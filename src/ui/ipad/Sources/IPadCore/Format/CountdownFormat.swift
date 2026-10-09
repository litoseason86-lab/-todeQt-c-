import Foundation
public enum CountdownFormat {
    // 天数来自服务；本层只把负数显示成已过期，不用设备日期重算。
    public static func days(_ value: Int) -> String { value < 0 ? "已过期 \(value.magnitude) 天" : "\(value) 天" }
    // 表单默认值沿用 Mac：在服务给出的逻辑今日上做 30 天日历加法，仅用于初始输入。
    public static func defaultDate(logicalToday: String) -> String {
        guard let date = MemoFormat.parse(logicalToday) else { return logicalToday }
        let calendar = Calendar(identifier: .gregorian)
        guard let target = calendar.date(byAdding: .day, value: 30, to: date) else { return logicalToday }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: target)
    }
    public static func targetDate(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        return "\(parts[0])年\(parts[1])月\(parts[2])日"
    }
}
