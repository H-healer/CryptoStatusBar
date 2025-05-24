import Foundation
import Combine
import SwiftUI
import AppKit
import os.log

class StatusBarViewModel: ObservableObject {
    // 发布属性
    @Published var currentDisplayProduct: CryptoProduct?
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var errorMessage: String?
    
    // 服务依赖
    private weak var cryptoService: CryptoService?
    private let logger = Logger(subsystem: "com.cryptostatusbar", category: "StatusBarViewModel")
    
    // 订阅集合
    private var cancellables = Set<AnyCancellable>()
    
    // 状态栏颜色
    private var lastColorChangeTime: Date = Date()
    private let colorResetDelay: TimeInterval = 2.0  // 2秒后恢复颜色
    private var colorResetTimer: Timer?
    
    // 初始化
    init(cryptoService: CryptoService) {
        self.cryptoService = cryptoService
        setupBindings()
    }
    
    // 析构函数
    deinit {
        cleanup()
        logger.info("StatusBarViewModel已释放")
    }
    
    // 清理资源
    func cleanup() {
        // 停止定时器
        colorResetTimer?.invalidate()
        colorResetTimer = nil
        
        // 取消所有订阅
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        
        // 断开服务引用
        cryptoService = nil
    }
    
    // 设置数据绑定
    private func setupBindings() {
        guard let cryptoService = cryptoService else {
            logger.error("无法设置绑定：cryptoService为nil")
            return
        }
        
        // 监听收藏列表变化
        cryptoService.$favoriteProducts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] favorites in
                guard let self = self else { return }
                
                // 如果当前有显示的产品，但它已不在收藏列表中，选择新的显示产品
                if let current = self.currentDisplayProduct,
                   !favorites.contains(where: { $0.instId == current.instId }) {
                    logger.info("当前显示的币种已从收藏列表移除，需要选择新的显示币种")
                    self.selectNewDisplayProduct()
                    return
                }
                
