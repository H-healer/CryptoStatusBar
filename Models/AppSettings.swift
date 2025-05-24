import Foundation
import SwiftUI
import Combine
import ServiceManagement

class AppSettings: ObservableObject {
    // 单例模式
    static let shared = AppSettings()
    
    // 设置项
    @Published var currentDisplayProductID: String?
    @Published var refreshInterval: TimeInterval = 60.0
    @Published var colorCodePriceChanges: Bool = true
    @Published var notifyOnSignificantChanges: Bool = false
    @Published var significantChangeThreshold: Double = 5.0  // 百分比
    @Published var displayCurrency: String = "USD"
    @Published var useSystemAppearance: Bool = true
    @Published var appearance: ColorScheme = .light
    @Published var compactMode: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var showNetworkIndicator: Bool = true
    @Published var priceChangeCalculationMode: PriceChangeCalculationMode = .hours24  // 默认为24小时计算
    @Published var selectedProductType: String = ProductType.SPOT.rawValue  // 默认为币币
    @Published var priceColorScheme: PriceColorScheme = .international  // 默认为国际通用的红跌绿涨
    
    // 设置Key
    private let currentDisplayKey = "CurrentDisplayProduct"
    private let refreshIntervalKey = "RefreshInterval"
    private let colorCodePriceChangesKey = "ColorCodePriceChanges"
    private let notifyOnSignificantChangesKey = "NotifyOnSignificantChanges"
    private let significantChangeThresholdKey = "SignificantChangeThreshold"
    private let displayCurrencyKey = "DisplayCurrency"
    private let useSystemAppearanceKey = "UseSystemAppearance"
    private let appearanceKey = "AppearanceMode"
    private let compactModeKey = "CompactMode"
    private let launchAtLoginKey = "LaunchAtLogin"
    private let showNetworkIndicatorKey = "ShowNetworkIndicator"
    private let priceChangeCalculationModeKey = "PriceChangeCalculationMode"
    private let selectedProductTypeKey = "SelectedProductType"
    private let priceColorSchemeKey = "PriceColorScheme"
    
    // 禁止外部直接实例化
    private init() {
        loadSettings()
    }
    
    // 加载所有设置
    private func loadSettings() {
        currentDisplayProductID = UserDefaults.standard.string(forKey: currentDisplayKey)
        
        refreshInterval = UserDefaults.standard.double(forKey: refreshIntervalKey)
        if refreshInterval <= 0 {
            refreshInterval = 60.0  // 默认值
        }
        
        colorCodePriceChanges = UserDefaults.standard.bool(forKey: colorCodePriceChangesKey)
        
        notifyOnSignificantChanges = UserDefaults.standard.bool(forKey: notifyOnSignificantChangesKey)
        
        significantChangeThreshold = UserDefaults.standard.double(forKey: significantChangeThresholdKey)
        if significantChangeThreshold <= 0 {
            significantChangeThreshold = 5.0  // 默认值
        }
        
        if let currency = UserDefaults.standard.string(forKey: displayCurrencyKey) {
            displayCurrency = currency
        }
        
        // 外观设置
        useSystemAppearance = UserDefaults.standard.bool(forKey: useSystemAppearanceKey)
        if !useSystemAppearance {
            // 使用暗/亮模式
            let isDarkMode = UserDefaults.standard.bool(forKey: appearanceKey)
            appearance = isDarkMode ? .dark : .light
        }
        
        compactMode = UserDefaults.standard.bool(forKey: compactModeKey)
        
        launchAtLogin = UserDefaults.standard.bool(forKey: launchAtLoginKey)
        
        showNetworkIndicator = UserDefaults.standard.bool(forKey: showNetworkIndicatorKey)
        
        // 加载价格变动计算模式
        if let modeRawValue = UserDefaults.standard.string(forKey: priceChangeCalculationModeKey),
           let mode = PriceChangeCalculationMode(rawValue: modeRawValue) {
            priceChangeCalculationMode = mode
        }
        
        // 加载选择的产品类型
        if let typeRawValue = UserDefaults.standard.string(forKey: selectedProductTypeKey) {
            selectedProductType = typeRawValue
        }
        
        // 加载价格颜色方案
        if let schemeRawValue = UserDefaults.standard.string(forKey: priceColorSchemeKey),
           let scheme = PriceColorScheme(rawValue: schemeRawValue) {
            priceColorScheme = scheme
        }
    }
    
