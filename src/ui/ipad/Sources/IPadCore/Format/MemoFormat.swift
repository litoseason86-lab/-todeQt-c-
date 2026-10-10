import Foundation

public enum MemoFormat {
    // 用户决定保留 Qt JS 的 UTF-16 计数缺陷；表情按两个单元，不能替换成 String.count。
    public static func characterCount(_ value: String) -> Int { value.utf16.count }
    // Swift String 无法承载孤立代理项，显示截取口径先保留 UTF-16 单元，避免解码时悄悄替换。
    public static func firstCharacters(_ value: String, count: Int) -> [UInt16] {
        let units = Array(value.utf16)
        let end = count < 0 ? max(0, units.count + count) : min(count, units.count)
        return Array(units.prefix(end))
    }
    public static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
    public static func shownTitle(title: String, body: String) -> String {
        let first = body.components(separatedBy: "\n").first ?? ""
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? first : title
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新备忘录" : text
    }
    public static func parse(_ value: String, timeZone: TimeZone = .current) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone; formatter.isLenient = false
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value), formatter.string(from: date) == value { return date }
        }
        return nil
    }
    // 自然日期分档只用于更新时间显示，和业务的逻辑日不同；日历差避免夏令时造成 24 小时误差。
    public static func formatUpdatedAt(_ value: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let date = parse(value, timeZone: timeZone) else { return "" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let distance = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if distance == 0 { return "今天 \(pad(parts.hour!)):\(pad(parts.minute!))" }
        if distance == 1 { return "昨天" }
        if (2...6).contains(distance) { return "\(distance) 天前" }
        return (parts.year == calendar.component(.year, from: now) ? "" : "\(parts.year!)年") + "\(parts.month!)月\(parts.day!)日"
    }
}
