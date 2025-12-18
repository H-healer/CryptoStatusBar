import Foundation
import Combine
import os.log

class CryptoService: ObservableObject {
    // 静态共享实例，供全局访问
    static let shared = CryptoService()
    
    // 发布订阅属性
    @Published var products: [CryptoProduct] = []
    @Published var favoriteProducts: [CryptoProduct] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var errorMessage: String?
    
    // 日志系统
    private let logger = Logger(subsystem: "com.cryptostatusbar", category: "CryptoService")
    
    // WebSocket相关属性
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var subscribedProducts: Set<String> = []
    private var messageProcessCount: Int = 0
    private let messageProcessThreshold: Int = 3 // 每X条消息处理一次
    
    // 设置相关
    private let favoritesKey = "FavoriteCryptoProducts"
    private let cacheKey = "CryptoPriceCache"
    private var updateTimer: Timer?
    
    // 重连控制
    private(set) var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 10
    private let reconnectDelay: TimeInterval = 5.0
    
    // 缓存控制
    private let cacheDuration: TimeInterval = 30 * 60 // 30分钟缓存
    
    // 属性列表
    private var pingTimer: Timer?
    private var urlSession: URLSession?
    
    // 汇率相关属性
    @Published private(set) var usdCnyRate: Double = 7.16  // 默认汇率
    private let exchangeRateKey = "UsdCnyExchangeRate"
    private let exchangeRateTimestampKey = "ExchangeRateTimestamp"
    private let exchangeRateValidDuration: TimeInterval = 3600  // 汇率有效期1小时
    
    // 节流机制变量
    private var lastUIUpdateTime: Date = Date()
    private let uiUpdateThrottleInterval: TimeInterval = 0.1 // 降低到0.1秒，确保更快响应
    
    // 连接WebSocket
    func connectWebSocket() {
        // 如果已有连接，先关闭
        if webSocketTask != nil {
            disconnectWebSocket()
            // 短暂延迟后再重连，给资源释放的时间
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.doConnectWebSocket()
            }
            return
        }
        
