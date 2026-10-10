import Foundation
import Observation

public struct HistoryDay: Equatable, Identifiable, Sendable {
    public let id: Int
    public let date: String?
    public let day: Int
    public let seconds: Int
    public let band: Int
    public let today: Bool
    public let future: Bool
}
@MainActor @Observable public final class HistoryStore {
    public private(set) var year = 0
    public private(set) var month = 0
    public private(set) var monthStart = ""
    public private(set) var logicalToday = ""
    public private(set) var selectedDate = ""
    public private(set) var cells: [HistoryDay] = []
    public private(set) var sessions: [SessionValue] = []
    public private(set) var invalidSessionCount = 0
    public private(set) var errorMessage = ""
    public var cleanupConfirmationPresented = false
    @ObservationIgnored private let history: any FocusHistoryBridgeProtocol
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private var active = false
    @ObservationIgnored private var followingToday = true
    @ObservationIgnored private var requestedAnchor: String?
    @ObservationIgnored private var cleaning = false
    @ObservationIgnored private var cleanupRequested = false

    public init(history: any FocusHistoryBridgeProtocol, logicalDay: any LogicalDayBridgeProtocol) {
        self.history = history; self.logicalDay = logicalDay
        // 页面各持自己的桥接订阅；失效只在活跃时查询，回页时重读完整快照。
        history.onChanged = { [weak self] in
            guard let self, self.active, !self.cleaning else { return }; self.refresh()
        }
        logicalDay.onChanged = { [weak self] in
            guard let self, self.active else { return }; self.refresh()
        }
    }
    public var selectedSeconds: Int { cells.first { $0.date == selectedDate }?.seconds ?? 0 }
    public var selectedSessions: [SessionValue] { sessions.filter { $0.date == selectedDate } }
    public func durationText(_ seconds: Int) -> String { history.formatDuration(seconds: seconds) }
    public func setActive(_ value: Bool) { active = value; if value { refresh() } }
    public func refresh() {
        do {
            // 本次快照只读一次逻辑今日，逐格日期关系共用该值；Swift 不比较日期、不聚合秒数。
            let today = logicalDay.today
            let anchor = followingToday ? today : requestedAnchor ?? (monthStart.isEmpty ? today : monthStart)
            let period = try logicalDay.period(anchor: anchor, range: "month", shift: 0, logicalToday: today)
            let records = try history.monthSessions(year: period.year, month: period.month)
            let invalidCount = try history.invalidSessionCount()
            let nextCells = try MonthGoalFormat.monthCells(year: period.year, month: period.month).map { item in
                guard let date = item.date else {
                    return HistoryDay(id: item.index, date: nil, day: 0, seconds: 0, band: -1, today: false, future: false)
                }
                let relation = try logicalDay.relation(date, to: today)
                let seconds = try history.dayTotalDuration(date: date)
                // seconds / 60.0 保留不足一分钟的投入，档位结果只消费 C++ 返回值。
                let band = history.bandForMinutes(Double(seconds) / 60.0)
                return HistoryDay(id: item.index, date: date, day: item.day, seconds: seconds, band: band,
                                  today: relation == .same, future: relation == .later)
            }
            let nextSelection: String
            if followingToday { nextSelection = today }
            else if requestedAnchor == nil && nextCells.contains(where: { $0.date == selectedDate && !$0.future }) {
                nextSelection = selectedDate
            } else { nextSelection = nextCells.first { $0.date != nil && !$0.future }?.date ?? "" }
            // 全部读取成功才替换月历、明细与标题；失败时保留上次数据，重试继续尝试待切月份。
            year = period.year; month = period.month; monthStart = period.start; logicalToday = today
            cells = nextCells; sessions = records; invalidSessionCount = invalidCount; selectedDate = nextSelection
            requestedAnchor = nil; errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }
    public func moveMonth(_ shift: Int) {
        guard !monthStart.isEmpty else { return }
        do {
            let period = try logicalDay.period(anchor: monthStart, range: "month", shift: shift, logicalToday: logicalToday)
            followingToday = false; requestedAnchor = period.start; refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    public func returnToCurrentMonth() { followingToday = true; requestedAnchor = nil; refresh() }
    public func select(_ date: String) {
        guard let cell = cells.first(where: { $0.date == date }), !cell.future else { return }
        selectedDate = date; followingToday = cell.today
    }
    public func requestCleanup() {
        guard invalidSessionCount > 0 else { return }; cleanupRequested = true; cleanupConfirmationPresented = true
    }
    public func cancelCleanup() { cleanupRequested = false; cleanupConfirmationPresented = false }
    public func confirmCleanup() {
        // 面板显示绑定与待确认意图分开，系统收起面板不等于取消或重复提交。
        guard cleanupRequested else { return }
        cleanupRequested = false; cleanupConfirmationPresented = false; cleaning = true
        defer { cleaning = false }
        do {
            // 清理会同步发 historyChanged，调用结束后统一重读，避免重复查询和半份状态。
            _ = try history.cleanupInvalidSessions(); refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    public func openSelectedDay(shell: ShellStore) {
        guard cells.contains(where: { $0.date == selectedDate && !$0.future }) else { return }
        shell.openFocusHistory(date: selectedDate)
    }
}
