import Cocoa

/// 监控全局鼠标事件的工具类
class EventMonitor {
    // 事件监听器
    private var monitor: Any?
    
    // 监听的事件类型
    private let mask: NSEvent.EventTypeMask
    
    // 事件处理闭包
    private let handler: (NSEvent?) -> Void
    
    // 是否正在监听
    private(set) var isMonitoring = false
    
    /// 初始化事件监视器
    /// - Parameters:
    ///   - mask: 要监控的事件类型
    ///   - handler: 事件处理闭包
    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }
    
    /// 析构函数，确保停止监控
    deinit {
        stop()
    }
    
    /// 开始监控事件
    func start() {
        // 如果已经在监控，先停止
        if isMonitoring {
            stop()
        }
        
        // 开始全局事件监控
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self, self.isMonitoring else { return }
            self.handler(event)
        }
        
        isMonitoring = true
    }
    
    /// 停止监控事件
    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isMonitoring = false
    }
    
    /// 临时暂停监控
    func pause() {
        isMonitoring = false
    }
    
    /// 恢复监控（如果之前已启动）
    func resume() {
        if monitor != nil && !isMonitoring {
            isMonitoring = true
        } else if monitor == nil {
            start()
        }
    }
} 