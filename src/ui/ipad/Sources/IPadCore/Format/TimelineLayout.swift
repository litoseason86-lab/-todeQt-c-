import Foundation

// 055-R4：今日专注时间轴的排版换算。只把服务给出的开始时刻与时长换成相对所选日 0 点的分钟，
// 用来定位色块；记录归哪一天、有多少段、合计多少都仍以服务为准，这里不筛选、不加总。
public struct TimelineBlock: Equatable, Sendable {
    public let session: SessionValue
    public let startMinute: Int
    public let endMinute: Int
}

public enum TimelineLayout {
    // 默认显示 8:00–20:00；有更早或更晚的记录时按整点往外扩，刻度两小时一格。
    public static let defaultStartHour = 8
    public static let defaultEndHour = 20

    // 逻辑日的起点在凌晨（默认 4 点），所以次日凌晨的记录会算成 24 点以后的分钟，接在当天后面。
    // 按本地墙钟换算（隔了几个日历日 × 24 小时 + 当时的时分），不用与 0 点的绝对秒差：
    // 夏令时切换日只有 23 或 25 小时，秒差会把 09:00 算成 8 点或 10 点。
    public static func minute(of timestamp: String, day: String) -> Int? {
        guard let start = LogicalDateNavigation.timestampDate(timestamp),
              let midnight = LogicalDateNavigation.date(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let days = calendar.dateComponents([.day], from: midnight, to: calendar.startOfDay(for: start)).day else { return nil }
        let clock = calendar.dateComponents([.hour, .minute], from: start)
        return days * 24 * 60 + (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
    }

    public static func blocks(_ sessions: [SessionValue], day: String) -> [TimelineBlock] {
        sessions.compactMap { session in
            guard let start = minute(of: session.startTime, day: day) else { return nil }
            return TimelineBlock(session: session, startMinute: start,
                                 endMinute: start + max(1, Int((Double(session.durationSeconds) / 60).rounded())))
        }
    }

    // 刻度范围（整点，偶数小时对齐，便于两小时一格的刻度）。
    // 分钟可能为负（服务归到当天、本地墙钟却在前一天的旧记录）：下界一律向更早取整，
    // Swift 的整数除法和取余向零截断，负数直接用会往晚处取。
    public static func hourRange(_ blocks: [TimelineBlock], extraMinutes: [Int] = []) -> ClosedRange<Int> {
        let starts = blocks.map(\.startMinute) + extraMinutes
        let ends = blocks.map(\.endMinute) + extraMinutes
        var lower = min(defaultStartHour, Int((Double(starts.min() ?? defaultStartHour * 60) / 60).rounded(.down)))
        var upper = max(defaultEndHour, Int((Double(ends.max() ?? defaultEndHour * 60) / 60).rounded(.up)))
        lower -= positiveRemainder(lower, 2)
        upper += positiveRemainder(upper, 2)
        return lower...upper
    }

    // 时间轴上的分钟写成墙钟「HH:mm」：24 点以后接次日凌晨，负数接前一天晚上（-150 → 21:30）。
    public static func clockText(_ minute: Int) -> String {
        let wall = positiveRemainder(minute, 24 * 60)
        return String(format: "%02d:%02d", wall / 60, wall % 60)
    }

    private static func positiveRemainder(_ value: Int, _ divisor: Int) -> Int {
        (value % divisor + divisor) % divisor
    }
}
