import Foundation

public struct ScheduleInterval<Entry> {
    public var entry: Entry
    public var start: Double
    public var end: Double
    public var top: Double
    public var height: Double
    public init(entry: Entry, start: Double, end: Double, top: Double = 0, height: Double = 0) {
        self.entry = entry; self.start = start; self.end = end; self.top = top; self.height = height
    }
}
public struct SchedulePlacement<Entry> {
    public var entry: Entry
    public var top: Double
    public var height: Double
    public var lane: Int
    public var laneCount: Int
}
public enum ScheduleLayout {
    // 泳道是同日课程并排显示的位置；按最终绘制区间分簇，避免短块放大后遮住另一门课。
    public static func place<Entry>(_ entries: [ScheduleInterval<Entry>]) -> [SchedulePlacement<Entry>] {
        let sorted = entries.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end < b.element.end }
            return a.offset < b.offset
        }.map(\.element)
        var result: [SchedulePlacement<Entry>] = [], cluster: [SchedulePlacement<Entry>] = []
        var laneEnds: [Double] = [], clusterEnd: Double = -1
        func flush() {
            for var item in cluster { item.laneCount = laneEnds.count; result.append(item) }
            cluster = []; laneEnds = []; clusterEnd = -1
        }
        for item in sorted {
            if clusterEnd >= 0 && item.start >= clusterEnd { flush() }
            let lane = laneEnds.firstIndex(where: { $0 <= item.start }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(item.end) } else { laneEnds[lane] = item.end }
            cluster.append(SchedulePlacement(entry: item.entry, top: item.top, height: item.height, lane: lane, laneCount: 1))
            clusterEnd = max(clusterEnd, item.end)
        }
        flush()
        return result
    }
}
