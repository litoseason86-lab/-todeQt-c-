import Foundation

public enum ScheduleFormat {
    // 与 Mac 的纯显示函数同口径，分钟钳在自然日范围，保留 24:00 作为末尾刻度。
    public static func formatMinutes(_ value: Double) -> String {
        let safe = value.isNaN ? 0 : max(0, min(1440, value))
        let hours = Int(floor(safe / 60)), minutes = safe.truncatingRemainder(dividingBy: 60)
        let text = minutes.rounded() == minutes ? String(Int(minutes)) : String(minutes)
        return (hours < 10 ? "0" : "") + String(hours) + ":" + (minutes < 10 ? "0" : "") + text
    }
    public static func parseMinutes(_ text: String) -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else { return -1 }
        let parts = value.split(separator: ":")
        guard let hours = Int(parts[0]), let minutes = Int(parts[1]), hours <= 24, minutes <= 59,
              hours * 60 + minutes <= 1440 else { return -1 }
        return hours * 60 + minutes
    }
    public static func parityLabel(_ parity: Double) -> String {
        parity == 1 ? "单周" : (parity == 2 ? "双周" : "")
    }
    public static func weekRangeLabel(start: Double, end: Double, parity: Double, semesterWeeks: Double) -> String {
        let parityText = parityLabel(parity), whole = start <= 1 && end >= semesterWeeks
        if whole { return parityText }
        let range = start == end ? "第 \(Int(start)) 周" : "第 \(Int(start))-\(Int(end)) 周"
        return parityText.isEmpty ? range : range + " · " + parityText
    }
    // 这里只投影服务给的日历日期供列头显示，不判断今日、未来或学期归属。
    public static func displayDate(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }
}
