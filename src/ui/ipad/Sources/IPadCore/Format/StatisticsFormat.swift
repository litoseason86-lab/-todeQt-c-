import Foundation

public struct StatisticsLevel: Equatable, Sendable {
    public let lv: Int
    public let min: Int
    public let name: String
}
public enum StatisticsFormat {
    // 这些函数只把服务数据排成 Mac 已登记的文字，不计算统计归属、总量、比值或事实。
    private static func safe(_ number: Double) -> Double { number.isNaN ? number : max(0, floor(number)) }
    private static func integerText(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }
        return String(format: "%.0f", number)
    }
    public static func levelOf(_ count: Double) -> StatisticsLevel {
        let number = safe(count)
        let levels = [StatisticsLevel(lv: 1, min: 0, name: "起步"), StatisticsLevel(lv: 2, min: 3, name: "上路"),
                      StatisticsLevel(lv: 3, min: 8, name: "成习"), StatisticsLevel(lv: 4, min: 20, name: "丰收"),
                      StatisticsLevel(lv: 5, min: 40, name: "燎原")]
        return levels.last { number >= Double($0.min) } ?? levels[0]
    }
    public static func formatDuration(_ seconds: Double) -> String {
        let value = safe(seconds)
        if value > 0 && value < 60 { return integerText(value) + "秒" }
        let hours = floor(value / 3600), minutes = floor(value.truncatingRemainder(dividingBy: 3600) / 60)
        return hours > 0 ? integerText(hours) + "小时" + integerText(minutes) + "分钟" : integerText(minutes) + "分钟"
    }
    public static func decimalHours(_ seconds: Double) -> String {
        guard !seconds.isNaN else { return "NaN" }
        if seconds == .infinity { return "Infinity" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds) / 3600)
    }
    public static func totalDurationValue(_ seconds: Double) -> String {
        let value = safe(seconds)
        if value >= 3600 { return decimalHours(value) }
        if value > 0 && value < 60 { return integerText(value) }
        return integerText(floor(value / 60))
    }
    public static func totalDurationUnit(_ seconds: Double) -> String {
        let value = safe(seconds)
        return value >= 3600 ? "小时" : (value > 0 && value < 60 ? "秒" : "分钟")
    }
    // 显示对照表中的自然日格式；页面的周期导航与未来判断使用桥接，不能调用这些函数作业务判断。
    public static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: String(text.prefix(10)))
    }
    private static var calendar: Calendar { Calendar(identifier: .gregorian) }
    public static func mondayOf(_ date: Date) -> Date {
        let offset = (calendar.component(.weekday, from: date) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: date))!
    }
    public static func endOfWeek(_ start: Date) -> Date { calendar.date(byAdding: .day, value: 6, to: start)! }
    public static func dayStart(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    public static func formatWeekRange(_ start: Date, _ end: Date) -> String {
        "\(calendar.component(.month, from: start)).\(calendar.component(.day, from: start))-\(calendar.component(.month, from: end)).\(calendar.component(.day, from: end))"
    }
    public static func weekdayLabel(_ date: String?, index: Int) -> String {
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        guard let date, let parsed = parseDate(date) else { return labels[((index % 7) + 7) % 7] }
        return labels[(calendar.component(.weekday, from: parsed) + 5) % 7]
    }
    public static func comparisonLabel(range: String, distance: Int) -> String {
        switch range {
        case "day": distance <= 1 ? "昨天" : distance == 2 ? "前天" : "\(distance)天前"
        case "week": distance <= 1 ? "上周" : distance == 2 ? "上上周" : "\(distance)周前"
        default: distance <= 1 ? "上月" : distance == 2 ? "上上月" : "\(distance)个月前"
        }
    }
    // 周复盘沿用 Duration.js：分钟四舍五入，秒向下截成分钟，与统计卡的不带空格格式区分。
    public static func reviewMinutes(_ minutes: Double) -> String {
        guard !minutes.isNaN else { return "NaN 分钟" }
        let value = max(0, floor(minutes + 0.5)), h = floor(value / 60), m = value.truncatingRemainder(dividingBy: 60)
        if h > 0 && m > 0 { return integerText(h) + " 小时 " + integerText(m) + " 分" }
        return h > 0 ? integerText(h) + " 小时" : integerText(m) + " 分钟"
    }
    public static func reviewSeconds(_ seconds: Double) -> String {
        seconds.isNaN ? reviewMinutes(.nan) : reviewMinutes(floor(max(0, seconds) / 60))
    }
    public static func percent(_ number: Double) -> String { integerText(floor(number + 0.5)) + "%" }
    public static func signedMinutes(_ number: Int) -> String {
        number == 0 ? reviewMinutes(0) : (number > 0 ? "+" : "-") + reviewMinutes(abs(Double(number)))
    }
    public static func dateText(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return "" }
        return "\(month) 月 \(day) 日"
    }
    public static func factText(_ fact: ReviewFact) -> String {
        switch fact.type {
        case "goalShortfall":
            return dateText(fact.date) + "：目标 " + reviewMinutes(Double(fact.goalMinutes ?? 0))
                + "，实际 " + reviewSeconds(Double(fact.actualSeconds ?? 0)) + "，投入为目标的 " + percent(fact.ratioPercent ?? 0) + "。"
        case "subjectShareChange":
            let delta = fact.deltaPoints ?? 0
            return fact.subject + "：当周 " + reviewSeconds(Double(fact.currentSeconds ?? 0))
                + "，前一周 " + reviewSeconds(Double(fact.previousSeconds ?? 0))
                + "，占比 " + percent(fact.currentSharePercent ?? 0) + "，比前一周" + (delta >= 0 ? "增加 " : "减少 ")
                + integerText(floor(abs(delta) + 0.5)) + " 个百分点。"
        case "estimateShortfall":
            return fact.subject + "：计划 " + reviewMinutes(Double(fact.plannedMinutes ?? 0))
                + "，实际 " + reviewMinutes(Double(fact.actualDisplayMinutes ?? 0))
                + "，差 " + reviewMinutes(Double(fact.shortfallDisplayMinutes ?? 0)) + "。"
        case "estimateOnTrack": return "当周有预计用时的任务，其总投入接近计划。"
        default: return ""
        }
    }
}
