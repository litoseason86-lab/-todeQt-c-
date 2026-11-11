import Foundation

public enum BackupTimeText {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    private static let formatterLock = NSLock()

    public static func display(_ iso: String) -> String {
        // 沿用桥接时刻的解析：无时区旧串按本地墙钟读，有偏移的串按绝对时刻换成本地显示。
        guard let date = LogicalDateNavigation.timestampDate(iso) else { return iso }
        // 复用格式器避免列表逐行初始化；更新时区与格式化同锁，系统时区变化后不继续显示旧时区。
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let zone = NSTimeZone.default
        if formatter.timeZone != zone { formatter.timeZone = zone }
        return formatter.string(from: date)
    }
}
