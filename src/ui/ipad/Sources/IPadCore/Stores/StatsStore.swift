import Foundation
import Observation

public enum StatisticsRange: String, CaseIterable, Sendable { case day, week, month
    public var title: String { switch self { case .day: "今日"; case .week: "本周"; case .month: "本月" } }
}
public struct StatisticsBar: Equatable, Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let seconds: Int
}
public struct StatisticsCard: Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let value: String
    public let unit: String
    public let subtitle: String
    public let comparison: String
    public let trend: Int
}
public struct StatsSnapshot: Equatable, Sendable {
    public var range: StatisticsRange = .day
    public var period = PeriodDates()
    public var cards: [StatisticsCard] = []
    public var bars: [StatisticsBar] = []
    public var categories = CategoryStatistics()
    public var review: WeeklyReview?
    public init() {}
}
@MainActor @Observable public final class StatsStore {
    public private(set) var range: StatisticsRange
    public private(set) var snapshot = StatsSnapshot()
    public private(set) var logicalToday = ""
    public private(set) var errorMessage = ""
    public private(set) var reviewErrorMessage = ""
    public private(set) var hasLoaded = false
    @ObservationIgnored private let statistics: any StatisticsBridgeProtocol
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private let tasks: (any TaskBridgeProtocol)?
    @ObservationIgnored private let settings: (any SettingsBridgeProtocol)?
    @ObservationIgnored private let categories: (any CategoryBridgeProtocol)?
    @ObservationIgnored private let history: (any FocusHistoryBridgeProtocol)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var followingCurrent = true
    @ObservationIgnored private var requestedAnchor: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(statistics: any StatisticsBridgeProtocol, logicalDay: any LogicalDayBridgeProtocol,
                tasks: (any TaskBridgeProtocol)? = nil, settings: (any SettingsBridgeProtocol)? = nil,
                categories: (any CategoryBridgeProtocol)? = nil, history: (any FocusHistoryBridgeProtocol)? = nil,
                defaults: UserDefaults? = nil) {
        self.statistics = statistics; self.logicalDay = logicalDay; self.tasks = tasks; self.settings = settings
        self.categories = categories; self.history = history; self.defaults = defaults
        range = StatisticsRange(rawValue: defaults?.string(forKey: "ipadui.statistics.range") ?? "day") ?? .day
        // 各领域桥接只分配给这个 Store；同一轮任务、目标、科目与日界失效合并为一次刷新。
        let invalidate: () -> Void = { [weak self] in self?.requestRefresh() }
        logicalDay.onChanged = invalidate; tasks?.onChanged = invalidate; settings?.onDailyFocusGoalChanged = invalidate
        categories?.onChanged = invalidate; history?.onChanged = invalidate
        statistics.onFailure = { [weak self] message in
            guard let self, self.active else { return }; self.errorMessage = message
        }
    }
    public var isEmpty: Bool { hasLoaded && errorMessage.isEmpty && snapshot.categories.totalDuration == 0 }
    public var showReview: Bool {
        range == .week && (!reviewErrorMessage.isEmpty || snapshot.review?.hasDisplayContent == true)
    }
    public var periodTitle: String {
        guard hasLoaded else { return range.title }
        let period = snapshot.period
        if period.current { return snapshot.range.title }
        switch snapshot.range {
        case .day: return period.start
        case .week:
            guard let start = StatisticsFormat.parseDate(period.start), let end = StatisticsFormat.parseDate(period.end) else { return "" }
            return StatisticsFormat.formatWeekRange(start, end)
        case .month: return "\(period.year)年\(period.month)月"
        }
    }
    public func setActive(_ value: Bool) {
        active = value
        if value { refresh() } else { refreshTask?.cancel(); refreshTask = nil }
    }
    private func requestRefresh() {
        guard active, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.active else { return }
            self.refreshTask = nil; self.refresh()
        }
    }
    public func selectRange(_ value: StatisticsRange) {
        guard range != value else { return }
        range = value; followingCurrent = true; requestedAnchor = nil
        defaults?.set(value.rawValue, forKey: "ipadui.statistics.range"); refresh()
    }
    public func movePeriod(_ shift: Int) {
        guard hasLoaded, shift <= 0 || snapshot.period.canAdvance else { return }
        do {
            let next = try logicalDay.period(anchor: snapshot.period.start, range: range.rawValue, shift: shift, logicalToday: logicalToday)
            requestedAnchor = next.start; followingCurrent = next.current; refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    public func returnToCurrentPeriod() { followingCurrent = true; requestedAnchor = nil; refresh() }
    public func refresh() {
        refreshTask?.cancel(); refreshTask = nil
        do {
            // 只读一次逻辑今日；周期、周比较、复盘都使用同一串，不在日界附近各读一次时钟。
            let today = logicalDay.today
            let anchor = followingCurrent ? today : requestedAnchor ?? snapshot.period.start
            let period = try logicalDay.period(anchor: anchor, range: range.rawValue, shift: 0, logicalToday: today)
            var next = StatsSnapshot(); next.range = range; next.period = period
            let comparison: StatisticsComparison
            let primaryValue: String, primaryTitle: String, primaryUnit: String, primarySubtitle: String
            let count: Int, duration: Int
            switch range {
            case .day:
                let day = try statistics.dayStats(date: period.start)
                comparison = try statistics.dayComparison(date: period.start)
                let week = try logicalDay.period(anchor: period.start, range: "week", shift: 0, logicalToday: today)
                next.bars = try statistics.weekStats(startDate: week.start).enumerated().map {
                    StatisticsBar(id: $0.offset, label: StatisticsFormat.weekdayLabel($0.element.date, index: $0.offset), seconds: $0.element.duration)
                }
                next.categories = try statistics.categoryStats(from: period.start, to: period.end)
                primaryTitle = "任务完成"; primaryValue = "\(day.completedTasks) / \(day.totalTasks)"; primaryUnit = ""
                primarySubtitle = "完成率 " + StatisticsFormat.percent(day.completionRate * 100)
                count = day.sessionCount; duration = day.totalDuration
            case .week:
                next.bars = try statistics.weekStats(startDate: period.start).enumerated().map {
                    StatisticsBar(id: $0.offset, label: StatisticsFormat.weekdayLabel($0.element.date, index: $0.offset), seconds: $0.element.duration)
                }
                comparison = try statistics.weekComparison(startDate: period.start, logicalToday: today)
                let review = try statistics.weeklyReview(startDate: period.start, logicalToday: today)
                if review.loadState == "error" { throw NSError(domain: "周复盘", code: 1, userInfo: [NSLocalizedDescriptionKey: review.errorMessage]) }
                next.review = review
                next.categories = try statistics.categoryStats(from: period.start, to: period.end)
                primaryTitle = "有效天数"; primaryValue = String(try statistics.effectiveDays(from: period.start, to: period.end)); primaryUnit = "天"
                primarySubtitle = period.current ? "本周有记录天数" : "所选周有记录天数"
                count = try statistics.focusSessionCount(from: period.start, to: period.end)
                // 周比较在当前周不提供总量，累计直接用同范围科目统计的服务合计，不能加总图表。
                duration = next.categories.totalDuration
            case .month:
                let month = try statistics.monthStats(year: period.year, month: period.month)
                comparison = try statistics.monthComparison(year: period.year, month: period.month, current: month)
                next.bars = try statistics.monthWeeklySummary(year: period.year, month: period.month).enumerated().map {
                    StatisticsBar(id: $0.offset, label: $0.element.label, seconds: $0.element.duration)
                }
                next.categories = try statistics.categoryStats(from: period.start, to: period.end)
                primaryTitle = "有效天数"; primaryValue = String(month.effectiveDays); primaryUnit = "天"
                primarySubtitle = period.current ? "本月有记录天数" : "所选月有记录天数"
                count = month.sessionCount; duration = month.totalDuration
            }
            // 只格式化服务给的指标，当前周是否有比较认服务 hasData，不在 Swift 比两周数字。
            func card(_ id: Int, _ title: String, _ value: String, _ unit: String, _ subtitle: String, _ metric: ComparisonMetric) -> StatisticsCard {
                let oldLabel = range == .day ? "昨天" : range == .week ? "上周" : "上月"
                let text = metric.hasData ? metric.displayText.replacingOccurrences(of: oldLabel,
                    with: StatisticsFormat.comparisonLabel(range: range.rawValue, distance: period.comparisonDistance)) : ""
                return StatisticsCard(id: id, title: title, value: value, unit: unit, subtitle: subtitle, comparison: text, trend: metric.trend)
            }
            let prefix = period.current ? range.title : (range == .day ? "当日" : range == .week ? "所选周" : "所选月")
            next.cards = [card(0, primaryTitle, primaryValue, primaryUnit, primarySubtitle, range == .day ? comparison.taskCompletion : comparison.effectiveDays),
                          card(1, "专注次数", String(count), "次", prefix + "完成次数", comparison.sessionCount),
                          card(2, prefix + (range == .day ? "专注" : "累计"), StatisticsFormat.totalDurationValue(Double(duration)),
                               StatisticsFormat.totalDurationUnit(Double(duration)), prefix + "专注时长", comparison.duration)]
            // 查询失败保留旧快照；标题、图表与卡片只在同一范围全部读取成功后替换。
            snapshot = next; logicalToday = today; hasLoaded = true; requestedAnchor = nil
            followingCurrent = period.current; errorMessage = ""; reviewErrorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
            reviewErrorMessage = range == .week ? error.localizedDescription : ""
        }
    }
}
