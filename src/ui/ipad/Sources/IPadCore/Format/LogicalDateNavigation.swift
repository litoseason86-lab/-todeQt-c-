import Foundation

public enum LogicalDateNavigation {
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
    public static func initialSessionStart(date iso: String) -> Date {
        let day = date(iso) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    public static func timestampDate(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: iso) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
