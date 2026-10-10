import Foundation

public struct MonthCalendarCell: Sendable {
    public let index: Int
    public let date: String?
    public let day: Int
}
public enum MonthGoalFormat {
    // 只做显示与七列排版，不判断逻辑日和未来；日期状态由桥接给出。
    public static func monthCells(year: Int, month: Int) -> [MonthCalendarCell] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        return (0..<42).map { index in
            let day = index - offset + 1
            let inMonth = days.contains(day)
            return MonthCalendarCell(index: index, date: inMonth ? String(format: "%04d-%02d-%02d", year, month, day) : nil,
                                     day: inMonth ? day : 0)
        }
    }
    public static func isoDate(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
    // 服务旧值兼有 T 和空格分隔；先截取时钟文字，保持 99:99 这类已登记显示边界。
    public static func formatClock(_ value: String?) -> String {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "--:--" }
        if let separator = text.firstIndex(of: "T") ?? text.firstIndex(of: " ") {
            let clock = String(text[text.index(after: separator)...].prefix(5))
            if clock.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil { return clock }
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: text)
        parser.formatOptions = [.withInternetDateTime]
        guard let parsed = date ?? parser.date(from: text) else { return "--:--" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm"
        return formatter.string(from: parsed)
    }
}
