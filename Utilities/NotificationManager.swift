import Foundation
import UserNotifications
import os.log

class NotificationManager {
    // 单例模式
    static let shared = NotificationManager()
    
    // 日志记录器
    private let logger = Logger(subsystem: "com.cryptostatusbar", category: "NotificationManager")
    
    // 通知中心
    private let notificationCenter = UNUserNotificationCenter.current()
    
    // 通知分类标识
    private let priceChangeCategory = "PRICE_CHANGE"
    private let errorCategory = "ERROR"
    private let infoCategory = "INFO"
    
    // 通知权限状态
    private var isNotificationAuthorized = false
    
    // 私有初始化方法
    private init() {
        setupNotifications()
    }
    
    // 设置通知
    private func setupNotifications() {
        // 定义通知分类
        let priceChangeCategory = UNNotificationCategory(
            identifier: priceChangeCategory,
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let errorCategory = UNNotificationCategory(
            identifier: errorCategory,
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let infoCategory = UNNotificationCategory(
            identifier: infoCategory,
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        // 注册通知分类
        notificationCenter.setNotificationCategories([
            priceChangeCategory,
            errorCategory,
            infoCategory
        ])
        
        // 请求授权
        requestAuthorization()
    }
    
    // 请求通知权限
    func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self = self else { return }
            
            self.isNotificationAuthorized = granted
            
            if granted {
                self.logger.info("用户已授权通知权限")
            } else {
                self.logger.error("用户拒绝通知权限: \(String(describing: error?.localizedDescription))")
            }
        }
    }
    
    // 检查通知权限
    func checkNotificationStatus(completion: @escaping (Bool) -> Void) {
        notificationCenter.getNotificationSettings { settings in
            let isAuthorized = settings.authorizationStatus == .authorized
            self.isNotificationAuthorized = isAuthorized
            completion(isAuthorized)
        }
    }
    
    // 发送价格变动通知
    func sendPriceChangeNotification(for product: CryptoProduct, percentChange: Double, previousPrice: Double) {
        guard isNotificationAuthorized else {
            logger.warning("无法发送通知：未获得通知权限")
            return
        }
        
        // 设置通知内容
        let content = UNMutableNotificationContent()
        
        // 设置标题和正文
        let changeDirection = percentChange >= 0 ? "上涨" : "下跌"
        let absChange = abs(percentChange)
        
        content.title = "\(product.baseCcy) 价格\(changeDirection)提醒"
        content.body = "\(product.baseCcy) 价格在短时间内\(changeDirection)了 \(String(format: "%.2f", absChange))%\n" +
                      "从 \(String(format: "%.2f", previousPrice)) 变为 \(String(format: "%.2f", product.currentPrice))"
        
        // 设置声音和分类
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = priceChangeCategory
        
        // 设置用户信息，可以在点击通知时使用
        content.userInfo = [
            "productId": product.instId,
            "baseCcy": product.baseCcy,
            "currentPrice": product.currentPrice,
            "previousPrice": previousPrice,
            "percentChange": percentChange
        ]
        
        // 创建通知请求
        let request = UNNotificationRequest(
            identifier: "price-change-\(product.instId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // 立即触发
        )
        
        // 添加通知请求
        notificationCenter.add(request) { error in
            if let error = error {
                self.logger.error("发送价格变动通知失败: \(error.localizedDescription)")
            } else {
                self.logger.info("已发送 \(product.baseCcy) 价格变动通知，变动：\(percentChange)%")
            }
        }
    }
    
    // 发送连接状态变化通知
    func sendConnectionStatusNotification(status: ConnectionStatus, retryCount: Int? = nil) {
        guard isNotificationAuthorized else { return }
        
        // 只有在连接失败时才发送通知
        guard status == .failed else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "连接失败"
        
        if let retryCount = retryCount {
            content.body = "与服务器的连接已断开，已尝试重连 \(retryCount) 次。请检查网络连接。"
        } else {
            content.body = "与服务器的连接已断开。请检查网络连接。"
        }
        
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = errorCategory
        
        let request = UNNotificationRequest(
            identifier: "connection-status-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                self.logger.error("发送连接状态通知失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 发送一般信息通知
    func sendInfoNotification(title: String, message: String) {
        guard isNotificationAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = infoCategory
        
        let request = UNNotificationRequest(
            identifier: "info-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                self.logger.error("发送信息通知失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 发送错误通知
    func sendErrorNotification(title: String, message: String) {
        guard isNotificationAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = errorCategory
        
        let request = UNNotificationRequest(
            identifier: "error-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                self.logger.error("发送错误通知失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 删除所有未发出的通知
    func removeAllPendingNotifications() {
        notificationCenter.removeAllPendingNotificationRequests()
        logger.info("已移除所有待发送的通知")
    }
    
    // 删除所有已发出的通知
    func removeAllDeliveredNotifications() {
        notificationCenter.removeAllDeliveredNotifications()
        logger.info("已移除所有已发送的通知")
    }
} 