    // 保存当前显示的产品ID
    func saveCurrentDisplay(productID: String) {
        currentDisplayProductID = productID
        UserDefaults.standard.set(productID, forKey: currentDisplayKey)
        UserDefaults.standard.synchronize()
    }
    
    // 清除当前显示的产品ID
    func clearCurrentDisplay() {
        currentDisplayProductID = nil
        UserDefaults.standard.removeObject(forKey: currentDisplayKey)
        UserDefaults.standard.synchronize()
    }
    
    // 加载当前显示的产品ID
    func loadCurrentDisplayID() -> String? {
        // 直接从UserDefaults读取，而不是依赖内存中的属性
        // 这样可以确保即使在不同时机调用此方法，始终能获取到正确的值
        return UserDefaults.standard.string(forKey: currentDisplayKey)
    }
    
    // 保存刷新间隔
    func saveRefreshInterval(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: refreshIntervalKey)
        UserDefaults.standard.synchronize()
        
        // 发送通知，让服务更新定时器
        NotificationCenter.default.post(name: NSNotification.Name("RefreshIntervalChanged"), object: nil)
    }
    
    // 保存是否对价格变动进行颜色标记
    func saveColorCodeSetting(_ value: Bool) {
        colorCodePriceChanges = value
        UserDefaults.standard.set(value, forKey: colorCodePriceChangesKey)
        UserDefaults.standard.synchronize()
    }
    
    // 保存价格变动通知设置
    func saveNotificationSettings(enabled: Bool, threshold: Double) {
        notifyOnSignificantChanges = enabled
        significantChangeThreshold = threshold
        
        UserDefaults.standard.set(enabled, forKey: notifyOnSignificantChangesKey)
        UserDefaults.standard.set(threshold, forKey: significantChangeThresholdKey)
        UserDefaults.standard.synchronize()
    }
    
    // 保存显示货币
    func saveDisplayCurrency(_ currency: String) {
        displayCurrency = currency
        UserDefaults.standard.set(currency, forKey: displayCurrencyKey)
        UserDefaults.standard.synchronize()
        
        // 发送通知让应用更新显示
        NotificationCenter.default.post(name: NSNotification.Name("DisplaySettingsChanged"), object: nil)
    }
    
    // 保存外观设置
    func saveAppearanceSettings(useSystem: Bool, isDarkMode: Bool) {
        useSystemAppearance = useSystem
        appearance = isDarkMode ? .dark : .light
        
        UserDefaults.standard.set(useSystem, forKey: useSystemAppearanceKey)
        UserDefaults.standard.set(isDarkMode, forKey: appearanceKey)
        UserDefaults.standard.synchronize()
        
        // 发送外观设置变更通知
        NotificationCenter.default.post(name: NSNotification.Name("AppearanceSettingsChanged"), object: nil)
    }
    
    // 保存紧凑模式设置
    func saveCompactMode(_ value: Bool) {
        compactMode = value
        UserDefaults.standard.set(value, forKey: compactModeKey)
        UserDefaults.standard.synchronize()
    }
    
    // 保存开机启动设置
    func saveLaunchAtLogin(_ value: Bool) {
        launchAtLogin = value
        UserDefaults.standard.set(value, forKey: launchAtLoginKey)
        UserDefaults.standard.synchronize()
        
        // 实际设置开机启动（使用系统API）
        configureLaunchAtLogin(value)
    }
    
    // 保存网络指示器设置
    func saveShowNetworkIndicator(_ value: Bool) {
        showNetworkIndicator = value
        UserDefaults.standard.set(value, forKey: showNetworkIndicatorKey)
        UserDefaults.standard.synchronize()
    }
    
    // 保存价格变动计算模式
    func savePriceChangeCalculationMode(_ mode: PriceChangeCalculationMode) {
        priceChangeCalculationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: priceChangeCalculationModeKey)
        UserDefaults.standard.synchronize()
    }
    
    // 保存选择的产品类型
    func saveSelectedProductType(_ type: String) {
        selectedProductType = type
        UserDefaults.standard.set(type, forKey: selectedProductTypeKey)
        UserDefaults.standard.synchronize()
        
        // 发送通知让应用更新数据
        NotificationCenter.default.post(name: NSNotification.Name("ProductTypeChanged"), object: nil)
    }
    
    // 保存价格颜色方案
    func savePriceColorScheme(_ scheme: PriceColorScheme) {
        priceColorScheme = scheme
        UserDefaults.standard.set(scheme.rawValue, forKey: priceColorSchemeKey)
        UserDefaults.standard.synchronize()
    }
    
    // 获取当前选择的产品类型
    func getCurrentProductType() -> ProductType {
        if let type = ProductType(rawValue: selectedProductType) {
            return type
        }
        return .SPOT // 默认为币币
    }
    
    // 重置所有设置为默认值
    func resetToDefaults() {
        // 保留当前显示的产品ID
        let currentProduct = currentDisplayProductID
        
        // 重置所有设置键
        let keys = [
            refreshIntervalKey, colorCodePriceChangesKey, notifyOnSignificantChangesKey,
            significantChangeThresholdKey, displayCurrencyKey, useSystemAppearanceKey,
            appearanceKey, compactModeKey, launchAtLoginKey, showNetworkIndicatorKey,
            priceChangeCalculationModeKey, selectedProductTypeKey, priceColorSchemeKey
        ]
        
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        // 重新加载设置（会使用默认值）
        loadSettings()
        
        // 恢复当前显示的产品ID
        if let productID = currentProduct {
            saveCurrentDisplay(productID: productID)
        }
    }
    
    // 配置开机启动（使用系统API）
    private func configureLaunchAtLogin(_ enabled: Bool) {
        // 使用ServiceManagement框架
        let helperBundleName = "CryptoStatusBarLauncher"
        if #available(macOS 13, *) {
            // macOS 13及更高版本使用SMAppService
            do {
                let appService = SMAppService.mainApp
                if enabled {
                    try appService.register()
                } else {
                    try appService.unregister()
                }
            } catch {
                print("无法设置开机启动: \(error.localizedDescription)")
            }
        } else {
            // macOS 12及更低版本使用SMLoginItemSetEnabled
            let success = SMLoginItemSetEnabled(helperBundleName as CFString, enabled)
            print("设置开机启动\(success ? "成功" : "失败")")
        }
    }
    
    // 获取显示产品ID的键名
    func getCurrentDisplayKey() -> String {
        return currentDisplayKey
    }
}

// 价格变动计算模式
extension AppSettings {
    enum PriceChangeCalculationMode: String, CaseIterable {
        case hours24 = "24h"           // 过去24小时
        case todayUtc = "today_utc"    // 今日UTC时间
        case todayLocal = "today_cn"   // 今日北京时间

        var description: String {
            switch self {
            case .hours24:
                return "过去24小时"
            case .todayUtc:
                return "今日(UTC)"
            case .todayLocal:
                return "今日(北京时间)"
            }
        }
    }
}

// 价格颜色方案
extension AppSettings {
    enum PriceColorScheme: String, CaseIterable {
        case international = "International"  // 国际通用的红跌绿涨
        case chinese = "Chinese"              // 中国传统的红涨绿跌

        var description: String {
            switch self {
            case .international:
                return "国际通用(绿涨红跌)"
            case .chinese:
                return "中国传统(红涨绿跌)"
            }
        }
    }
} 