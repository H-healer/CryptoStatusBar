import SwiftUI
import AppKit
import Combine
import os.log

@main
struct CryptoStatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // 状态栏相关属性
    private var statusBarItem: NSStatusItem?
    
    // 服务和模型
    private let cryptoService = CryptoService.shared // 使用共享实例
    private lazy var statusBarViewModel = StatusBarViewModel(cryptoService: cryptoService)
    
    // 弹出窗口和控制器
    private var popover: NSPopover?
    private var eventMonitor: EventMonitor?
    private var settingsWindow: NSWindow?
    
    // 订阅管理
    private var cancellables = Set<AnyCancellable>()
    
    // 日志系统
    private let logger = Logger(subsystem: "com.cryptostatusbar", category: "AppDelegate")
    
    // 节流机制相关变量
    private var lastStatusBarUpdateTime = Date()
    private let statusBarUpdateThreshold: TimeInterval = 0.2 // 降低到0.2秒
    
    // 应用启动
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("应用程序启动")
        
        // 初始化通知管理器，请求通知权限
        let notificationManager = NotificationManager.shared
        notificationManager.requestAuthorization()
        logger.info("已初始化通知管理器")
        
        // 如果用户已开启开机启动设置，尝试设置应用为登录项
        if AppSettings.shared.launchAtLogin {
            AppSettings.shared.saveLaunchAtLogin(true)
        }
        
        // 设置状态栏
        setupStatusBar()
        
        // 初始化弹出窗口和事件监控
        setupPopover()
        
        // 初始化加密货币服务
        cryptoService.initialize()
        
        // 添加收藏列表更新的观察者
        cryptoService.$favoriteProducts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] favorites in
                guard let self = self else { return }
                self.updateFavoritesMenu()
            }
            .store(in: &cancellables)
        
        // 添加价格更新的观察者
        cryptoService.$products
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusBarDisplay()
                self?.updateFavoritesMenu()
            }
            .store(in: &cancellables)
        
        // 监听状态栏视图模型的变化
        statusBarViewModel.$currentDisplayProduct
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusBarDisplay()
                self?.updateFavoritesMenu() // 确保菜单中的选中状态正确
            }
            .store(in: &cancellables)
            
        // 监听设置变化的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: NSNotification.Name("DisplaySettingsChanged"),
            object: nil
        )
        
        // 监听收藏列表重排序的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFavoritesReordered),
            name: NSNotification.Name("FavoritesReordered"),
            object: nil
        )
        
        // 打印当前设置，用于调试
        let currentDisplayKey = AppSettings.shared.getCurrentDisplayKey()
        let savedID = UserDefaults.standard.string(forKey: currentDisplayKey)
        logger.info("应用启动完成，当前保存的显示ID: \(savedID ?? "无")")
    }
    
    // 应用即将退出
    func applicationWillTerminate(_ notification: Notification) {
        logger.info("应用程序即将退出，开始清理资源")
        
        // 简单地使用下一个运行循环延迟关闭操作
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            // 在此处不尝试直接访问定时器
            // 让CryptoService自己处理定时器清理
        }
        
        // 停止网络连接并保存缓存
        cryptoService.cleanup()
        
        // 停止事件监控
        eventMonitor?.stop()
        eventMonitor = nil
        
        // 移除通知中心观察者
        NotificationCenter.default.removeObserver(self)
        
        // 清理所有取消令牌
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        
        // 强制清理内存占用较大的视图资源
        if let popover = popover {
            // 替换为空视图
            let emptyVC = NSViewController()
            emptyVC.view = NSView(frame: NSRect.zero)
            popover.contentViewController = emptyVC
            popover.close()
            self.popover = nil
        }
        
        // 关闭设置窗口
        if let window = settingsWindow {
            window.contentViewController = nil
            window.close()
        settingsWindow = nil
        }
        
        // 释放状态栏资源
        statusBarItem = nil
        
        // 清空视图模型引用
        statusBarViewModel = StatusBarViewModel(cryptoService: CryptoService.shared)
        
        // 强制运行一次自动释放池
        autoreleasepool {
            URLCache.shared.removeAllCachedResponses()
        }
        
        logger.info("资源清理完成，应用程序退出")
    }
    
    // 设置状态栏
    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusBarItem?.button {
            button.title = "加载中..."
            
            // 不再使用定时器进行频繁更新
            // 而是依赖statusBarViewModel数据变化自动触发
            
            // 通过监听价格更新通知来更新状态栏
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePriceUpdated),
                name: NSNotification.Name("PriceUpdated"),
                object: nil
            )
            
            // 移除固定的1秒定时器，改为监听设置变化来动态调整
            // 状态栏显示更新现在完全依赖数据变化触发，而不是定时器
    
            // 设置菜单
            setupMenu()
        }
    }
    
    // 设置菜单
    private func setupMenu() {
        let menu = NSMenu()
        
        // 使用SwiftUI的MenuBarExtra创建高级菜单
        
        // 添加收藏产品子菜单
        let favoritesMenu = NSMenu()
        let favoritesItem = NSMenuItem(title: "收藏", action: nil, keyEquivalent: "")
        favoritesItem.submenu = favoritesMenu
        menu.addItem(favoritesItem)
        
        // 添加当前价格信息
        menu.addItem(NSMenuItem.separator())
        let priceInfoItem = NSMenuItem(title: "价格详情", action: nil, keyEquivalent: "")
        priceInfoItem.isEnabled = false
        menu.addItem(priceInfoItem)
        
        // 添加"管理收藏"菜单项
        menu.addItem(NSMenuItem(title: "管理收藏...", action: #selector(showProductList), keyEquivalent: "m"))
        
        // 添加设置菜单项
        menu.addItem(NSMenuItem(title: "设置...", action: #selector(showSettings), keyEquivalent: ","))
        
        // 添加分隔线和功能菜单项
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "刷新", action: #selector(refreshPrices), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusBarItem?.menu = menu
        
        // 初次填充收藏菜单
        updateFavoritesMenu()
    }
    
    // 初始化弹出窗口
    private func setupPopover() {
        // 创建弹出窗口
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.animates = true
        
        // 设置弹出窗口外观 - 根据用户设置或系统设置
        updatePopoverAppearance()
        
        // 设置弹出窗口内容边距
        popover?.contentSize = NSSize(width: 400, height: 500)
        
        // 添加关闭通知监听
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverWillClose(_:)),
            name: NSPopover.willCloseNotification,
            object: popover
        )
        
        // 监听外观设置变更
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChanged),
            name: NSNotification.Name("AppearanceSettingsChanged"),
            object: nil
        )
        
        // 初始化事件监视器但不启动
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self, let popover = self.popover, popover.isShown {
                popover.close()
            }
        }
    }
    
    // 更新弹出窗口外观
    private func updatePopoverAppearance() {
        if #available(macOS 10.14, *) {
            let settings = AppSettings.shared
            
            if settings.useSystemAppearance {
                // 使用系统外观设置
                popover?.appearance = nil // 使用系统默认
            } else {
                // 使用用户选择的外观设置
                let isDark = settings.appearance == .dark
                popover?.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
            }
        }
    }
    
    // 处理外观设置变更
    @objc private func handleAppearanceChanged() {
        // 更新弹出窗口外观
        updatePopoverAppearance()
        
        // 更新设置窗口的外观
        updateSettingsWindowAppearance()
    }
    
    // 更新设置窗口的外观
    private func updateSettingsWindowAppearance() {
        guard let window = settingsWindow else { return }
        
        let settings = AppSettings.shared
        
        if settings.useSystemAppearance {
            // 使用系统外观设置
            window.appearance = nil
        } else {
            // 使用用户选择的外观设置
            let isDark = settings.appearance == .dark
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        }
    }
    
    // 处理弹出窗口关闭
    @objc private func popoverWillClose(_ notification: Notification) {
        // 停止事件监控
        eventMonitor?.stop()
        
        // 立即释放视图资源
        DispatchQueue.main.async {
            self.forceCleanupPopoverResources()
    }
    
        // 记录关闭事件
        logger.info("弹出窗口已关闭")
    }
    
    // 强制清理弹出窗口资源
    private func forceCleanupPopoverResources() {
        // 确保在主线程上执行
        assert(Thread.isMainThread, "必须在主线程上调用")
        
        if let popover = popover {
            // 替换为空视图控制器
            let emptyVC = NSViewController()
            emptyVC.view = NSView(frame: NSRect.zero)
            popover.contentViewController = emptyVC
            
            // 强制运行自动释放池，帮助释放资源
            autoreleasepool {
                // 强制GC - 使用最小尺寸的视图代替nil
                emptyVC.view = NSView(frame: NSRect.zero)
                NSApp.windows.forEach { window in
                    if window.isKind(of: NSPanel.self) && !window.isVisible {
                        window.close()
                    }
                }
            }
        }
    }
    
    // 更新状态栏显示
    private func updateStatusBarDisplay() {
        guard let button = statusBarItem?.button else { return }
        
        // 获取当前产品
        if let product = statusBarViewModel.currentDisplayProduct {
            // 获取价格字符串和价格颜色
            let priceString = product.formattedPrice
            var textColor = NSColor.labelColor
            
            // 如果启用了颜色标记，应用颜色
            if AppSettings.shared.colorCodePriceChanges {
                let direction = product.priceChangeDirection
                let colorScheme = AppSettings.shared.priceColorScheme
                
                if direction == .up {
                    textColor = colorScheme == .chinese ? .systemRed : .systemGreen
                } else if direction == .down {
                    textColor = colorScheme == .chinese ? .systemGreen : .systemRed
                }
            }
        
            // 创建固定宽度的属性文本
            let attributedString = NSMutableAttributedString(
                string: "\(product.baseCcy) ",
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
            
            // 添加价格部分(等宽字体)
            let attributedPrice = NSAttributedString(
                string: priceString,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: textColor
                ]
            )
            attributedString.append(attributedPrice)
        
        // 如果启用了网络状态指示器并且连接状态不是已连接，则显示状态指示器
        if AppSettings.shared.showNetworkIndicator && 
           statusBarViewModel.connectionStatus != .connected {
            // 添加连接状态指示器
            let statusSymbol = "●"
            let statusAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: statusColor,
                .baselineOffset: 2
            ]
            
            let statusIndicator = NSAttributedString(string: " \(statusSymbol)", attributes: statusAttributes)
                attributedString.append(statusIndicator)
            }
            
            button.attributedTitle = attributedString
        } else {
            // 未选择产品
            button.title = "选择币种"
        }
    }
    
    // 获取连接状态颜色
    private var statusColor: NSColor {
        switch statusBarViewModel.connectionStatus {
        case .connected:
            return .systemGreen
        case .connecting:
            return .systemYellow
        case .disconnected:
            return .systemGray
        case .failed:
            return .systemRed
        }
    }
    
    // 更新收藏产品菜单
    private func updateFavoritesMenu() {
        guard let menu = statusBarItem?.menu, 
              let favoritesItem = menu.item(at: 0), 
              let favoritesMenu = favoritesItem.submenu else { return }
        
        favoritesMenu.removeAllItems()
        
        // 获取当前显示的币种ID
        let currentId = statusBarViewModel.currentDisplayProduct?.instId
        
        if cryptoService.favoriteProducts.isEmpty {
            let emptyItem = NSMenuItem(title: "没有收藏的产品", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            favoritesMenu.addItem(emptyItem)
        } else {
            // 按产品类型对收藏分组
            let grouped = Dictionary(grouping: cryptoService.favoriteProducts) { $0.productType }
            
            // 添加产品类型分隔线和分组项
            for productType in ProductType.allCases {
                // 只添加包含该类型产品的分组
                if let products = grouped[productType], !products.isEmpty {
                    // 添加产品类型分隔标题
                    let typeItem = NSMenuItem(title: productType.displayName, action: nil, keyEquivalent: "")
                    typeItem.isEnabled = false
                    typeItem.attributedTitle = NSAttributedString(
                        string: productType.displayName,
                        attributes: [
                            .font: NSFont.boldSystemFont(ofSize: 12),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    
                    favoritesMenu.addItem(typeItem)
                    
                    // 添加该类型的所有收藏
                    for product in products {
                        // 使用等宽字体创建菜单项
                        let menuItem = NSMenuItem(title: "", action: #selector(selectProduct(_:)), keyEquivalent: "")
                        menuItem.representedObject = product
                        
                        // 创建带等宽字体的属性字符串
                        let attributedTitle = NSMutableAttributedString(
                            string: "\(product.baseCcy): ",
                            attributes: [.font: NSFont.systemFont(ofSize: 13)]
                        )
                        
                        // 添加等宽字体显示的价格
                        let priceText = product.formattedPrice
                        let priceAttrString = NSAttributedString(
                            string: priceText,
                            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]
                        )
                        attributedTitle.append(priceAttrString)
                        
                        menuItem.attributedTitle = attributedTitle
                        
                        // 添加选择标记
                        if product.instId == currentId {
                            menuItem.state = .on
                        } else {
                            menuItem.state = .off
                        }
                        
                        favoritesMenu.addItem(menuItem)
                    }
                    
                    // 如果不是最后一个分组，添加分隔线
                    if productType != ProductType.allCases.last {
                        favoritesMenu.addItem(NSMenuItem.separator())
                    }
                }
            }
        }
        
        // 更新价格信息项
        if let infoItem = menu.item(at: 2) {
            if let product = statusBarViewModel.currentDisplayProduct {
                // 获取产品信息
                let baseCcy = product.baseCcy
                let productTypeName = product.productType.displayName
                
                // 使用NumberFormatter直接展示API返回的价格，保持原始精度
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 12
                
                // 使用等宽字体格式化高低价格
                let highPrice = formatter.string(from: NSNumber(value: product.highPrice24h)) ?? String(describing: product.highPrice24h)
                let lowPrice = formatter.string(from: NSNumber(value: product.lowPrice24h)) ?? String(describing: product.lowPrice24h)
                
                let changePercent = product.formattedPriceChangePercent(mode: AppSettings.shared.priceChangeCalculationMode)
                
                // 判断价格变动方向
                let priceChangeMode = AppSettings.shared.priceChangeCalculationMode
                let percentChange = product.getPriceChangePercent(mode: priceChangeMode)
                
                // 创建属性文本
                let fullText = "\(baseCcy)(\(productTypeName)): ⬆︎\(highPrice) ⬇︎\(lowPrice) \(changePercent)"
                let attributedString = NSMutableAttributedString(string: fullText)
                
                // 设置等宽字体属性
                if let highRange = fullText.range(of: highPrice) {
                    let nsHighRange = NSRange(highRange, in: fullText)
                    attributedString.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), range: nsHighRange)
                }
                
                if let lowRange = fullText.range(of: lowPrice) {
                    let nsLowRange = NSRange(lowRange, in: fullText)
                    attributedString.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), range: nsLowRange)
                }
                
                // 定位百分比变化的位置
                if let percentRange = fullText.range(of: changePercent) {
                    let nsRange = NSRange(percentRange, in: fullText)
                    
                    // 颜色方案
                    let colorScheme = AppSettings.shared.priceColorScheme
                    let textColor: NSColor
                    
                    if percentChange > 0 {
                        textColor = colorScheme == .chinese ? NSColor.systemRed : NSColor.systemGreen
                    } else if percentChange < 0 {
                        textColor = colorScheme == .chinese ? NSColor.systemGreen : NSColor.systemRed
                    } else {
                        textColor = NSColor.secondaryLabelColor
                    }
                    
                    // 应用颜色和等宽字体
                    attributedString.addAttributes([
                        .foregroundColor: textColor,
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                    ], range: nsRange)
                }
                
                // 设置属性文本
                infoItem.attributedTitle = attributedString
            } else {
                infoItem.title = "未选择显示产品"
            }
        }
    }
    
    // 显示产品列表
    @objc private func showProductList() {
        guard let button = statusBarItem?.button else { return }
        
        // 如果弹出窗口已经显示，只是关闭它
        if let popover = popover, popover.isShown {
            popover.close()
            return
        }
        
        // 每次显示前确保无残留资源
        eventMonitor?.stop()
        
        // 强制内存回收
        autoreleasepool {
            // 完全重新创建内容视图，隔离上下文
            let contentView = ProductListView(
                cryptoService: cryptoService,
                statusBarViewModel: statusBarViewModel
            )
            .environmentObject(AppSettings.shared)
            
            let hostingController = NSHostingController(rootView: contentView)
            popover?.contentViewController = hostingController
            
            // 配置弹出窗口大小
            popover?.contentSize = NSSize(width: 400, height: 500)
            
            // 应用当前外观设置
            updatePopoverAppearance()
            
            // 计算合适的位置，确保不被菜单栏遮挡
            let screenHeight = NSScreen.main?.frame.height ?? 800
            let statusBarHeight = NSStatusBar.system.thickness
            
            // 如果状态栏在底部，弹出窗口向上显示；如果在顶部，向下显示
            let preferredEdge: NSRectEdge = (statusBarHeight < screenHeight / 2) ? .maxY : .minY
            
            // 启动事件监视器
            eventMonitor?.start()
            
            // 显示弹出窗口
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: preferredEdge)
            
            // 记录打开事件
            logger.info("弹出窗口已显示")
        }
    }
    
    // 显示设置窗口
    @objc private func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(cryptoService: cryptoService)
                .environmentObject(AppSettings.shared)
            
            let hostingController = NSHostingController(rootView: settingsView)
            
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            
            settingsWindow?.title = "设置"
            settingsWindow?.center()
            settingsWindow?.setFrameAutosaveName("设置窗口")
            settingsWindow?.contentViewController = hostingController
            settingsWindow?.isReleasedWhenClosed = false
            
            // 应用用户设置的外观
            updateSettingsWindowAppearance()
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // 选择产品显示在菜单栏
    @objc private func selectProduct(_ sender: NSMenuItem) {
        guard let product = sender.representedObject as? CryptoProduct else { return }
        
        // 确保在主线程执行UI更新
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.selectProduct(sender)
            }
            return
        }
        
        // 设置为菜单栏显示产品
        statusBarViewModel.selectDisplayProduct(product)
        
        // 更新菜单状态
        updateFavoritesMenu()
        
        // 即时更新状态栏显示
        updateStatusBarDisplay()
        }
    
    // 刷新价格
    @objc private func refreshPrices() {
        // 手动重连
        if cryptoService.connectionStatus != .connected {
            cryptoService.reconnect()
        }
        
        // 刷新价格
        statusBarViewModel.refreshPrices()
        
        // 即时更新UI
        updateStatusBarDisplay()
        updateFavoritesMenu()
        }
        
    // 退出应用
    @objc private func quitApp() {
        // 准备退出
        logger.info("用户请求退出应用")
        
        // 清理资源并退出
        applicationWillTerminate(Notification(name: .init("UserQuit")))
        
        // 退出应用
        NSApp.terminate(nil)
    }
    
    // 处理设置变更通知
    @objc private func handleSettingsChanged() {
        logger.info("检测到显示设置变更，正在刷新")
        
        // 强制刷新数据
        cryptoService.refreshFavoriteProducts()
        
        // 更新状态栏和菜单
        updateStatusBarDisplay()
        updateFavoritesMenu()
    }
    
    // 处理收藏列表重排序的通知
    @objc private func handleFavoritesReordered() {
        logger.info("检测到收藏列表重排序，正在刷新")
        
        // 强制刷新数据
        cryptoService.refreshFavoriteProducts()
        
        // 更新状态栏和菜单
        updateStatusBarDisplay()
        updateFavoritesMenu()
    }
    
    // 添加价格更新通知处理方法
    @objc private func handlePriceUpdated(_ notification: Notification) {
        // 当收到价格更新通知时，更新状态栏
        // 这种方式比定时器轮询更高效
        updateStatusBarDisplay()
    }
} 