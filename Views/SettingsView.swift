import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @ObservedObject var cryptoService: CryptoService
    @Environment(\.presentationMode) var presentationMode
    
    // 临时状态变量
    @State private var notifyOnChanges = false
    @State private var changeThreshold = 5.0
    @State private var refreshInterval = 60.0
    @State private var useSystemAppearance = true
    @State private var darkMode = false
    @State private var colorCodeChanges = true
    @State private var compactMode = false
    @State private var launchAtLogin = false
    @State private var showNetworkIndicator = true
    @State private var displayCurrency = "USD"
    @State private var priceChangeMode = AppSettings.PriceChangeCalculationMode.hours24
    @State private var priceColorScheme = AppSettings.PriceColorScheme.international
    
    // 设置模块的统一宽度
    private let moduleWidth: CGFloat = 360
    
    // 初始化
    init(cryptoService: CryptoService) {
        self.cryptoService = cryptoService
        
        // 在init中读取设置值
        let settings = AppSettings.shared
        _notifyOnChanges = State(initialValue: settings.notifyOnSignificantChanges)
        _changeThreshold = State(initialValue: settings.significantChangeThreshold)
        _refreshInterval = State(initialValue: settings.refreshInterval)
        _useSystemAppearance = State(initialValue: settings.useSystemAppearance)
        _darkMode = State(initialValue: settings.appearance == .dark)
        _colorCodeChanges = State(initialValue: settings.colorCodePriceChanges)
        _compactMode = State(initialValue: settings.compactMode)
        _launchAtLogin = State(initialValue: settings.launchAtLogin)
        _showNetworkIndicator = State(initialValue: settings.showNetworkIndicator)
        _displayCurrency = State(initialValue: settings.displayCurrency)
        _priceChangeMode = State(initialValue: settings.priceChangeCalculationMode)
        _priceColorScheme = State(initialValue: settings.priceColorScheme)
    }
    
    var body: some View {
        // 使用VStack而不是NavigationView，避免默认的分栏布局
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Text("应用设置")
                    .font(.headline)
                    .padding()
                Spacer()
                Button("完成") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(BorderlessButtonStyle())
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            
            // 使用ScrollView和VStack替代Form，更好地控制宽度
            ScrollView {
                VStack(spacing: 16) {
                    // 显示设置
                    GroupBox(label: Text("显示设置").font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("紧凑模式", isOn: $compactMode)
                                .onChange(of: compactMode) { newValue in
                                    settings.saveCompactMode(newValue)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("显示货币单位")
                                Picker("", selection: $displayCurrency) {
                                    Text("USD").tag("USD")
                                    Text("CNY").tag("CNY")
                                    Text("不显示").tag("")
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .labelsHidden()
                                .onChange(of: displayCurrency) { newValue in
                                    settings.saveDisplayCurrency(newValue)
                                    // 额外触发刷新
                                    NotificationCenter.default.post(name: NSNotification.Name("DisplaySettingsChanged"), object: nil)
                                }
                                
                                // 如果选择CNY，显示汇率信息和刷新按钮
                                if displayCurrency == "CNY" {
                                    HStack {
                                        Text("当前汇率: 1 USD = \(String(format: "%.3f", CryptoService.shared.usdCnyRate)) CNY")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            CryptoService.shared.fetchExchangeRate()
                                        }) {
                                            Label("刷新", systemImage: "arrow.clockwise")
                                                .font(.footnote)
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                    }
                                }
                            }
                            
                            Toggle("价格变动使用颜色显示", isOn: $colorCodeChanges)
                                .onChange(of: colorCodeChanges) { newValue in
                                    settings.saveColorCodeSetting(newValue)
                                }
                                
                            // 价格颜色方案，不再根据colorCodeChanges条件显示
                            VStack(alignment: .leading, spacing: 6) {
                                Text("价格涨跌颜色方案")
                                Picker("", selection: $priceColorScheme) {
                                    ForEach(AppSettings.PriceColorScheme.allCases, id: \.self) { scheme in
                                        Text(scheme == .chinese ? "红涨绿跌(中国风格)" : "绿涨红跌(国际风格)").tag(scheme)
                                    }
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .labelsHidden()
                                .onChange(of: priceColorScheme) { newValue in
                                    settings.savePriceColorScheme(newValue)
                                    // 额外触发刷新
                                    NotificationCenter.default.post(name: NSNotification.Name("DisplaySettingsChanged"), object: nil)
                                }
                                
                                Text("选择价格上涨和下跌时使用的颜色方案")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                            }
                        }
                        .padding()
                        .frame(width: moduleWidth)
                    }
                    .frame(width: moduleWidth)
                    
                    // 外观设置
                    GroupBox(label: Text("外观").font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("使用系统外观", isOn: $useSystemAppearance)
                                .onChange(of: useSystemAppearance) { newValue in
                                    settings.saveAppearanceSettings(useSystem: newValue, isDarkMode: darkMode)
                                }
                            
                            if !useSystemAppearance {
                                Text("外观模式:")
                                    .padding(.leading, 20)
                                
                                Picker("", selection: $darkMode) {
                                    Text("浅色").tag(false)
                                    Text("深色").tag(true)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .labelsHidden()
                                .padding(.leading, 20)
                                .onChange(of: darkMode) { newValue in
                                    settings.saveAppearanceSettings(useSystem: useSystemAppearance, isDarkMode: newValue)
                                }
                            }
                            
                            // 添加一个占位控件以保持一致宽度
                            Color.clear
                                .frame(height: 0)
                        }
                        .padding()
                        .frame(width: moduleWidth)
                    }
                    .frame(width: moduleWidth)
                    
                    // 通知设置
                    GroupBox(label: Text("通知设置").font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("价格显著变动时通知我", isOn: $notifyOnChanges)
                                .onChange(of: notifyOnChanges) { newValue in
                                    settings.saveNotificationSettings(enabled: newValue, threshold: changeThreshold)
                                    
                                    // 如果用户启用通知，确保请求通知权限
                                    if newValue {
                                        NotificationManager.shared.requestAuthorization()
                                    }
                                }
                            
                            if notifyOnChanges {
                                VStack(alignment: .leading) {
                                    Text("变动阈值: \(String(format: "%.1f", changeThreshold))%")
                                    Slider(value: $changeThreshold, in: 1...20, step: 0.5)
                                        .frame(maxWidth: .infinity)
                                        .onChange(of: changeThreshold) { newValue in
                                            settings.saveNotificationSettings(enabled: notifyOnChanges, threshold: newValue)
                                        }
                                }
                                .padding(.leading, 20)
                            } else {
                                // 当不显示滑块时，添加占位空间保持一致高度
                                Color.clear
                                    .frame(height: 10)
                            }
                        }
                        .padding()
                        .frame(width: moduleWidth)
                    }
                    .frame(width: moduleWidth)
                    
                    // 数据设置
                    GroupBox(label: Text("数据设置").font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("涨跌幅计算方式")
                                Picker("", selection: $priceChangeMode) {
                                    ForEach(AppSettings.PriceChangeCalculationMode.allCases, id: \.self) { mode in
                                        Text(mode.description).tag(mode)
                                    }
                                }
                                .pickerStyle(DefaultPickerStyle())
                                .labelsHidden()
                                .onChange(of: priceChangeMode) { newValue in
                                    settings.savePriceChangeCalculationMode(newValue)
                                    cryptoService.refreshFavoriteProducts()
                                }
                            }
                            
                            VStack(alignment: .leading) {
                                Text("刷新间隔: \(Int(refreshInterval))秒")
                                Slider(value: $refreshInterval, in: 10...300, step: 10)
                                    .frame(maxWidth: .infinity)
                                    .onChange(of: refreshInterval) { newValue in
                                        settings.saveRefreshInterval(newValue)
                                    }
                                
                                Text("设置自动刷新数据的时间间隔，较短的间隔可获取更实时的数据，但会增加网络流量")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                            }
                            
                            Toggle("显示网络状态指示器", isOn: $showNetworkIndicator)
                                .onChange(of: showNetworkIndicator) { newValue in
                                    settings.saveShowNetworkIndicator(newValue)
                                }
                        }
                        .padding()
                        .frame(width: moduleWidth)
                    }
                    .frame(width: moduleWidth)
                    
                    // 系统设置
                    GroupBox(label: Text("系统设置").font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("开机时启动", isOn: $launchAtLogin)
                                .onChange(of: launchAtLogin) { newValue in
                                    settings.saveLaunchAtLogin(newValue)
                                }
                                .help("设置应用在系统启动时自动运行，首次设置后请前往\"系统设置->登录项\"确认应用权限")
                            
                            Button("重置所有设置") {
                                confirmResetSettings()
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            
                            Button("清除所有数据") {
                                confirmClearData()
                            }
                            .foregroundColor(.red)
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .padding()
                        .frame(width: moduleWidth)
                    }
                    .frame(width: moduleWidth)
                    
                    // 连接状态
                    GroupBox(label: Text("连接状态").font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("WebSocket状态:")
                                Spacer()
                                StatusIndicator(status: cryptoService.connectionStatus)
                                Text(cryptoService.connectionStatus.rawValue)
                            }
                            
                            Button("重新连接") {
                                cryptoService.reconnect()
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .disabled(cryptoService.connectionStatus == .connected)
                        }
                        .padding()
                        .frame(width: moduleWidth)
                    }
                    .frame(width: moduleWidth)
                }
                .padding()
            }
        }
        // 设置视图大小
        .frame(width: 400, height: 600)
    }
    
    // 确认重置设置
    private func confirmResetSettings() {
        let alert = NSAlert()
        alert.messageText = "重置所有设置"
        alert.informativeText = "您确定要将所有设置重置为默认值吗？这不会影响您的收藏列表。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        
        if alert.runModal() == .alertFirstButtonReturn {
            settings.resetToDefaults()
            
            // 更新视图状态
            notifyOnChanges = settings.notifyOnSignificantChanges
            changeThreshold = settings.significantChangeThreshold
            refreshInterval = settings.refreshInterval
            useSystemAppearance = settings.useSystemAppearance
            darkMode = settings.appearance == .dark
            colorCodeChanges = settings.colorCodePriceChanges
            compactMode = settings.compactMode
            launchAtLogin = settings.launchAtLogin
            showNetworkIndicator = settings.showNetworkIndicator
            displayCurrency = settings.displayCurrency
            priceChangeMode = settings.priceChangeCalculationMode
            priceColorScheme = settings.priceColorScheme
        }
    }
    
    // 确认清除数据
    private func confirmClearData() {
        let alert = NSAlert()
        alert.messageText = "清除所有数据"
        alert.informativeText = "您确定要清除所有数据吗？这将删除您的收藏列表和设置。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        
        if alert.runModal() == .alertFirstButtonReturn {
            cryptoService.clearAllData()
            settings.resetToDefaults()
            
            // 更新视图状态
            notifyOnChanges = settings.notifyOnSignificantChanges
            changeThreshold = settings.significantChangeThreshold
            refreshInterval = settings.refreshInterval
            useSystemAppearance = settings.useSystemAppearance
            darkMode = settings.appearance == .dark
            colorCodeChanges = settings.colorCodePriceChanges
            compactMode = settings.compactMode
            launchAtLogin = settings.launchAtLogin
            showNetworkIndicator = settings.showNetworkIndicator
            displayCurrency = settings.displayCurrency
            priceChangeMode = settings.priceChangeCalculationMode
            priceColorScheme = settings.priceColorScheme
        }
    }
}

// 状态指示器组件
struct StatusIndicator: View {
    var status: ConnectionStatus
    
    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .padding(.trailing, 4)
    }
    
    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .failed:
            return .red
        }
    }
} 