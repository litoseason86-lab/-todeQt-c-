import Foundation

public enum ContentDateFormat {
    // 日期控件只转换表单输入，是否今天/逾期仍完全使用服务字段。
    public static func date(_ iso: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: iso), formatter.string(from: date) == iso else { return nil }
        return date
    }
    public static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
