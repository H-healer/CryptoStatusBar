import SwiftUI

/// 价格颜色工具类 - 统一处理价格颜色逻辑
struct PriceColorHelper {

    /// 根据价格变动方向获取颜色
    /// - Parameters:
    ///   - direction: 价格变动方向
    ///   - colorScheme: 颜色方案（国际/中国）
    /// - Returns: 对应的颜色
    static func color(for direction: PriceChangeDirection, colorScheme: AppSettings.PriceColorScheme = AppSettings.shared.priceColorScheme) -> Color {
        switch direction {
        case .up:
            return colorScheme == .chinese ? .red : .green
        case .down:
            return colorScheme == .chinese ? .green : .red
        case .unchanged:
            return .primary
        }
    }

    /// 根据涨跌幅百分比获取颜色
    /// - Parameters:
    ///   - changePercent: 涨跌幅百分比
    ///   - colorScheme: 颜色方案（国际/中国）
    /// - Returns: 对应的颜色
    static func color(for changePercent: Double, colorScheme: AppSettings.PriceColorScheme = AppSettings.shared.priceColorScheme) -> Color {
        if changePercent > 0 {
            return colorScheme == .chinese ? .red : .green
        } else if changePercent < 0 {
            return colorScheme == .chinese ? .green : .red
        } else {
            return .gray
        }
    }

    /// 获取产品的价格颜色
    /// - Parameter product: 加密货币产品
    /// - Returns: 价格颜色
    static func priceColor(for product: CryptoProduct) -> Color {
        return color(for: product.priceChangeDirection)
    }

    /// 获取产品的涨跌幅颜色
    /// - Parameters:
    ///   - product: 加密货币产品
    ///   - mode: 涨跌幅计算模式
    /// - Returns: 涨跌幅颜色
    static func changeColor(for product: CryptoProduct, mode: AppSettings.PriceChangeCalculationMode = AppSettings.shared.priceChangeCalculationMode) -> Color {
        let changePercent = product.getPriceChangePercent(mode: mode)
        return color(for: changePercent)
    }
}

/// 价格变动文本视图 - 可复用的涨跌幅显示组件
struct PriceChangeText: View {
    let product: CryptoProduct
    var mode: AppSettings.PriceChangeCalculationMode = AppSettings.shared.priceChangeCalculationMode

    var body: some View {
        Text(product.formattedPriceChangePercent(mode: mode))
            .font(.caption.monospacedDigit())
            .foregroundColor(PriceColorHelper.changeColor(for: product, mode: mode))
    }
}
