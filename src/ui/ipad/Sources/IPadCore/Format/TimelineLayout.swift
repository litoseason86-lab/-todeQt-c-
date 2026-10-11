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
    public static func minute(of timestamp: String, day: String) -> Int? {
        guard let start = LogicalDateNavigation.timestampDate(timestamp),
              let midnight = LogicalDateNavigation.date(day) else { return nil }
        return Int((start.timeIntervalSince(midnight) / 60).rounded(.down))
    }

    public static func blocks(_ sessions: [SessionValue], day: String) -> [TimelineBlock] {
        sessions.compactMap { session in
            guard let start = minute(of: session.startTime, day: day) else { return nil }
            return TimelineBlock(session: session, startMinute: start,
                                 endMinute: start + max(1, Int((Double(session.durationSeconds) / 60).rounded())))
        }
    }

    // 刻度范围（整点，偶数小时对齐，便于两小时一格的刻度）。
    public static func hourRange(_ blocks: [TimelineBlock], extraMinutes: [Int] = []) -> ClosedRange<Int> {
        let starts = blocks.map(\.startMinute) + extraMinutes
        let ends = blocks.map(\.endMinute) + extraMinutes
        var lower = min(defaultStartHour, (starts.min() ?? defaultStartHour * 60) / 60)
        var upper = max(defaultEndHour, Int((Double(ends.max() ?? defaultEndHour * 60) / 60).rounded(.up)))
        lower -= lower % 2
        upper += upper % 2
        return lower...upper
    }
}
