import Foundation
import Observation

public enum StatisticsRange: String, CaseIterable, Sendable { case day, week, month
    public var title: String { switch self { case .day: "今日"; case .week: "本周"; case .month: "本月" } }
    public var segmentTitle: String { switch self { case .day: "日"; case .week: "周"; case .month: "月" } }
}
public struct StatisticsBar: Equatable, Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let seconds: Int
    public let date: String
    public let today: Bool
    public init(id: Int, label: String, seconds: Int, date: String = "", today: Bool = false) {
        self.id = id; self.label = label; self.seconds = seconds; self.date = date; self.today = today
    }
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
    public private(set) var selectedBarLabel: String?
    public private(set) var selectedCategoryIndex: Int?
    public func selectBar(_ label: String?) {
        selectedBarLabel = snapshot.bars.contains { $0.label == label } ? label : nil
    }
    public func selectCategory(_ index: Int?) {
        guard let index, snapshot.categories.categories.indices.contains(index) else { selectedCategoryIndex = nil; return }
        selectedCategoryIndex = index
    }
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
        // 后台统计失败由外壳提示，本页只显示自己读取时抛出的错误。
        statistics.onFailure = nil
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
    public var periodSubtitle: String {
        guard hasLoaded else { return "" }
        let period = snapshot.period
        let dates = period.start == period.end ? period.start : period.start + " – " + period.end
        return period.current ? snapshot.range.title + " · " + dates : dates
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
            let count: Int, duration: Int
            let secondary: (title: String, value: String, unit: String, subtitle: String, metric: ComparisonMetric)
            func weekBars(_ rows: [WeekDayStatistics]) throws -> [StatisticsBar] {
                try rows.enumerated().map { index, row in
                    StatisticsBar(id: index, label: StatisticsFormat.weekdayLabel(row.date, index: index), seconds: row.duration,
                                  date: row.date, today: try logicalDay.relation(row.date, to: today) == .same)
                }
            }
            switch range {
            case .day:
                let day = try statistics.dayStats(date: period.start)
                comparison = try statistics.dayComparison(date: period.start)
                let week = try logicalDay.period(anchor: period.start, range: "week", shift: 0, logicalToday: today)
                next.bars = try weekBars(statistics.weekStats(startDate: week.start))
                next.categories = try statistics.categoryStats(from: period.start, to: period.end)
                // 日卡取任务完成指标和服务完成率，不把已完成数除以任务数重新计算。
                secondary = ("任务完成", "\(day.completedTasks) / \(day.totalTasks)", "",
                             "完成率 \(Int((day.completionRate * 100).rounded()))%", comparison.taskCompletion)
                count = day.sessionCount; duration = day.totalDuration
            case .week:
                next.bars = try weekBars(statistics.weekStats(startDate: period.start))
                comparison = try statistics.weekComparison(startDate: period.start, logicalToday: today)
                let review = try statistics.weeklyReview(startDate: period.start, logicalToday: today)
                if review.loadState == "error" { throw NSError(domain: "周复盘", code: 1, userInfo: [NSLocalizedDescriptionKey: review.errorMessage]) }
                next.review = review
                next.categories = try statistics.categoryStats(from: period.start, to: period.end)
                secondary = ("有记录天数", String(try statistics.effectiveDays(from: period.start, to: period.end)), "天", "", comparison.effectiveDays)
                count = try statistics.focusSessionCount(from: period.start, to: period.end)
                // 当前周比较不提供总量，累计继续使用同范围科目统计的服务合计，不能加总图表。
                duration = next.categories.totalDuration
            case .month:
                let month = try statistics.monthStats(year: period.year, month: period.month)
                comparison = try statistics.monthComparison(year: period.year, month: period.month, current: month)
                // 现有按日汇总接口已包含零投入日；只投影顺序与秒数，不在 Swift 拆周、补日或加总。
                let summary = try statistics.focusSummary(from: period.start, to: period.end, dayStartHour: logicalDay.dayStartHour)
                next.bars = try summary.days.enumerated().map { index, row in
                    StatisticsBar(id: index, label: TrashFormat.dateLabel(row.date, today: today), seconds: row.seconds,
                                  date: row.date, today: try logicalDay.relation(row.date, to: today) == .same)
                }
                next.categories = try statistics.categoryStats(from: period.start, to: period.end)
                secondary = ("有记录天数", String(month.effectiveDays), "天", "", comparison.effectiveDays)
                count = month.sessionCount; duration = month.totalDuration
            }
            // hasData（服务是否提供可展示的比较）决定留白；当前周由服务关闭，日/月不另加当前期门禁。
            func card(_ id: Int, _ title: String, _ value: String, _ unit: String, _ metric: ComparisonMetric, subtitle: String = "") -> StatisticsCard {
                let oldLabel = range == .day ? "昨天" : range == .week ? "上周" : "上月"
                let text = metric.hasData ? metric.displayText.replacingOccurrences(of: oldLabel,
                    with: StatisticsFormat.comparisonLabel(range: range.rawValue, distance: period.comparisonDistance)) : ""
                return StatisticsCard(id: id, title: title, value: value, unit: unit, subtitle: subtitle, comparison: text, trend: metric.trend)
            }
            next.cards = [card(2, "专注时长", StatisticsFormat.totalDurationValue(Double(duration)),
                               StatisticsFormat.totalDurationUnit(Double(duration)), comparison.duration),
                          card(0, secondary.title, secondary.value, secondary.unit, secondary.metric, subtitle: secondary.subtitle),
                          card(1, "完成次数", String(count), "次", comparison.sessionCount)]
            // 成功换数据后才清图表选择；失败不能清掉旧读数或换上半份图表。
            if next.bars != snapshot.bars { selectedBarLabel = nil }
            if next.categories != snapshot.categories { selectedCategoryIndex = nil }
            // 查询失败保留旧快照；标题、图表与卡片只在同一范围全部读取成功后替换。
            snapshot = next; logicalToday = today; hasLoaded = true; requestedAnchor = nil
            followingCurrent = period.current; errorMessage = ""; reviewErrorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
            reviewErrorMessage = range == .week ? error.localizedDescription : ""
        }
    }
}