        // 直接连接
        doConnectWebSocket()
    }
    
    // 实际执行WebSocket连接
    private func doConnectWebSocket() {
        logger.info("正在连接WebSocket...")
        connectionStatus = .connecting
        
        guard let url = URL(string: "wss://ws.okx.com:8443/ws/v5/public") else {
            logger.error("无效的WebSocket URL")
            connectionStatus = .failed
            errorMessage = "无效的WebSocket URL"
            return
        }
        
        // 使用自定义配置创建URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0  // 请求超时
        config.timeoutIntervalForResource = 60.0 // 资源超时
        
        let session = URLSession(configuration: config)
        webSocketTask = session.webSocketTask(with: url)
        
        // 设置任务完成后的回调
        webSocketTask?.resume()
        
        // 开始接收消息
        receiveMessage()
        
        // 设置心跳检测
        setupPing()
        
        // 连接成功后恢复之前的订阅
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.onWebSocketConnected()
        }
    }
    
    // 使用定期发送ping来检测连接状态
    private func setupPing() {
        // 清理旧的ping定时器
        pingTimer?.invalidate()
        pingTimer = nil
        
        guard connectionStatus != .disconnected, let webSocketTask = webSocketTask else {
            return
        }
        
        // 创建新的ping定时器，每30秒发送一次
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.connectionStatus == .connected else {
                return
            }
            
            // 发送ping并检查连接状态
            webSocketTask.sendPing { error in
                if let error = error {
                    self.logger.error("Ping失败，连接可能已断开: \(error.localizedDescription)")
                    
                    // 在主线程处理断开连接
                    DispatchQueue.main.async {
                        self.handleDisconnect()
                    }
                }
            }
        }
    }
    
    // 处理WebSocket连接成功
    private func onWebSocketConnected() {
        connectionStatus = .connected
        reconnectAttempts = 0
        logger.info("WebSocket连接成功，准备订阅收藏产品")
        
        // 仅订阅收藏列表中的产品
        subscribedProducts.removeAll()
        
        // 只为收藏的产品创建订阅
        for product in favoriteProducts {
            subscribeProduct(product)
        }
        
        logger.info("已订阅 \(self.subscribedProducts.count) 个收藏产品的价格更新")
    }
    
    // 接收消息
    private func receiveMessage() {
        // 避免在已取消的WebSocket任务上接收消息
        guard let task = webSocketTask, connectionStatus != .disconnected else {
            return
        }
        
        task.receive { [weak self] result in
            guard let self = self else { return }
            
            // 如果连接已断开，不再处理
            if self.connectionStatus == .disconnected || self.webSocketTask == nil {
                return
            }
            
            switch result {
            case .success(let message):
                // 增加消息计数
                self.messageProcessCount += 1
                
                // 使用限流机制，不处理所有消息
                let shouldProcess = self.messageProcessCount % self.messageProcessThreshold == 0
                let currentDisplayId = AppSettings.shared.loadCurrentDisplayID()
                
                switch message {
                case .string(let text):
                    // WebSocket保持实时接收，但使用简单的节流避免过度处理
                    // 快速检查消息中是否包含当前显示的币种，只处理相关消息或达到处理阈值的消息
                    let containsCurrentCoin = currentDisplayId != nil && text.contains(currentDisplayId!)

                    if containsCurrentCoin || shouldProcess {
                        // 使用最低优先级处理消息
                        DispatchQueue.global(qos: .background).async {
                        self.handleMessage(text)
                        }
                    }

                    // 立即开始接收下一条消息，不等待处理完成
                        DispatchQueue.main.async {
                            self.receiveMessage()
                        }
                    
                case .data(let data):
                    // 对于二进制数据，仅在达到处理阈值时才处理
                    if shouldProcess {
                        DispatchQueue.global(qos: .background).async {
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                            }
                        }
                        }

                    // 立即开始接收下一条消息
                        DispatchQueue.main.async {
                            self.receiveMessage()
                        }
                    
                @unknown default:
                    self.logger.error("收到未知类型的WebSocket消息")
                    DispatchQueue.main.async {
                        self.receiveMessage()
                    }
                }
                
            case .failure(let error):
                self.logger.error("接收WebSocket消息失败: \(error.localizedDescription)")
                
                // 使用主队列处理断开连接
                DispatchQueue.main.async {
                    self.handleDisconnect()
                }
            }
        }
    }
    
    // 处理接收到的消息
    private func handleMessage(_ message: String) {
        // 简单过滤：确保不处理空消息和ping/pong消息
        guard !message.isEmpty, 
              !message.contains("\"pong\"") else {
            return
        }
        
        // 如果消息包含数据和产品ID，直接处理
        if message.contains("\"data\"") && message.contains("\"instId\"") {
            handlePriceUpdate(message)
        }
    }
    
    // 处理价格更新消息
    private func handlePriceUpdate(_ message: String) {
        // 优化：使用后台队列处理消息，但降低优先级
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
        guard let data = message.data(using: .utf8) else {
                self.logger.error("无法将消息转换为数据")
            return
        }
        
            // 获取当前显示的币种ID
            let currentDisplayId = AppSettings.shared.loadCurrentDisplayID()
            
            do {
                // 快速预判断，如果不是JSON对象则直接返回
                if data.first != 123 { // ASCII '{' 的值
                    return
                }
                
                // 重用解析器实例，减少对象创建
                // 使用更轻量级的方式解析JSON
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]] {
                
                    // 优先处理当前显示的币种，延迟处理其他币种
                    var hasCurrentDisplayUpdate = false
                    
                    // 首先只检查是否有当前显示币种的更新
                    if let currentDisplayId = currentDisplayId {
                for item in dataArray {
                            if let instId = item["instId"] as? String, instId == currentDisplayId {
                                hasCurrentDisplayUpdate = true
                                break
                            }
                        }
                    }
                    
                    // 批量收集更新数据
                    var priceUpdates = [(String, Double)]()
                    var detailUpdates = [(String, Double, Double, Double, Double, Double)]()
                    
                    // 首先处理当前显示的币种
                    for item in dataArray {
                        // 快速检查必要字段
                        guard let instId = item["instId"] as? String,
                              self.subscribedProducts.contains(instId) else {
                        continue
                    }
                    
                        // 如果当前有显示的币种，且这不是显示的币种，且不在需要立即更新的情况下
                        // 则只以较低频率更新其他币种
                        if currentDisplayId != nil && 
                           instId != currentDisplayId && 
                           !hasCurrentDisplayUpdate {
                            // 为非显示币种应用额外的节流
                            if Int.random(in: 0...10) > 3 { // 70%的概率跳过处理
                        continue
                    }
                        }
                        
                        // 提取价格
                        if let lastPriceStr = item["last"] as? String,
                           let lastPrice = Double(lastPriceStr) {
                            // 添加到价格更新批次中
                            priceUpdates.append((instId, lastPrice))
                    
                            // 检查是否有24小时高低价数据
                    if let high24hStr = item["high24h"] as? String,
                       let low24hStr = item["low24h"] as? String,
                       let high24h = Double(high24hStr),
                       let low24h = Double(low24hStr) {
                        
                                // 简化涨跌幅获取逻辑
                                let changePercent = self.extractChangePercent(from: item, currentPrice: lastPrice)
                                
                                // 提取开盘价 - 只在必要时提取
                                let utcOpenPrice = instId == currentDisplayId ? 
                                    self.extractDoubleValue(from: item, key: "sodUtc0") : 0.0
                                let localOpenPrice = instId == currentDisplayId ? 
                                    self.extractDoubleValue(from: item, key: "sodUtc8") : 0.0
                                
                                detailUpdates.append((instId, high24h, low24h, changePercent, utcOpenPrice, localOpenPrice))
                            }
                        }
                    }
                    
                    // 只有在有更新时才执行主线程操作
                    if !priceUpdates.isEmpty {
                        // 使用节流机制限制UI更新频率
                        self.efficientPriceUpdate(priceUpdates, detailUpdates, hasCurrentDisplayUpdate)
                    }
                }
            } catch {
                self.logger.error("解析价格更新消息失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 高效的价格更新机制 - 替代之前的throttledPriceUpdate
    private func efficientPriceUpdate(_ priceUpdates: [(String, Double)], _ detailUpdates: [(String, Double, Double, Double, Double, Double)], _ isImportantUpdate: Bool) {
        let now = Date()
        
        // 获取当前显示的币种ID
        let currentDisplayId = AppSettings.shared.loadCurrentDisplayID()
        let hasCurrentDisplayUpdate = priceUpdates.contains { $0.0 == currentDisplayId }
                        
        // 减少非重要更新的频率
        if !isImportantUpdate && !hasCurrentDisplayUpdate && now.timeIntervalSince(lastUIUpdateTime) < uiUpdateThrottleInterval {
            return
        }
        
        // 更新UI - 使用低优先级队列，减少主线程负担
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 批量更新价格
            for (id, price) in priceUpdates {
                // 更主列表中的价格
                for (index, var product) in self.products.enumerated() where product.instId == id {
                    // 避免不必要的更新 - 只在价格实际变化时更新
                    if abs(product.currentPrice - price) > 0.000001 { // 使用精度比较
                        product.updatePrice(newPrice: price)
                        self.products[index] = product
                    }
                    break
                }
                
                // 更新收藏列表中的价格
                for (index, var favorite) in self.favoriteProducts.enumerated() where favorite.instId == id {
                    let oldPrice = favorite.currentPrice
                    // 避免不必要的更新 - 只在价格实际变化时更新
                    if abs(oldPrice - price) > 0.000001 { // 使用精度比较
                        favorite.updatePrice(newPrice: price)
                        self.favoriteProducts[index] = favorite
                        
                        // 如果是当前显示的币种，发送通知促使状态栏更新
                        if id == currentDisplayId {
                            // 发布价格更新通知，让状态栏响应
                            NotificationCenter.default.post(
                                name: NSNotification.Name("PriceUpdated"),
                                object: nil,
                                userInfo: ["instId": id, "price": price]
                            )
                        }
                    }
                    break
                }
            }
            
            // 批量更新详细信息 - 只为当前显示的币种更新
            if let currentId = currentDisplayId {
                for (id, high, low, change, utcOpen, localOpen) in detailUpdates where id == currentId {
                    // 更新24小时数据
                            self.update24hData(instId: id, high: high, low: low, changePercent: change)
                    
                    // 只在开盘价有值时才更新
                    if utcOpen > 0 || localOpen > 0 {
                            self.updateOpenPrices(instId: id, utcOpen: utcOpen, localOpen: localOpen)
                        }
                    }
                }
            
            // 只有当前显示币种有更新时才发送全局更新通知
            if hasCurrentDisplayUpdate {
                self.objectWillChange.send()
            }
            
            // 更新时间戳
            self.lastUIUpdateTime = now
        }
    }
    
    // 从消息中提取Double值的辅助方法
    private func extractDoubleValue(from item: [String: Any], key: String) -> Double {
        if let valueStr = item[key] as? String,
           let value = Double(valueStr) {
            return value
        }
        return 0.0
    }
    
    // 从消息中提取涨跌幅的辅助方法
    private func extractChangePercent(from item: [String: Any], currentPrice: Double) -> Double {
        // 尝试直接从API获取涨跌幅
        if let changePercentStr = item["changePercentage"] as? String 
           ?? item["changePercent24h"] as? String 
           ?? item["priceChangePercent"] as? String {
            
            // 处理可能包含百分号的字符串
            var changeStr = changePercentStr
            if changeStr.hasSuffix("%") {
                changeStr = String(changeStr.dropLast())
            }
            
            return Double(changeStr) ?? 0
        } 
        
        // 尝试通过变化量计算
        if let chgStr = item["chg24h"] as? String, 
           let chg24h = Double(chgStr), 
           currentPrice > 0 {
            return (chg24h / currentPrice) * 100
        }
        
        // 尝试通过开盘价计算
        if let openPxStr = item["open24h"] as? String,
           let openPx = Double(openPxStr), 
           openPx > 0,
           currentPrice > 0 {
            return ((currentPrice - openPx) / openPx) * 100
        }
        
        return 0.0
    }
    
    // 更新产品价格
    private func updateProductPrice(instId: String, newPrice: Double) {
        // 获取当前显示的币种ID
        let currentDisplayId = AppSettings.shared.loadCurrentDisplayID()
        let isCurrentDisplayCoin = (instId == currentDisplayId)
        
        // 更新主列表
        for (index, var product) in products.enumerated() where product.instId == instId {
            product.updatePrice(newPrice: newPrice)
            products[index] = product
            break
        }
        
        // 更新单个收藏币种
        updateSingleFavoritePrice(instId: instId, newPrice: newPrice)
        
        // 发布更新通知 - 使用主线程同步执行确保立即更新UI
        if isCurrentDisplayCoin {
            // 如果是当前显示的币种，同步立即更新
            if Thread.isMainThread {
                self.objectWillChange.send()
            } else {
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
        } else {
            // 对于其他币种，可以异步更新
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    // 更新单个收藏币种价格，优化版本以减少CPU使用率
    private func updateSingleFavoritePrice(instId: String, newPrice: Double) {
        // 获取当前显示的币种ID
        let currentDisplayId = AppSettings.shared.loadCurrentDisplayID()
        let isCurrentDisplayCoin = (instId == currentDisplayId)

        // 仅查找并更新匹配的收藏币种
        for (index, var favorite) in favoriteProducts.enumerated() where favorite.instId == instId {
            // 检查价格是否真的发生了变化 - 避免不必要的更新
            if abs(favorite.currentPrice - newPrice) < 0.000001 {
                // 价格没有变化，直接返回
                return
            }
            
            // 保存旧价格用于比较
                let oldCurrentPrice = favorite.currentPrice
                
            // 仅在必要时检查通知条件
            if AppSettings.shared.notifyOnSignificantChanges && oldCurrentPrice > 0 && newPrice > 0 {
                // 计算变化百分比
                let priceChangeMode = AppSettings.shared.priceChangeCalculationMode
                var priceChange: Double = 0
                
                // 简化百分比计算逻辑
                if priceChangeMode == .hours24 {
                    // 使用24小时百分比变化
                    priceChange = favorite.priceChangePercent24h
                    } else {
                    // 简单计算当前价格与开盘价的百分比差异
                    let refPrice = priceChangeMode == .todayUtc ? 
                        favorite.utcOpenPrice : favorite.localOpenPrice
                    
                    if refPrice > 0 {
                        priceChange = ((newPrice - refPrice) / refPrice) * 100
                    }
                }
                
                let absoluteChange = abs(priceChange)
                
                // 只在价格变化超过阈值时发送通知
                if absoluteChange >= AppSettings.shared.significantChangeThreshold {
                    // 使用现有对象发送通知，避免创建新对象
                    NotificationManager.shared.sendPriceChangeNotification(
                        for: favorite,
                        percentChange: priceChange,
                        previousPrice: oldCurrentPrice
                    )
                }
            }
            
            // 直接更新价格，减少对象创建
            favorite.updatePrice(newPrice: newPrice)
                favoriteProducts[index] = favorite
            
            // 只为当前显示的币种发送更新通知
            if isCurrentDisplayCoin {
                // 发送价格更新通知，让状态栏响应
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("PriceUpdated"),
                        object: nil,
                        userInfo: ["instId": instId, "price": newPrice]
                    )
                }
            }
            
            // 找到后退出循环
            break
            }
        }
    
    // 原函数保留，但实际上不再使用，避免意外调用导致的问题
    private func updateFavoritePrices() {
        // 此函数不再使用，数据更新改为由updateSingleFavoritePrice处理
        logger.debug("updateFavoritePrices被调用，但不再使用此函数")
    }
    
    // 更新24小时数据
    private func update24hData(instId: String, high: Double, low: Double, changePercent: Double) {
        // 更新主列表
        for (index, var product) in products.enumerated() where product.instId == instId {
            product.update24hData(high: high, low: low, changePercent: changePercent)
            products[index] = product
            break
        }
        
        // 同步更新收藏列表
        for (index, var favorite) in favoriteProducts.enumerated() where favorite.instId == instId {
            if let product = products.first(where: { $0.instId == favorite.instId }) {
                favorite.update24hData(
                    high: product.highPrice24h,
                    low: product.lowPrice24h, 
                    changePercent: product.priceChangePercent24h
                )
                favoriteProducts[index] = favorite
            }
        }
    }
    
    // 更新开盘价数据
    private func updateOpenPrices(instId: String, utcOpen: Double, localOpen: Double) {
        // 如果开盘价为0，不进行更新
        if utcOpen == 0 && localOpen == 0 {
            return
        }
        
        // 更新主列表
        for (index, var product) in products.enumerated() where product.instId == instId {
            product.updateOpenPrices(utcOpen: utcOpen, localOpen: localOpen)
            products[index] = product
            break
        }
        
        // 更新收藏列表
        for (index, var favorite) in favoriteProducts.enumerated() where favorite.instId == instId {
            if let product = products.first(where: { $0.instId == favorite.instId }) {
                favorite.updateOpenPrices(
                    utcOpen: product.utcOpenPrice,
                    localOpen: product.localOpenPrice
                )
                favoriteProducts[index] = favorite
            }
        }
    }
    
    // 计算从指定开始日期到现在的涨跌幅
    func calculatePriceChangePercent(for product: CryptoProduct, 
                                    from startTimestamp: TimeInterval) -> Double {
        // 实现基于开始日期的涨跌幅计算逻辑
        // 这里需要API支持，目前仅作为示例实现
        
        // 当前没有访问历史价格API的实现，暂时返回24小时涨跌幅
        // 实际应用中可以使用API获取指定时间的价格，然后计算涨跌幅
        return product.priceChangePercent24h
    }
    
    // 基于设置计算涨跌幅百分比
    func getPriceChangePercent(for product: CryptoProduct) -> Double {
        let calculationMode = AppSettings.shared.priceChangeCalculationMode
        
        switch calculationMode {
        case .hours24:
            // 直接使用24小时涨跌幅
            return product.priceChangePercent24h
            
        case .todayUtc:
            // 计算从UTC零点到现在的涨跌幅
            let calendar = Calendar.current
            var components = DateComponents()
            components.year = calendar.component(.year, from: Date())
            components.month = calendar.component(.month, from: Date())
            components.day = calendar.component(.day, from: Date())
            components.hour = 0
            components.minute = 0
            components.second = 0
            
            // 使用UTC时区设置零点
            components.timeZone = TimeZone(abbreviation: "UTC")
            
            guard let startDate = calendar.date(from: components) else {
                return product.priceChangePercent24h
            }
            
            return calculatePriceChangePercent(for: product, from: startDate.timeIntervalSince1970)
            
        case .todayLocal:
            // 计算从北京时间零点到现在的涨跌幅
            let calendar = Calendar.current
            var components = DateComponents()
            components.year = calendar.component(.year, from: Date())
            components.month = calendar.component(.month, from: Date())
            components.day = calendar.component(.day, from: Date())
            components.hour = 0
            components.minute = 0
            components.second = 0
            
            // 使用北京时区(UTC+8)设置零点
            components.timeZone = TimeZone(abbreviation: "GMT+8")
            
            guard let startDate = calendar.date(from: components) else {
                return product.priceChangePercent24h
            }
            
            return calculatePriceChangePercent(for: product, from: startDate.timeIntervalSince1970)
        }
    }
    
    // 刷新所有收藏的产品的涨跌幅
    func refreshPriceChangePercents() {
        // 重新计算所有产品的涨跌幅数据
        // 在真实环境中可能需要发起API请求获取更多历史数据
        
        let mode = AppSettings.shared.priceChangeCalculationMode
        logger.info("正在基于 \(mode.description) 重新计算涨跌幅...")
        
        // 在实际应用中，这里应该调用API获取历史价格，然后更新开盘价和涨跌幅
        // 为了演示，我们暂时使用已有数据
        
        switch mode {
        case .hours24:
            logger.info("使用24小时涨跌幅数据，无需额外计算")
            
        case .todayUtc, .todayLocal:
            logger.info("需要获取当日开盘价数据来计算涨跌幅，暂时使用估算值")
            // 实际应用中这里应该发起API请求获取当天开盘价
        }
        
        // 通知UI更新
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    // 刷新收藏产品价格
    func refreshFavoriteProducts() {
        logger.info("正在刷新收藏产品价格")
        
        // 如果收藏列表为空，无需刷新
        if favoriteProducts.isEmpty {
            logger.info("收藏列表为空，无需刷新价格")
            return
        }
        
        // 确保WebSocket连接有效
        if connectionStatus != .connected {
            logger.info("WebSocket未连接，尝试重新连接")
            reconnect()
            return
        }
        
        // 优化订阅，确保只订阅收藏的产品
        let favoriteIds = Set(favoriteProducts.map { $0.instId })
        
        // 获取每个收藏产品的最新价格
        for instId in favoriteIds {
            // 从主列表中查找产品的最新价格
            if let product = products.first(where: { $0.instId == instId }) {
                // 直接使用单个产品更新机制，传递最新价格
                updateSingleFavoritePrice(instId: instId, newPrice: product.currentPrice)
            } else {
                // 如果在主列表中找不到，尝试从API获取最新价格
                fetchSingleProductPrice(instId: instId)
            }
        }
        
        // 每次刷新后保存价格缓存
        savePriceCache()
    }
    
    // 订阅产品价格
    func subscribeProduct(_ product: CryptoProduct) {
        // 如果已经在订阅列表中，不重复订阅
        if subscribedProducts.contains(product.instId) {
            return
        }
        
        // 先添加到订阅列表
        subscribedProducts.insert(product.instId)
        
        // 若WebSocket未连接，仅记录状态不发送请求
        if connectionStatus != .connected {
            logger.info("WebSocket未连接，记录订阅 \(product.instId)，待连接后发送请求")
            return
        }
        
        let instId = product.instId
        logger.info("发送订阅请求: \(instId)")
        
        let subscribeMessage: [String: Any] = [
            "op": "subscribe",
            "args": [
                [
                    "channel": "tickers",
                    "instId": instId
                ]
            ]
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: subscribeMessage)
            if let message = String(data: data, encoding: .utf8) {
                webSocketTask?.send(.string(message)) { [weak self] error in
                    if let error = error {
                        self?.logger.error("订阅 \(instId) 失败: \(error.localizedDescription)")
                        
                        // 订阅失败时从列表中移除
                        DispatchQueue.main.async {
                            self?.subscribedProducts.remove(instId)
                        }
                    } else {
                        self?.logger.info("已发送订阅请求 \(instId)")
                    }
                }
            }
        } catch {
            logger.error("创建订阅消息失败: \(error.localizedDescription)")
            // 创建消息失败时从列表中移除
            subscribedProducts.remove(instId)
        }
    }
    
    // 取消订阅产品价格
    func unsubscribeProduct(_ instId: String) {
        // 如果不在订阅列表中，无需取消
        guard subscribedProducts.contains(instId) else {
            return
        }
        
        // 如果产品还在收藏列表中，不取消订阅
        if favoriteProducts.contains(where: { $0.instId == instId }) {
            logger.info("产品 \(instId) 仍在收藏列表中，保留订阅")
            return
        }
        
        logger.info("取消订阅产品: \(instId)")
        
        // 从订阅列表中移除
        subscribedProducts.remove(instId)
        
        // 如果WebSocket连接，发送取消订阅请求
        if connectionStatus == .connected, let webSocketTask = webSocketTask {
            let unsubscribeMessage: [String: Any] = [
                "op": "unsubscribe",
                "args": [
                    [
                        "channel": "tickers",
                        "instId": instId
                    ]
                ]
            ]
            
            do {
                let data = try JSONSerialization.data(withJSONObject: unsubscribeMessage)
                if let message = String(data: data, encoding: .utf8) {
                    webSocketTask.send(.string(message)) { [weak self] error in
                        if let error = error {
                            self?.logger.error("取消订阅 \(instId) 失败: \(error.localizedDescription)")
                        } else {
                            self?.logger.info("已取消订阅 \(instId)")
                        }
                    }
                }
            } catch {
                logger.error("创建取消订阅消息失败: \(error.localizedDescription)")
            }
        } else {
            logger.info("WebSocket未连接，直接移除订阅状态: \(instId)")
        }
    }
    
    // 获取所有产品列表
    func fetchAllProducts() {
        let productType = AppSettings.shared.getCurrentProductType()
        logger.info("正在获取所有产品列表，类型: \(productType.displayName)")
        
        guard let url = URL(string: "https://www.okx.com/api/v5/market/tickers?instType=\(productType.rawValue)") else {
            logger.error("无效的API URL")
            return
        }
        
        // 设置连接超时
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15 // 15秒超时
        config.timeoutIntervalForResource = 30 // 30秒资源超时
        
        let session = URLSession(configuration: config)
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("获取产品列表失败: \(error.localizedDescription)")
                self.errorMessage = "获取产品列表失败"
                return
            }
            
            guard let data = data else {
                self.logger.error("获取产品列表返回空数据")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArray = json["data"] as? [[String: Any]] {
                    
                    var newProducts: [CryptoProduct] = []
                    
                    var processedCount = 0
                    
                    for item in dataArray {
                        
                        guard let instId = item["instId"] as? String else { continue }
                        
                        let parts = instId.split(separator: "-")
                        guard parts.count >= 2 else { continue }
                        
                        let baseCcy = String(parts[0])
                        let quoteCcy = String(parts[1])
                        
                        // 根据产品类型过滤
                        let currentType = AppSettings.shared.getCurrentProductType()
                        
                        // 只显示USDT、USDC、USD交易对
                        let shouldAdd = quoteCcy == "USDT" || quoteCcy == "USDC" || quoteCcy == "USD"
                        
                        if shouldAdd {
                            processedCount += 1
                            
                            let product = CryptoProduct(
                                id: instId,
                                instId: instId,
                                baseCcy: baseCcy,
                                quoteCcy: quoteCcy,
                                productType: currentType
                            )
                            
                            if let lastPriceStr = item["last"] as? String,
                               let lastPrice = Double(lastPriceStr) {
                                var productWithPrice = product
                                productWithPrice.updatePrice(newPrice: lastPrice)
                                
                                // 可能的24小时数据
                                if let high24hStr = item["high24h"] as? String,
                                   let low24hStr = item["low24h"] as? String,
                                   let high24h = Double(high24hStr),
                                   let low24h = Double(low24hStr) {
                                    
                                    var changePercent: Double = 0
                                    
                                    // 首先尝试直接从API获取涨跌幅
                                    if let changePercentStr = item["changePercentage"] as? String 
                                       ?? item["changePercent24h"] as? String 
                                       ?? item["priceChangePercent"] as? String {
                                        
                                        // 处理可能包含百分号的字符串
                                        var changeStr = changePercentStr
                                        if changeStr.hasSuffix("%") {
                                            changeStr = String(changeStr.dropLast())
                                        }
                                        
                                        changePercent = Double(changeStr) ?? 0
                                    } 
                                    // 如果没有直接获取到涨跌幅，尝试通过变化量计算
                                    else if let chgStr = item["chg24h"] as? String, 
                                            let chg24h = Double(chgStr), 
                                            lastPrice > 0 {
                                        // 涨跌幅 = 价格变化 / 最新价格 * 100
                                        changePercent = (chg24h / lastPrice) * 100
                                    } 
                                    // 如果都获取不到，也可以尝试通过开盘价计算
                                    else if let openPxStr = item["open24h"] as? String,
                                            let openPx = Double(openPxStr), 
                                            openPx > 0,
                                            lastPrice > 0 {
                                        // 涨跌幅 = (当前价格 - 开盘价) / 开盘价 * 100
                                        changePercent = ((lastPrice - openPx) / openPx) * 100
                                    }
                                    
                                    productWithPrice.update24hData(
                                        high: high24h,
                                        low: low24h,
                                        changePercent: changePercent
                                    )
                                    
                                    // 获取UTC和UTC+8开盘价
                                    var utcOpenPrice: Double = 0.0
                                    var localOpenPrice: Double = 0.0
                                    
                                    // 直接从API获取UTC和北京时间开盘价
                                    if let sodUtc0Str = item["sodUtc0"] as? String,
                                       let utcOpen = Double(sodUtc0Str) {
                                        utcOpenPrice = utcOpen
                                    }
                                    
                                    if let sodUtc8Str = item["sodUtc8"] as? String,
                                       let localOpen = Double(sodUtc8Str) {
                                        localOpenPrice = localOpen
                                    }
                                    
                                    // 更新开盘价
                                    productWithPrice.updateOpenPrices(
                                        utcOpen: utcOpenPrice,
                                        localOpen: localOpenPrice
                                    )
                                }
                                
                                newProducts.append(productWithPrice)
                            } else {
                                newProducts.append(product)
                            }
                        }
                    }
                    
                    // 按交易量排序
                    newProducts.sort { $0.baseCcy < $1.baseCcy }
                    
                    self.logger.info("已处理 \(processedCount) 个产品，添加了 \(newProducts.count) 个\(AppSettings.shared.getCurrentProductType().displayName)产品")
                    
                    DispatchQueue.main.async {
                        self.products = newProducts
                        self.logger.info("已更新产品列表，共 \(newProducts.count) 个")
                        
                        // 更新收藏列表
                        self.updateFavoritesList()
                        
                        // 随机延迟1-2秒保存缓存，减轻立即处理的压力
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1...2)) {
                            // 保存价格缓存
                            self.savePriceCache()
                        }
                    }
                }
            } catch {
                self.logger.error("解析产品列表失败: \(error.localizedDescription)")
            }
        }
        
        task.resume()
    }
    
    // 更新收藏列表（当产品列表更新时）
    private func updateFavoritesList() {
        // 匹配产品列表中的数据，更新收藏列表
        var updatedFavorites: [CryptoProduct] = []
        
        for favorite in favoriteProducts {
            let instId = favorite.instId
            
            // 先确保产品类型正确
            let expectedType = determineProductType(forInstId: instId)
            
            // 如果产品类型不匹配预期，需要修复
            let correctType = (favorite.productType == expectedType) ? favorite.productType : expectedType
            
            if let product = products.first(where: { $0.instId == favorite.instId }) {
                // 保留用户设置的显示选项
                var updatedProduct = product
                
                // 确保使用正确的产品类型
                if updatedProduct.productType != correctType {
                    logger.warning("收藏列表更新时修复产品类型: \(instId) 从 \(updatedProduct.productType.displayName) 到 \(correctType.displayName)")
                    
                    // 创建具有正确类型的新产品
                    var correctedProduct = CryptoProduct(
                        id: updatedProduct.id,
                        instId: updatedProduct.instId,
                        baseCcy: updatedProduct.baseCcy,
                        quoteCcy: updatedProduct.quoteCcy,
                        productType: correctType
                    )
                    
                    // 复制产品数据
                    correctedProduct.updatePrice(newPrice: updatedProduct.currentPrice)
                    correctedProduct.update24hData(
                        high: updatedProduct.highPrice24h,
                        low: updatedProduct.lowPrice24h,
                        changePercent: updatedProduct.priceChangePercent24h
                    )
                    correctedProduct.updateOpenPrices(
                        utcOpen: updatedProduct.utcOpenPrice,
                        localOpen: updatedProduct.localOpenPrice
                    )
                    
                    updatedProduct = correctedProduct
                }
                
                // 不再使用实例的displayDecimals和displayWithCurrency属性
                // 所有显示格式直接从AppSettings获取
                updatedProduct.notifyOnPriceChange = favorite.notifyOnPriceChange
                updatedProduct.priceAlertThreshold = favorite.priceAlertThreshold
                
                // 保留原始的previousPrice，确保颜色正确显示
                if favorite.previousPrice != favorite.currentPrice {
                    // 如果原来的收藏项有不同的前一价格，保留该差异关系
                    if favorite.currentPrice > 0 && product.currentPrice > 0 {
                        // 计算相对变化比例
                        let ratio = favorite.previousPrice / favorite.currentPrice
                        // 应用同样比例到新价格上
                        var modifiedProduct = updatedProduct
                        let calculatedPreviousPrice = product.currentPrice * ratio
                        
                        // 先保存当前价格
                        let temp = modifiedProduct.currentPrice
                        // 更新一次（将价格设为计算出的previousPrice）
                        modifiedProduct.updatePrice(newPrice: calculatedPreviousPrice)
                        // 再更新回当前价格
                        modifiedProduct.updatePrice(newPrice: temp)
                        updatedProduct = modifiedProduct
                    }
                }
                
                updatedFavorites.append(updatedProduct)
            } else {
                // 如果在产品列表中找不到，也要确保产品类型正确
                if favorite.productType != correctType {
                    logger.warning("修复未在主列表找到的收藏产品类型: \(instId) 从 \(favorite.productType.displayName) 到 \(correctType.displayName)")
                    
                    // 创建具有正确类型的新产品
                    var correctedProduct = CryptoProduct(
                        id: favorite.id,
                        instId: favorite.instId,
                        baseCcy: favorite.baseCcy,
                        quoteCcy: favorite.quoteCcy,
                        productType: correctType
                    )
                    
                    // 复制产品数据
                    correctedProduct.updatePrice(newPrice: favorite.currentPrice)
                    correctedProduct.setPreviousPrice(favorite.previousPrice)
                    correctedProduct.update24hData(
                        high: favorite.highPrice24h,
                        low: favorite.lowPrice24h,
                        changePercent: favorite.priceChangePercent24h
                    )
                    correctedProduct.updateOpenPrices(
                        utcOpen: favorite.utcOpenPrice,
                        localOpen: favorite.localOpenPrice
                    )
                    
                    updatedFavorites.append(correctedProduct)
                } else {
                    updatedFavorites.append(favorite)
                }
            }
        }
        
        // 如果发现有类型变化，记录警告
        let beforeTypes = Set(favoriteProducts.map { "\($0.instId):\($0.productType.rawValue)" })
        let afterTypes = Set(updatedFavorites.map { "\($0.instId):\($0.productType.rawValue)" })
        if beforeTypes != afterTypes {
            logger.warning("收藏列表的产品类型已修复")
            // 更新列表并保存
            favoriteProducts = updatedFavorites
            saveFavorites()
        } else {
            favoriteProducts = updatedFavorites
        }
        
        // 确保仅订阅收藏的产品
        optimizeSubscriptions()
    }
    
    // 根据产品ID确定产品类型的辅助方法
    private func determineProductType(forInstId instId: String) -> ProductType {
        // 根据instId特征识别类型
        if instId.contains("-SWAP") {
            return .SWAP
        } else if instId.contains("-FUTURES") {
            return .FUTURES
        } else if instId.contains("-OPTION") {
            return .OPTION
        } else {
            return .SPOT
        }
    }
    
    // 整理用户订阅
    func optimizeSubscriptions() {
        // 如果收藏列表为空，直接清空订阅并返回
        if favoriteProducts.isEmpty {
            logger.info("收藏列表为空，清空所有WebSocket订阅")
            let oldSubscriptions = subscribedProducts
            subscribedProducts.removeAll()
            
            // 取消所有现有订阅
            oldSubscriptions.forEach { instId in
                unsubscribeProduct(instId)
            }
            return
        }
        
        logger.info("正在优化WebSocket订阅...")
        
        // 取消不在收藏列表中的产品订阅
        // 先找出需要取消的订阅
        var toUnsubscribe = Set<String>()
        for instId in subscribedProducts {
            if !favoriteProducts.contains(where: { $0.instId == instId }) {
                toUnsubscribe.insert(instId)
            }
        }
        
        // 逐个取消订阅，避免一次性发送太多请求
        for instId in toUnsubscribe {
            subscribedProducts.remove(instId)
            unsubscribeProduct(instId)
        }
        
        // 添加新的订阅
        // 找出需要新增的订阅
        var toSubscribe = [CryptoProduct]()
        for product in favoriteProducts {
            if !subscribedProducts.contains(product.instId) {
                toSubscribe.append(product)
            }
        }
        
        // 如果需要订阅的产品数量超过5个，分批进行
        if toSubscribe.count > 5 {
            logger.info("需要订阅 \(toSubscribe.count) 个产品，将分批进行")
            
            // 先订阅前5个
            let firstBatch = Array(toSubscribe.prefix(5))
            for product in firstBatch {
                subscribeProduct(product)
            }
            
            // 剩余的延迟订阅
            let remainingBatch = Array(toSubscribe.dropFirst(5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                for product in remainingBatch {
                    self.subscribeProduct(product)
                    
                    // 每个订阅间隔一小段时间
                    Thread.sleep(forTimeInterval: 0.2)
                }
                self.logger.info("已完成所有批次订阅，当前订阅数: \(self.subscribedProducts.count)")
            }
        } else {
            // 订阅数量较少，直接订阅
            for product in toSubscribe {
                subscribeProduct(product)
            }
        }
        
        logger.info("WebSocket订阅已优化，当前订阅数: \(self.subscribedProducts.count)")
    }
    
    // 处理断开连接
    private func handleDisconnect() {
        logger.info("WebSocket已断开连接")
        connectionStatus = .disconnected
        
        // 取消之前的重连计划（如果有）
        reconnectWorkItem?.cancel()
        
        // 清理当前的WebSocket任务
        webSocketTask = nil
        
        // 尝试重新连接
        if self.reconnectAttempts < self.maxReconnectAttempts {
            self.reconnectAttempts += 1
            
            // 使用指数退避算法计算延迟
            let delay = reconnectDelay * pow(1.5, Double(self.reconnectAttempts - 1))
            logger.info("将在 \(delay) 秒后尝试第 \(self.reconnectAttempts) 次重连")
            
            let workItem = DispatchWorkItem { [weak self] in
                self?.connectWebSocket()
            }
            
            reconnectWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            logger.error("已达到最大重连次数 (\(self.maxReconnectAttempts))，停止重连")
            connectionStatus = .failed
            errorMessage = "连接服务器失败，请检查网络连接后重试"
        }
    }
    
    // 手动重新连接
    func reconnect() {
        // 重置重连计数
        reconnectAttempts = 0
        
        // 取消当前的重连计划
        reconnectWorkItem?.cancel()
        
        // 断开当前连接
        disconnectWebSocket()
        
        // 重新连接
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.connectWebSocket()
        }
    }
    
    // 公开方法用于清理资源
    public func cleanup() {
        logger.info("正在清理CryptoService资源")
        
        // 移除通知观察者
        NotificationCenter.default.removeObserver(self)
        
        // 保存价格到磁盘
        savePriceCache()
        
        // 断开WebSocket连接
        disconnectWebSocket()
        
        // 清理订阅和定时器
        cancelAllSubscriptions()
        
        // 强制取消所有延迟操作
        cancelDelayedOperations()
        
        // 记录清理完成
        logger.info("CryptoService资源已清理")
    }
    
    // 取消所有延迟操作
    private func cancelDelayedOperations() {
        // 遍历DispatchQueue.main中的所有与self相关的项目并取消
        DispatchQueue.main.async { [weak self] in
            // 这里故意留空，仅用于刷新队列
            guard let _ = self else { return }
        }
    }
    
    // 取消所有订阅
    private func cancelAllSubscriptions() {
        // 停止定时器
        updateTimer?.invalidate()
        updateTimer = nil

        // 停止ping定时器
        pingTimer?.invalidate()
        pingTimer = nil

        // 停止汇率刷新定时器
        exchangeRateTimer?.invalidate()
        exchangeRateTimer = nil

        // 取消重连计划
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        // 清空订阅列表
        subscribedProducts.removeAll()
    }
    
    // 断开WebSocket连接
    func disconnectWebSocket() {
        logger.info("手动断开WebSocket连接")
        
        // 标记连接状态为断开，防止后续消息处理
        connectionStatus = .disconnected
        
        // 取消重连计划
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        
        // 清空订阅集合
        subscribedProducts.removeAll()
        
        // 关闭WebSocket，确保在主线程执行
        if Thread.isMainThread {
            closeWebSocketConnection()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.closeWebSocketConnection()
            }
        }
    }
    
    // 关闭WebSocket连接的实际实现
    private func closeWebSocketConnection() {
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            logger.info("WebSocket连接已关闭")
        }
    }
    
    // 清除所有数据
    func clearAllData() {
        // 清除收藏和缓存
        UserDefaults.standard.removeObject(forKey: favoritesKey)
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.synchronize()
        
        // 重置数据
        favoriteProducts = []
        
        // 重新设置默认值
        setupDefaultFavorites()
        
        // 优化订阅
        optimizeSubscriptions()
        
        logger.info("已清除所有数据并重置为默认设置")
    }
    
    // 强制关闭所有网络活动
    func forceCloseAllConnections() {
        logger.warning("强制关闭所有网络连接")
        
        // 标记为已断开
        connectionStatus = .disconnected
        
        // 取消所有订阅和定时器
        cancelAllSubscriptions()
        
        // 关闭WebSocket连接
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: "Force close by user".data(using: .utf8))
            webSocketTask = nil
        }
        
        // 确保释放所有网络资源
        URLSession.shared.reset {}
    }
    
    // 析构函数
    deinit {
        // 强制关闭所有连接
        forceCloseAllConnections()
        
        // 日志记录
        logger.info("CryptoService已释放")
    }
    
    // 初始化
    private init() {
        // 加载缓存的数据
        loadCachedPrices()
        
        // 加载收藏列表
        loadFavorites()
        
        // 初始化URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        
        // 优化URLSession配置
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.shouldUseExtendedBackgroundIdleMode = true
        
        urlSession = URLSession(configuration: config)
        
        // 加载最新汇率
        loadCachedExchangeRate()
        
        // 内存优化：订阅低内存通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLowMemory),
            name: NSNotification.Name("NSApplicationDidReceiveMemoryWarning"),
            object: nil
        )
        
        // 设置更新定时器
        setupUpdateTimer()
    }
    
    // 处理低内存警告
    @objc private func handleLowMemory() {
        logger.warning("收到内存警告，开始清理缓存...")
        
        // 只保留收藏的产品，清理其他缓存
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            // 只保留favorites中引用的产品
            let favoriteIds = Set(self.favoriteProducts.map { $0.instId })
            
            // 过滤products数组，只保留收藏的产品
            DispatchQueue.main.async {
                self.products = self.products.filter { favoriteIds.contains($0.instId) }
                
                // 释放多余的内存
                autoreleasepool {
                    // 强制触发一次清理
                    URLCache.shared.removeAllCachedResponses()
                    
                    // 记录清理完成
                    self.logger.info("内存清理完成，当前缓存产品数: \(self.products.count)")
                }
            }
        }
    }
    
    // 初始化加密货币服务
    func initialize() {
        logger.info("初始化加密货币服务...")
        
        // 确保收藏列表已加载
        if favoriteProducts.isEmpty {
            // 加载收藏列表（确保不重复加载）
            loadFavorites()
        }
        
        // 如果收藏列表为空，添加默认的BTC和ETH
        if favoriteProducts.isEmpty {
            logger.info("收藏列表为空，添加默认产品...")
            setupDefaultFavorites()
        } else {
            // 优化：确保products和favorites完全同步
            // 避免重复存储同一个产品
            products = favoriteProducts
        }
        
        // 刷新收藏产品缓存
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.refreshFavoriteProducts()
        }
        
        // 连接WebSocket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connectWebSocket()
        }
    }
    
    // 注：此处原来是preloadFavoriteProductsCache方法，
    // 现在使用refreshFavoriteProducts替代该功能
    
    // 加载价格缓存
    private func loadCachedPrices() {
        guard let cacheData = UserDefaults.standard.object(forKey: cacheKey) as? [String: Any],
              let timestamp = cacheData["timestamp"] as? Double,
              Date().timeIntervalSince1970 - timestamp < cacheDuration,
              let cachedPrices = cacheData["prices"] as? [String: Double] else {
            logger.debug("没有有效的价格缓存或缓存已过期")
            return
        }
        
        logger.info("从缓存加载了 \(cachedPrices.count) 个产品价格")
        
        // 由于此时产品列表可能还未加载，先保存缓存，等产品列表加载后再应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.applyPriceCache(cachedPrices)
        }
    }
    
    // 应用价格缓存到产品列表
    private func applyPriceCache(_ cachedPrices: [String: Double]) {
        // 更新主列表产品价格
        for (index, var product) in products.enumerated() {
            if let price = cachedPrices[product.instId] {
                product.updatePrice(newPrice: price)
                products[index] = product
            }
        }
        
        // 更新每个收藏币种的价格
        for (instId, price) in cachedPrices {
            // 查找该ID对应的收藏币种
            if favoriteProducts.contains(where: { $0.instId == instId }) {
                // 使用单独更新方法更新此币种价格
                updateSingleFavoritePrice(instId: instId, newPrice: price)
            }
        }
        
        logger.debug("已应用缓存的价格数据")
    }
    
    // 保存价格缓存 - 优化：只缓存收藏的产品
    private func savePriceCache() {
        // 只缓存收藏产品的价格，减少存储空间和内存占用
        var priceDict: [String: Double] = [:]
        for product in favoriteProducts where product.currentPrice > 0 {
            priceDict[product.instId] = product.currentPrice
        }

        // 如果没有收藏产品，不保存缓存
        guard !priceDict.isEmpty else {
            logger.debug("没有收藏产品需要缓存")
            return
        }

        let cacheData: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "prices": priceDict
        ]

        UserDefaults.standard.set(cacheData, forKey: cacheKey)
        UserDefaults.standard.synchronize()

        logger.debug("已缓存 \(priceDict.count) 个收藏产品的价格")
    }
    
    // 加载收藏列表
    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey) {
            do {
                var favorites = try JSONDecoder().decode([CryptoProduct].self, from: data)
                
                if !favorites.isEmpty {
                    // 修复：确保每个收藏的产品都有正确的产品类型
                    // 如果产品类型信息损坏或不匹配其所在分组，则修复
                    for i in 0..<favorites.count {
                        let instId = favorites[i].instId
                        let parts = instId.split(separator: "-")
                        
                        // 检查这是否是一个有效的产品ID格式
                        if parts.count >= 2 {
                            let baseCcy = String(parts[0])
                            let quoteCcy = String(parts[1])
                            
                            // 获取该产品的预期类型（根据ID格式和保存的类型信息）
                            let expectedType: ProductType
                            
                            // 根据instId特征识别类型
                            if instId.contains("-SWAP") {
                                expectedType = .SWAP
                            } else if instId.contains("-FUTURES") {
                                expectedType = .FUTURES
                            } else if instId.contains("-OPTION") {
                                expectedType = .OPTION
                            } else {
                                expectedType = .SPOT
                            }
                            
                            // 如果产品类型不匹配预期，重新创建该产品对象
                            if favorites[i].productType != expectedType {
                                logger.warning("修复收藏产品类型: \(instId) 从 \(favorites[i].productType.displayName) 到 \(expectedType.displayName)")
                                
                                // 保存原始价格数据
                                let oldPrice = favorites[i].currentPrice
                                let oldPrevPrice = favorites[i].previousPrice
                                let highPrice = favorites[i].highPrice24h
                                let lowPrice = favorites[i].lowPrice24h
                                let changePercent = favorites[i].priceChangePercent24h
                                let utcOpen = favorites[i].utcOpenPrice
                                let localOpen = favorites[i].localOpenPrice
                                
                                // 创建新产品对象，使用正确的产品类型
                                var correctedProduct = CryptoProduct(
                                    id: instId, 
                                    instId: instId,
                                    baseCcy: baseCcy,
                                    quoteCcy: quoteCcy,
                                    productType: expectedType
                                )
                                
                                // 恢复价格信息
                                correctedProduct.updatePrice(newPrice: oldPrice)
                                correctedProduct.setPreviousPrice(oldPrevPrice)
                                correctedProduct.update24hData(high: highPrice, low: lowPrice, changePercent: changePercent)
                                correctedProduct.updateOpenPrices(utcOpen: utcOpen, localOpen: localOpen)
                                
                                // 替换原始产品
                                favorites[i] = correctedProduct
                            }
                        }
                    }
                    
                    // 更新收藏列表
                    self.favoriteProducts = favorites
                    logger.info("已加载 \(favorites.count) 个收藏产品，并确保产品类型正确")
                    
                    // 由于可能修复了产品类型，重新保存收藏列表
                    saveFavorites()
                } else {
                    logger.info("加载的收藏列表为空，使用默认值")
                    setupDefaultFavorites()
                }
            } catch {
                logger.error("加载收藏列表失败: \(error.localizedDescription)")
                setupDefaultFavorites()
            }
        } else {
            logger.info("未找到保存的收藏列表，使用默认值")
            setupDefaultFavorites()
        }
    }
    
    // 设置默认收藏
    private func setupDefaultFavorites() {
        logger.info("设置默认收藏列表")
        
        let defaultCoins = ["BTC-USDT", "ETH-USDT"]
        var defaultProducts: [CryptoProduct] = []
        
        for instId in defaultCoins {
            let parts = instId.split(separator: "-")
            if parts.count >= 2 {
                let product = CryptoProduct(
                    id: instId,
                    instId: instId, 
                    baseCcy: String(parts[0]), 
                    quoteCcy: String(parts[1])
                )
                
                defaultProducts.append(product)
            }
        }
        
        self.favoriteProducts = defaultProducts
        saveFavorites()
    }
    
    // 保存收藏列表
    func saveFavorites() {
        do {
            let data = try JSONEncoder().encode(favoriteProducts)
            UserDefaults.standard.set(data, forKey: favoritesKey)
            UserDefaults.standard.synchronize()
            logger.info("已保存 \(self.favoriteProducts.count) 个收藏产品")
        } catch {
            logger.error("保存收藏列表失败: \(error.localizedDescription)")
            errorMessage = "保存收藏列表失败"
        }
    }
    
    // 添加收藏
    func addFavorite(_ product: CryptoProduct) {
        // 检查是否已存在
        if !favoriteProducts.contains(where: { $0.instId == product.instId }) {
            // 获取更新的产品实例，确保价格信息完整
            var updatedProduct = product
            
            // 确定正确的产品类型
            let correctProductType = determineProductType(forInstId: product.instId)
            
            // 从主列表中找到最新数据
            if let latestProduct = products.first(where: { $0.instId == product.instId }) {
                // 使用最新价格数据
                updatedProduct = latestProduct
                
                // 确保产品类型正确
                if updatedProduct.productType != correctProductType {
                    logger.warning("添加收藏时修正产品类型: \(product.instId) 从 \(updatedProduct.productType.displayName) 到 \(correctProductType.displayName)")
                }
                
                // 创建带有正确产品类型的产品对象
                updatedProduct = CryptoProduct(
                    id: updatedProduct.id, 
                    instId: updatedProduct.instId, 
                    baseCcy: updatedProduct.baseCcy, 
                    quoteCcy: updatedProduct.quoteCcy, 
                    productType: correctProductType  // 使用正确的产品类型，而不是当前选择的类型
                )
                
                // 复制价格和其他数据
                updatedProduct.updatePrice(newPrice: latestProduct.currentPrice)
                updatedProduct.update24hData(
                    high: latestProduct.highPrice24h, 
                    low: latestProduct.lowPrice24h, 
                    changePercent: latestProduct.priceChangePercent24h
                )
                updatedProduct.updateOpenPrices(
                    utcOpen: latestProduct.utcOpenPrice, 
                    localOpen: latestProduct.localOpenPrice
                )
                
                // 确保添加到收藏列表时立即显示颜色
                if updatedProduct.previousPrice == updatedProduct.currentPrice && updatedProduct.currentPrice > 0 {
                    // 根据24小时价格变动百分比来决定颜色方向
                    if updatedProduct.priceChangePercent24h >= 0 {
                        // 价格上涨趋势，显示绿色
                        updatedProduct.setPreviousPrice(updatedProduct.currentPrice * 0.9999)
                    } else {
                        // 价格下跌趋势，显示红色
                        updatedProduct.setPreviousPrice(updatedProduct.currentPrice * 1.0001)
                    }
                }
            } else {
                // 如果在产品列表中找不到，确保使用正确的产品类型
                if updatedProduct.productType != correctProductType {
                    logger.warning("添加收藏时修正未在主列表找到的产品类型: \(product.instId) 从 \(updatedProduct.productType.displayName) 到 \(correctProductType.displayName)")
                }
                
                updatedProduct = CryptoProduct(
                    id: product.id, 
                    instId: product.instId, 
                    baseCcy: product.baseCcy, 
                    quoteCcy: product.quoteCcy, 
                    productType: correctProductType  // 使用从产品ID推断的正确类型
                )
                
                // 复制其他数据
                updatedProduct.updatePrice(newPrice: product.currentPrice)
                updatedProduct.update24hData(
                    high: product.highPrice24h, 
                    low: product.lowPrice24h, 
                    changePercent: product.priceChangePercent24h
                )
                updatedProduct.updateOpenPrices(
                    utcOpen: product.utcOpenPrice, 
                    localOpen: product.localOpenPrice
                )
            }
            
            // 添加到收藏列表
            favoriteProducts.append(updatedProduct)
            
            // 保存收藏
            saveFavorites()
            
            // 确保订阅
            if !subscribedProducts.contains(updatedProduct.instId) {
                logger.info("为新收藏产品 \(updatedProduct.instId) (\(updatedProduct.productType.displayName)) 创建WebSocket订阅")
                subscribeProduct(updatedProduct)
            }
            
            logger.info("已添加 \(updatedProduct.instId)(\(updatedProduct.productType.displayName)) 到收藏")
        }
    }
    
    // 移除收藏
    func removeFavorite(_ product: CryptoProduct) {
        // 移除收藏
        favoriteProducts.removeAll(where: { $0.instId == product.instId })
        
        // 保存更改
        saveFavorites()
        
        // 取消订阅
        if subscribedProducts.contains(product.instId) {
            logger.info("取消已移除收藏产品 \(product.instId) 的WebSocket订阅")
            unsubscribeProduct(product.instId)
        }
        
        logger.info("已从收藏中移除 \(product.instId)")
    }
    
    // 标记是否已注册刷新间隔观察者
    private var hasRegisteredRefreshIntervalObserver = false

    // 汇率刷新定时器
    private var exchangeRateTimer: Timer?

    // 更新定时器设置
    private func setupUpdateTimer() {
        // 使用AppSettings中的刷新间隔
        let refreshInterval = AppSettings.shared.refreshInterval

        // 取消旧的定时器
        updateTimer?.invalidate()
        updateTimer = nil

        logger.info("设置更新定时器，刷新间隔: \(refreshInterval) 秒")

        // 使用用户设置的间隔创建定时器 - 这个定时器控制定期数据刷新
        updateTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            self.logger.info("定时刷新触发: 间隔 \(refreshInterval) 秒")

            // 保存价格缓存
            self.savePriceCache()

            // 定期通过HTTP API获取最新价格，确保数据准确性
            if !self.favoriteProducts.isEmpty {
                self.logger.info("定时刷新: 通过HTTP API更新收藏产品数据")
                self.fetchLatestPricesViaHTTP()
            }

            // 如果WebSocket连接异常，尝试重连
            if self.connectionStatus != .connected {
                self.logger.info("WebSocket未连接，尝试重新连接")
                self.reconnect()
            }
        }

        // 只注册一次观察者，避免重复注册
        if !hasRegisteredRefreshIntervalObserver {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRefreshIntervalChanged),
                name: NSNotification.Name("RefreshIntervalChanged"),
                object: nil
            )
            hasRegisteredRefreshIntervalObserver = true
        }

        // 每两小时自动刷新一次汇率（只创建一次）
        if exchangeRateTimer == nil {
            exchangeRateTimer = Timer.scheduledTimer(withTimeInterval: 7200, repeats: true) { [weak self] _ in
                self?.fetchExchangeRate()
            }
        }
    }
    
    // 处理刷新间隔变化的方法
    @objc private func handleRefreshIntervalChanged() {
        let newInterval = AppSettings.shared.refreshInterval
        logger.info("检测到刷新间隔设置变更为 \(newInterval) 秒，重新设置定时器")

        // 确保在主线程上重新设置定时器
        if Thread.isMainThread {
            // 重新设置定时器
            setupUpdateTimer()

            // 立即触发一次刷新，让用户看到效果
            if !favoriteProducts.isEmpty {
                logger.info("设置变更后立即刷新数据")
                fetchLatestPricesViaHTTP()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.setupUpdateTimer()

                if !self.favoriteProducts.isEmpty {
                    self.logger.info("设置变更后立即刷新数据")
                    self.fetchLatestPricesViaHTTP()
                }
            }
        }
    }

    // 通过HTTP API获取最新价格（作为WebSocket的备用方案）
    private func fetchLatestPricesViaHTTP() {
        guard !favoriteProducts.isEmpty else { return }

        logger.info("通过HTTP API获取最新价格，共 \(self.favoriteProducts.count) 个产品")

        // 按产品类型分组获取数据
        let productsByType = Dictionary(grouping: favoriteProducts) { $0.productType }

        for (productType, products) in productsByType {
            // OKX API endpoint for ticker data - 获取该类型的所有产品
            let urlString = "https://www.okx.com/api/v5/market/tickers?instType=\(productType.rawValue)"

            guard let url = URL(string: urlString) else {
                logger.error("无效的API URL: \(urlString)")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10.0

            // 需要更新的产品ID集合
            let targetInstIds = Set(products.map { $0.instId })

            urlSession?.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                if let error = error {
                    self.logger.error("HTTP API请求失败 (\(productType.rawValue)): \(error.localizedDescription)")
                    return
                }

                guard let data = data else {
                    self.logger.error("HTTP API返回空数据 (\(productType.rawValue))")
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let dataArray = json["data"] as? [[String: Any]] {

                        var updatedCount = 0

                        DispatchQueue.main.async {
                            for productData in dataArray {
                                if let instId = productData["instId"] as? String,
                                   targetInstIds.contains(instId),
                                   let lastPriceStr = productData["last"] as? String,
                                   let lastPrice = Double(lastPriceStr) {

                                    // 更新对应产品的价格
                                    self.updateSingleFavoritePrice(instId: instId, newPrice: lastPrice)
                                    updatedCount += 1
                                }
                            }

                            self.logger.info("HTTP API更新了 \(updatedCount) 个 \(productType.rawValue) 产品价格")

                            // 通知UI更新
                            self.objectWillChange.send()
                            NotificationCenter.default.post(name: NSNotification.Name("PriceUpdated"), object: nil)
                        }
                    }
                } catch {
                    self.logger.error("解析HTTP API响应失败 (\(productType.rawValue)): \(error.localizedDescription)")
                }
            }.resume()
        }
    }
    
    // 加载缓存的汇率
    private func loadCachedExchangeRate() {
        if let timestamp = UserDefaults.standard.object(forKey: exchangeRateTimestampKey) as? Double,
           Date().timeIntervalSince1970 - timestamp < exchangeRateValidDuration,
           let rate = UserDefaults.standard.object(forKey: exchangeRateKey) as? Double,
           rate > 0 {
            usdCnyRate = rate
            logger.info("从缓存加载汇率: 1 USD = \(rate) CNY")
        } else {
            fetchExchangeRate()
        }
    }
    
    // 保存汇率到缓存
    private func saveExchangeRate(_ rate: Double) {
        UserDefaults.standard.set(rate, forKey: exchangeRateKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: exchangeRateTimestampKey)
        UserDefaults.standard.synchronize()
        logger.info("汇率已保存到缓存: 1 USD = \(rate) CNY")
    }
    
    // 获取最新汇率
    func fetchExchangeRate() {
        guard let url = URL(string: "https://www.okx.com/api/v5/market/exchange-rate") else {
            logger.error("无效的汇率API URL")
            return
        }
        
        logger.info("正在获取最新USD/CNY汇率...")
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("获取汇率失败: \(error.localizedDescription)")
                return
            }
            
            guard let data = data else {
                self.logger.error("获取汇率返回空数据")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArray = json["data"] as? [[String: Any]],
                   let firstItem = dataArray.first,
                   let rateStr = firstItem["usdCny"] as? String,
                   let rate = Double(rateStr) {
                    
                    DispatchQueue.main.async {
                        self.usdCnyRate = rate
                        self.saveExchangeRate(rate)
                        self.logger.info("已更新汇率: 1 USD = \(rate) CNY")
                        
                        // 通知UI更新
                        NotificationCenter.default.post(name: NSNotification.Name("DisplaySettingsChanged"), object: nil)
                    }
                } else {
                    self.logger.error("解析汇率数据失败")
                }
            } catch {
                self.logger.error("解析汇率JSON失败: \(error.localizedDescription)")
            }
        }
        
        task.resume()
    }
    
    // 重新排序收藏列表
    func reorderFavorites(_ newOrder: [CryptoProduct]) {
        // 验证新列表包含所有原始收藏项
        guard newOrder.count == favoriteProducts.count,
              Set(newOrder.map { $0.instId }) == Set(favoriteProducts.map { $0.instId }) else {
            logger.error("收藏列表重排序失败：新列表与原始列表不匹配")
            return
        }
        
        logger.info("重新排序收藏列表")
        
        // 更新列表
        favoriteProducts = newOrder
        
        // 保存到持久化存储
        saveFavorites()
        
        // 通知UI更新
        NotificationCenter.default.post(name: NSNotification.Name("FavoritesReordered"), object: nil)
    }
    
    // 获取单个产品的价格（针对不在主列表中的收藏产品）
    private func fetchSingleProductPrice(instId: String) {
        logger.info("尝试获取产品 \(instId) 的最新价格")
        
        // 构建API请求URL
        let baseUrl = "https://www.okx.com"
        let endpoint = "/api/v5/market/ticker"
        let queryItems = [URLQueryItem(name: "instId", value: instId)]
        
        var components = URLComponents(string: baseUrl + endpoint)
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            logger.error("无法构建API URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 创建并执行请求
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("获取产品价格失败: \(error.localizedDescription)")
                return
            }
            
            // 检查HTTP响应状态
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("获取产品价格请求失败: HTTP Status \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                return
            }
            
            // 解析响应数据
            guard let data = data else {
                self.logger.error("获取产品价格请求没有返回数据")
                return
            }
            
            do {
                // 解析JSON响应
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArray = json["data"] as? [[String: Any]],
                   let firstItem = dataArray.first {
                    
                    // 尝试提取价格
                    if let lastPriceStr = firstItem["last"] as? String,
                       let lastPrice = Double(lastPriceStr) {
                        
                        // 通过主线程更新价格
                        DispatchQueue.main.async {
                            self.updateProductPrice(instId: instId, newPrice: lastPrice)
                            self.logger.info("已更新产品 \(instId) 的价格: \(lastPrice)")
                        }
                    }
                }
            } catch {
                self.logger.error("解析价格数据失败: \(error.localizedDescription)")
            }
        }
        
        task.resume()
    }
}

// 连接状态枚举
enum ConnectionStatus: String {
    case disconnected = "已断开"
    case connecting = "连接中"
    case connected = "已连接"
    case failed = "连接失败"
} 