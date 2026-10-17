import Foundation

public enum LogicalDateNavigation {
    // 未装配的测试与预览仅有系统日期；应用启动时注入 C++ 逻辑今日，Swift 不另算日界。
    @MainActor public static var logicalTodayProvider: @MainActor () -> String = { isoDate(Date()) }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }
    // 只转换系统日期控件和前后日导航；未来日、逻辑今日及统计归属一律由 C++ 判断。
    public static func shifted(_ iso: String, days: Int) -> String? {
        guard let date = date(iso), let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return isoDate(shifted)
    }
    public static func date(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let result = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              isoDate(result) == iso else { return nil }
        return result
    }
    public static func isoDate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }
    @MainActor public static func dateOrLogicalToday(_ iso: String) -> Date {
        // 上游日期缺失或损坏时先用 C++ 的逻辑今天，避免凌晨日界前把控件初值移到自然日。
        // 每次兜底都重读 provider；仅它也不能解析时才使用系统时间，Swift 不复制日界计算。
        date(iso) ?? date(logicalTodayProvider()) ?? Date()
    }
    @MainActor public static func initialSessionStart(date iso: String) -> Date {
        let day = dateOrLogicalToday(iso)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
    // 专注记录按本地墙钟跨桥接传递；固定公历与 POSIX 区域，避免系统历法改变落库字段。
    private static func localTimestampFormatter(fractionalSeconds: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = .current
        formatter.dateFormat = fractionalSeconds ? "yyyy-MM-dd'T'HH:mm:ss.SSS" : "yyyy-MM-dd'T'HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }
    public static func timestamp(_ date: Date) -> String {
        localTimestampFormatter(fractionalSeconds: true).string(from: date)
    }
    public static func timestampDate(_ iso: String) -> Date? {
        // 桥接真实输出不含时区；整秒旧记录也按当前时区解析。回写比对避免宽松解析吞掉后缀。
        for fractionalSeconds in [true, false] {
            let formatter = localTimestampFormatter(fractionalSeconds: fractionalSeconds)
            if let result = formatter.date(from: iso), formatter.string(from: result) == iso { return result }
        }
        // 兼容曾使用的带偏移或 Z 的 ISO 串，按其绝对时刻读取，不把它们当本地墙钟。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: iso) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
