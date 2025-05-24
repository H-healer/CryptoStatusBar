import Foundation
import AppKit

// 产品类型枚举
enum ProductType: String, Codable, CaseIterable {
    case SPOT = "SPOT"       // 币币
    case SWAP = "SWAP"       // 永续合约
    case FUTURES = "FUTURES" // 交割合约
    case OPTION = "OPTION"   // 期权
    
    // 中文显示名称
    var displayName: String {
        switch self {
        case .SPOT: return "币币"
        case .SWAP: return "永续合约"
        case .FUTURES: return "交割合约"
        case .OPTION: return "期权"
        }
    }
}

struct CryptoProduct: Identifiable, Codable, Equatable {
    var id: String  // 用于SwiftUI列表
    let instId: String  // API识别符
    let baseCcy: String  // 基本货币（如BTC）
    let quoteCcy: String  // 报价货币（如USDT）
    let productType: ProductType // 产品类型
    
    // 价格信息
    var currentPrice: Double = 0.0
    var previousPrice: Double = 0.0
    var priceChangePercent24h: Double = 0.0  // 24小时价格变动百分比
    var highPrice24h: Double = 0.0  // 24小时最高价
    var lowPrice24h: Double = 0.0   // 24小时最低价
    
    // 类似股票开盘价的数据，从API直接获取
    var utcOpenPrice: Double = 0.0  // UTC(0点)开盘价
    var localOpenPrice: Double = 0.0  // UTC+8(0点)开盘价
    
    // 显示属性
    var notifyOnPriceChange: Bool = false
    var priceAlertThreshold: Double = 5.0  // 价格变动超过5%时提醒
    
    // 构造函数增加产品类型参数，默认为SPOT
    init(id: String, instId: String, baseCcy: String, quoteCcy: String, productType: ProductType = .SPOT) {
        self.id = id
        self.instId = instId
        self.baseCcy = baseCcy
        self.quoteCcy = quoteCcy
        self.productType = productType
    }
    
    // 格式化价格显示
    var formattedPrice: String {
        if currentPrice == 0.0 {
            return "加载中..."
        }
        
        // 获取货币设置
        let currencySetting = AppSettings.shared.displayCurrency
        
        // 根据货币类型和汇率调整价格
        let displayPrice: Double
        let currencySymbol: String
        
        if currencySetting == "CNY" {
            // 人民币汇率转换
            let cryptoService = CryptoService.shared
            displayPrice = currentPrice * cryptoService.usdCnyRate
            currencySymbol = "¥"
        } else if currencySetting == "USD" {
            // 美元显示
            displayPrice = currentPrice
            currencySymbol = "$"
        } else {
            // 不显示货币符号
            displayPrice = currentPrice
            currencySymbol = ""
        }
        
        // 确定需要显示的有效小数位数
        let minDecimals = 2  // 最少保留的小数位数
        let maxDecimals = 6  // 最多保留的小数位数
        
        // 计算有效小数位（找到最后一个非零位）
        var effectiveDecimals = minDecimals
        let tempString = String(format: "%.10f", displayPrice) // 用更多位数来分析
        if let decimalPoint = tempString.firstIndex(of: ".") {
            let fractionalPart = tempString[decimalPoint...].dropFirst()
            var lastSignificantIndex = 0
            
            for (index, char) in fractionalPart.enumerated() {
                if char != "0" {
                    lastSignificantIndex = index
                }
                if index >= 9 { // 防止越界
                    break
                }
            }
            
            // 最后一个有意义数字后再多显示1位
            effectiveDecimals = min(lastSignificantIndex + 1, maxDecimals)
            effectiveDecimals = max(effectiveDecimals, minDecimals)
        }
        
        // 使用等宽字体和固定小数位格式化
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = effectiveDecimals
        formatter.maximumFractionDigits = effectiveDecimals
        
        // 获取格式化后的价格文本
        guard var priceString = formatter.string(from: NSNumber(value: displayPrice)) else {
            return String(format: "%.\(effectiveDecimals)f", displayPrice)
        }
        
        // 添加货币符号
        if !currencySetting.isEmpty {
            priceString = "\(currencySymbol)\(priceString)"
        }
        
        // 返回可以用于创建固定宽度等宽字体的AttributedString的文本
        return priceString
    }
    
    // 获取用于显示的价格属性字符串(等宽字体)
    func getAttributedPrice() -> NSAttributedString {
        let priceText = formattedPrice
        
        // 设置等宽字体属性
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: NSFont.Weight.regular)
        ]
        
        return NSAttributedString(string: priceText, attributes: attributes)
    }
    
    // 价格变动方向
    var priceChangeDirection: PriceChangeDirection {
        if currentPrice > previousPrice {
            return .up
        } else if currentPrice < previousPrice {
            return .down
        } else {
            return .unchanged
        }
    }
    
    // 更新价格
    mutating func updatePrice(newPrice: Double) {
        // 保存当前价格为前一价格
        self.previousPrice = self.currentPrice
        // 设置新价格
        self.currentPrice = newPrice
    }
    
    // 直接设置前一价格（用于控制显示颜色）
    mutating func setPreviousPrice(_ price: Double) {
        self.previousPrice = price
    }
    
    // 更新24小时数据
    mutating func update24hData(high: Double, low: Double, changePercent: Double) {
        self.highPrice24h = high
        self.lowPrice24h = low
        self.priceChangePercent24h = changePercent
    }
    
    // 更新开盘价数据
    mutating func updateOpenPrices(utcOpen: Double, localOpen: Double) {
        self.utcOpenPrice = utcOpen
        self.localOpenPrice = localOpen
    }
    
    // 格式化价格变动百分比
    func formattedPriceChangePercent(mode: AppSettings.PriceChangeCalculationMode = .hours24) -> String {
        // 获取百分比值
        let changePercent = getPriceChangePercent(mode: mode)
        let absChange = abs(changePercent)
        
        // 格式化输出
        let sign = changePercent >= 0 ? "+" : "-"
        return "\(sign)\(String(format: "%.2f", absChange))%"
    }
    
    // 获取涨跌幅百分比
    func getPriceChangePercent(mode: AppSettings.PriceChangeCalculationMode) -> Double {
        // 已有的API字段值
        switch mode {
        case .hours24:
            return priceChangePercent24h  // 24小时涨跌幅
            
        case .todayUtc:
            // UTC(0) 日内涨跌幅
            guard utcOpenPrice > 0 else { return 0 }
            return ((currentPrice - utcOpenPrice) / utcOpenPrice) * 100.0
            
        case .todayLocal:
            // UTC+8 日内涨跌幅
            guard localOpenPrice > 0 else { return 0 }
            return ((currentPrice - localOpenPrice) / localOpenPrice) * 100.0
        }
    }
    
    // 自定义Equatable实现
    static func == (lhs: CryptoProduct, rhs: CryptoProduct) -> Bool {
        return lhs.instId == rhs.instId
    }
}

// 价格变动方向枚举
enum PriceChangeDirection {
    case up
    case down
    case unchanged
} 