                // 如果当前没有显示产品但收藏列表不为空，选择一个显示
                // 这种情况通常只会在首次启动时发生
                if self.currentDisplayProduct == nil && !favorites.isEmpty {
                    // 尝试从UserDefaults加载之前保存的选择
                    let currentDisplayKey = AppSettings.shared.getCurrentDisplayKey()
                    if let savedID = UserDefaults.standard.string(forKey: currentDisplayKey),
                       let product = favorites.first(where: { $0.instId == savedID }) {
                        // 使用保存的显示
                        logger.info("找到之前保存的显示币种: \(savedID)")
                        self.currentDisplayProduct = product
                    } else {
                        // 否则使用第一个
                        logger.info("当前没有显示币种但收藏列表不为空，选择第一个收藏币种显示")
                        self.selectNewDisplayProduct()
                    }
                }
            }
            .store(in: &cancellables)
            
        // 监听产品价格变化
        cryptoService.$products
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, let cryptoService = self.cryptoService else { return }
                
                // 如果当前有显示的产品，获取最新价格
                if let currentProduct = self.currentDisplayProduct {
                    if let updatedProduct = cryptoService.favoriteProducts.first(where: { $0.instId == currentProduct.instId }) {
                        if updatedProduct.currentPrice != currentProduct.currentPrice {
                            self.currentDisplayProduct = updatedProduct
                        }
                    }
                }
            }
            .store(in: &cancellables)
        
        // 监听连接状态变化
        cryptoService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.connectionStatus = status
                
                // 连接失败时向用户显示通知
                if status == .failed {
                    NotificationManager.shared.sendConnectionStatusNotification(
                        status: status, 
                        retryCount: self.cryptoService?.reconnectAttempts
                    )
                }
            }
            .store(in: &cancellables)
        
        // 监听错误消息
        cryptoService.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self = self else { return }
                self.errorMessage = message
                
                if let error = message, !error.isEmpty {
                    NotificationManager.shared.sendErrorNotification(
                        title: "发生错误",
                        message: error
                    )
                }
            }
            .store(in: &cancellables)
        
        // 不再在初始化时自动加载上次显示的产品
        // 现在由AppDelegate控制加载时机
    }
    
    // 加载上次显示的产品
    func loadLastDisplayProduct() {
        guard let cryptoService = cryptoService else {
            logger.error("无法加载上次显示的产品：cryptoService为nil")
            return
        }
        
        logger.info("开始尝试加载上次显示的产品，当前收藏数量: \(cryptoService.favoriteProducts.count)")
        
        // 从AppSettings获取键名，确保一致性
        let currentDisplayKey = AppSettings.shared.getCurrentDisplayKey()
        // 直接从UserDefaults读取，避免任何中间状态问题
        let savedID = UserDefaults.standard.string(forKey: currentDisplayKey)
        logger.info("从UserDefaults直接加载的上次显示产品ID: \(savedID ?? "nil")，使用键: \(currentDisplayKey)")
        
        if let savedID = savedID,
           let product = cryptoService.favoriteProducts.first(where: { $0.instId == savedID }) {
            self.currentDisplayProduct = product
            logger.info("成功加载上次显示的产品: \(product.instId)，价格: \(product.formattedPrice)")
        } else if !cryptoService.favoriteProducts.isEmpty {
            // 只有在没有上次显示记录时，才选择第一个产品
            // 增加日志以便排查问题
            logger.warning("未能找到上次显示产品记录或该产品已不在收藏中，savedID: \(savedID ?? "nil")")
            
            if savedID != nil {
                // 列出所有收藏的产品ID，帮助调试
                let favoriteIds = cryptoService.favoriteProducts.map { $0.instId }.joined(separator: ", ")
                logger.info("当前所有收藏的产品: \(favoriteIds)")
            }
            
            selectNewDisplayProduct()
        } else {
            logger.warning("收藏列表为空，无法加载或选择显示产品")
        }
    }
    
    // 选择新的显示产品
    func selectNewDisplayProduct() {
        guard let cryptoService = cryptoService else { return }
        
        if let firstProduct = cryptoService.favoriteProducts.first {
            self.currentDisplayProduct = firstProduct
            
            // 保存显示选择
            if let product = self.currentDisplayProduct {
                AppSettings.shared.saveCurrentDisplay(productID: product.instId)
                logger.info("已选择新的显示产品: \(product.instId)")
            }
        } else {
            self.currentDisplayProduct = nil
            AppSettings.shared.clearCurrentDisplay()
            logger.warning("没有收藏产品可显示")
        }
    }
    
    // 手动选择显示产品
    func selectDisplayProduct(_ product: CryptoProduct) {
        // 确保在主线程执行UI更新
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.selectDisplayProduct(product)
            }
            return
        }
        
        // 只有在产品变化时才更新
        if self.currentDisplayProduct?.instId != product.instId {
            // 设置新值
            self.currentDisplayProduct = product
            
            // 保存设置
            AppSettings.shared.saveCurrentDisplay(productID: product.instId)
            logger.info("用户选择显示产品: \(product.instId)")
        }
    }
    
    // 获取状态栏标题
    func getStatusBarTitle() -> String {
        if let product = currentDisplayProduct {
            return "\(product.baseCcy)" // 只需返回币种名称，价格将在attributedString中格式化
        } else {
            return connectionStatus == .connected ? "未选择" : connectionStatus.rawValue
        }
    }
    
    // 获取状态栏属性
    func getStatusBarAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        
        // 基本字体设置
        attributes[.font] = NSFont.systemFont(
            ofSize: AppSettings.shared.compactMode ? 10 : 12,
            weight: .medium
        )
        
        return attributes
    }
    
    // 刷新所有价格
    func refreshPrices() {
        guard let cryptoService = cryptoService else { return }
        
        // 刷新收藏价格
        cryptoService.refreshFavoriteProducts()
    }
} 