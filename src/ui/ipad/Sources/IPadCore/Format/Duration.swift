import Foundation

public enum DurationFormat {
    // 数字 NaN 在 JS 的 truthy 归一化后成为零；正无穷沿用对照表里的显示，不转 Int 以免溢出。
    public static func minutes(_ value: Double) -> String {
        formatted(value.isNaN ? 0 : value)
    }
    public static func minutes(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return formatted(0) }
        // 非数字字符串与数字 NaN 是两条不同的旧格式边界，按 P2B 表保留。
        return formatted(Double(text) ?? .nan)
    }
    public static func seconds(_ value: Double) -> String {
        minutes(floor(max(0, value.isNaN ? 0 : value) / 60))
    }
    private static func formatted(_ value: Double) -> String {
        if value.isNaN { return "NaN 分钟" }
        let safe = max(0, floor(value + 0.5))
        if safe == .infinity { return "Infinity 小时" }
        let hours = floor(safe / 60), minutes = safe.truncatingRemainder(dividingBy: 60)
        if hours > 0 && minutes > 0 { return "\(integerText(hours)) 小时 \(integerText(minutes)) 分" }
        if hours > 0 { return "\(integerText(hours)) 小时" }
        return "\(integerText(minutes)) 分钟"
    }
    private static func integerText(_ value: Double) -> String { String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
}
