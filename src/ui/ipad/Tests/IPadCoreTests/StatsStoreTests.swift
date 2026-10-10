import XCTest
@testable import IPadCore

// 读取计数替身故意让第二次读取跨日界，识别一次刷新内各模块各读时钟的实现。
@MainActor private final class CountingDayBridge: LogicalDayBridgeProtocol {
    let fake = LogicalDayBridgeFake()
    var reads = 0
    var alternateReads = false
    var today: String { reads += 1; return alternateReads && reads > 1 ? "2024-02-16" : fake.today }
    var dayStartHour: Int { fake.dayStartHour }
    var onChanged: (() -> Void)? { get { fake.onChanged } set { fake.onChanged = newValue } }
    func relation(_ date: String, to reference: String) throws -> DateRelation { try fake.relation(date, to: reference) }
    func period(anchor: String, range: String, shift: Int, logicalToday: String) throws -> PeriodDates {
        try fake.period(anchor: anchor, range: range, shift: shift, logicalToday: logicalToday)
    }
    init() {
        fake.today = "2024-02-15"
        // 替身只提供日历结果供参数验证；真实 QDate 导航由 PTCoreBridgeTests 单独覆盖。
        fake.periodHandler = { anchor, range, shift, today in
            let calendar = Calendar(identifier: .gregorian)
            let source = StatisticsFormat.parseDate(anchor)!, reference = StatisticsFormat.parseDate(today)!
            func start(_ date: Date) -> Date {
                if range == "week" { return StatisticsFormat.mondayOf(date) }
                if range == "month" { return calendar.date(from: calendar.dateComponents([.year, .month], from: date))! }
                return calendar.startOfDay(for: date)
            }
            let base = start(source), current = start(reference)
            let date = calendar.date(byAdding: range == "month" ? .month : .day, value: range == "week" ? shift * 7 : shift, to: base)!
            let end = range == "month" ? calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: date)!)!
                : range == "week" ? StatisticsFormat.endOfWeek(date) : date
            var result = PeriodDates(); result.start = MonthGoalFormat.isoDate(date); result.end = MonthGoalFormat.isoDate(end)
            result.year = calendar.component(.year, from: date); result.month = calendar.component(.month, from: date)
            result.current = date == current; result.canAdvance = date < current
            result.comparisonDistance = result.current ? 1 : 2
            return result
        }
    }
}
@MainActor final class StatsStoreTests: XCTestCase {
    // 产品保证：每次刷新只读取一次逻辑今日，周比较与复盘共用该值。
    func testOneLogicalTodayForComparisonAndReview() {
        let statistics = StatisticsBridgeFake(), day = CountingDayBridge()
        let store = StatsStore(statistics: statistics, logicalDay: day)
        store.setActive(true); day.reads = 0; day.alternateReads = true; statistics.calls.removeAll()
        store.selectRange(.week)
        XCTAssertEqual(day.reads, 1)
        XCTAssertEqual(statistics.calls.first { $0.0 == "weekComparison" }?.1, ["2024-02-12", "2024-02-15"])
        XCTAssertEqual(statistics.calls.first { $0.0 == "weeklyReview" }?.1, ["2024-02-12", "2024-02-15"])
    }
    // 产品保证：日、周、月翻页使用桥接给的周期，历史可向前返回，当前期不允许前进到未来。
    func testRangeNavigationParametersAndForwardBoundary() {
        let statistics = StatisticsBridgeFake(), day = CountingDayBridge()
        let store = StatsStore(statistics: statistics, logicalDay: day)
        store.setActive(true)
        XCTAssertEqual(store.snapshot.period.start, "2024-02-15")
        let count = statistics.calls.count
        store.movePeriod(1); XCTAssertEqual(statistics.calls.count, count)
        store.movePeriod(-1)
        XCTAssertEqual(statistics.calls.last { $0.0 == "dayStats" }?.1, ["2024-02-14"])
        store.movePeriod(1); XCTAssertEqual(store.snapshot.period.start, "2024-02-15")
        store.selectRange(.week); store.movePeriod(-1)
        XCTAssertEqual(statistics.calls.last { $0.0 == "weekStats" }?.1, ["2024-02-05"])
        XCTAssertEqual(statistics.calls.last { $0.0 == "categoryStats" }?.1, ["2024-02-05", "2024-02-11"])
        store.selectRange(.month)
        XCTAssertEqual(statistics.calls.last { $0.0 == "categoryStats" }?.1, ["2024-02-01", "2024-02-29"])
        store.movePeriod(-1)
        XCTAssertEqual(statistics.calls.last { $0.0 == "monthStats" }?.2, [2024, 1])
        XCTAssertEqual(statistics.calls.last { $0.0 == "categoryStats" }?.1, ["2024-01-01", "2024-01-31"])
        XCTAssertEqual(statistics.suppliedMonths.last, statistics.month)
    }
    // 产品保证：已结束周保留顶部整周比较，复盘消费结构化事实；当前周认服务无比较结果。
    func testCurrentAndEndedWeekPresentation() {
        let statistics = StatisticsBridgeFake()
        statistics.review.periodState = "current"; statistics.review.hasDisplayContent = true
        let store = StatsStore(statistics: statistics, logicalDay: CountingDayBridge())
        store.setActive(true); store.selectRange(.week)
        XCTAssertTrue(store.showReview)
        XCTAssertTrue(store.snapshot.cards.allSatisfy { $0.comparison.isEmpty })
        statistics.review.periodState = "ended"
        var fact = ReviewFact(); fact.type = "estimateOnTrack"; statistics.review.facts = [fact]
        statistics.comparison.duration.hasData = true
        statistics.comparison.duration.displayText = "比上周增加 25%"; statistics.comparison.duration.trend = 1
        store.movePeriod(-1)
        XCTAssertEqual(store.snapshot.cards.first?.comparison, "比上上周增加 25%")
        XCTAssertEqual(store.snapshot.review?.periodState, "ended")
        XCTAssertEqual(store.snapshot.review?.facts, [fact])
        XCTAssertEqual(store.snapshot.cards.first?.trend, 1)
    }
    // 产品保证：图表顺序与秒数原样来自服务，周累计使用服务合计，不把图表各项重新加总。
    func testChartsPreserveServiceOrderAndTotals() {
        let statistics = StatisticsBridgeFake()
        var late = WeekDayStatistics(); late.date = "2024-02-16"; late.duration = 86400
        var early = WeekDayStatistics(); early.date = "2024-02-12"; early.duration = 100
        statistics.weekDays = [late, early]
        var b = CategoryStatisticsRow(); b.name = "乙"; b.duration = 987; b.percentage = 27
        var a = CategoryStatisticsRow(); a.name = "甲"; a.duration = 123; a.percentage = 73
        statistics.categoryStats.categories = [b, a]; statistics.categoryStats.totalDuration = 3789
        let store = StatsStore(statistics: statistics, logicalDay: CountingDayBridge())
        store.setActive(true); store.selectRange(.week)
        XCTAssertEqual(store.snapshot.bars.map(\.seconds), [86400, 100])
        XCTAssertEqual(store.snapshot.bars.map(\.label), ["周五", "周一"])
        XCTAssertEqual(store.snapshot.categories, statistics.categoryStats)
        XCTAssertEqual(store.snapshot.cards.first?.value, "1.1")
        XCTAssertEqual(store.snapshot.cards.first?.unit, "小时")
        var second = FocusSummaryDay(); second.date = "2024-02-16"; second.seconds = 19
        var first = FocusSummaryDay(); first.date = "2024-02-12"; first.seconds = 71
        statistics.summary.days = [second, first]; store.selectRange(.month)
        XCTAssertEqual(store.snapshot.bars.map(\.date), ["2024-02-16", "2024-02-12"])
        XCTAssertEqual(store.snapshot.bars.map(\.seconds), [19, 71])
        XCTAssertEqual(statistics.calls.last { $0.0 == "focusSummary" }?.1, ["2024-02-01", "2024-02-29"])
        XCTAssertEqual(statistics.calls.last { $0.0 == "focusSummary" }?.2, [4])
    }
    // 产品保证：查询失败与空数据分开，失败保留已成功快照，重试成功才清错。
    func testReadFailurePreservesSnapshotAndDiffersFromEmpty() {
        let statistics = StatisticsBridgeFake(), store = StatsStore(statistics: StatisticsBridgeFake(), logicalDay: CountingDayBridge())
        store.setActive(true); XCTAssertTrue(store.isEmpty)
        let tested = StatsStore(statistics: statistics, logicalDay: CountingDayBridge())
        statistics.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "SQL 失败"])
        tested.setActive(true); XCTAssertFalse(tested.hasLoaded); XCTAssertFalse(tested.isEmpty)
        statistics.error = nil; statistics.day.totalDuration = 123; statistics.categoryStats.totalDuration = 123
        tested.refresh(); let snapshot = tested.snapshot
        XCTAssertEqual(snapshot.cards.first?.value, "2")
        statistics.error = NSError(domain: "测试", code: 2, userInfo: [NSLocalizedDescriptionKey: "再次失败"])
        tested.refresh(); XCTAssertEqual(tested.snapshot, snapshot); XCTAssertEqual(tested.errorMessage, "再次失败")
        statistics.error = nil; tested.refresh(); XCTAssertEqual(tested.errorMessage, "")
        tested.selectRange(.week)
        statistics.review.loadState = "error"; statistics.review.errorMessage = "复盘失败"
        tested.refresh(); XCTAssertEqual(tested.reviewErrorMessage, "复盘失败"); XCTAssertTrue(tested.showReview)
    }
    // 产品保证：日界变化跟随当前周期而保留历史周期，同轮失效合并，隐藏页不查库。
    func testSignalsCoalesceAndCurrentPeriodFollowsBoundary() async {
        let statistics = StatisticsBridgeFake(), day = CountingDayBridge(), tasks = TaskBridgeFake()
        let settings = SettingsBridgeFake(), categories = CategoryBridgeFake(), history = FocusHistoryBridgeFake()
        let store = StatsStore(statistics: statistics, logicalDay: day, tasks: tasks, settings: settings, categories: categories, history: history)
        store.setActive(true)
        let before = day.reads
        tasks.onChanged?(); settings.onDailyFocusGoalChanged?(); categories.onChanged?(); history.onChanged?()
        // 用可观察刷新次数等待队列，避免依赖固定墙钟或主机负载。
        for _ in 0..<100 where day.reads == before { await Task.yield() }
        XCTAssertEqual(day.reads, before + 1)
        day.fake.today = "2024-02-16"
        for _ in 0..<100 where store.snapshot.period.start != "2024-02-16" { await Task.yield() }
        XCTAssertEqual(store.snapshot.period.start, "2024-02-16")
        store.movePeriod(-1)
        XCTAssertEqual(store.snapshot.period.start, "2024-02-15")
        day.fake.today = "2024-02-17"
        let historical = day.reads
        for _ in 0..<100 where day.reads == historical { await Task.yield() }
        XCTAssertEqual(store.snapshot.period.start, "2024-02-15")
        store.setActive(false); let inactive = day.reads
        tasks.onChanged?(); day.fake.today = "2024-02-18"
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(day.reads, inactive)
        store.setActive(true); XCTAssertEqual(day.reads, inactive + 1)
    }
    // 产品保证：范围状态只存本机 ipadui 键，不创建同步或业务状态；测试设置域独立隔离。
    func testRangePreferenceStaysLocal() {
        let name = "P4-4-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("week", forKey: "ipadui.statistics.range")
        let store = StatsStore(statistics: StatisticsBridgeFake(), logicalDay: CountingDayBridge(), defaults: defaults)
        XCTAssertEqual(store.range, .week)
        store.setActive(true); store.selectRange(.month)
        XCTAssertEqual(defaults.string(forKey: "ipadui.statistics.range"), "month")
    }
    // 产品保证：日、周、月的数字卡统一按专注时长、有记录天数、完成次数排列，直接消费各服务指标。
    func testCardsUseServiceValuesInDesignOrderForEveryRange() {
        let statistics = StatisticsBridgeFake(); statistics.day.totalDuration = 1337; statistics.day.sessionCount = 9
        statistics.day.completedTasks = 88; statistics.day.totalTasks = 99
        statistics.effectiveDayCount = 0; statistics.sessionCount = 13
        statistics.categoryStats.totalDuration = 3789
        statistics.month.totalDuration = 4499; statistics.month.effectiveDays = 17; statistics.month.sessionCount = 29
        let store = StatsStore(statistics: statistics, logicalDay: CountingDayBridge()); store.setActive(true)
        XCTAssertEqual(store.snapshot.cards.map(\.title), ["专注时长", "有记录天数", "完成次数"])
        XCTAssertEqual(store.snapshot.cards.map(\.value), [StatisticsFormat.totalDurationValue(1337), "0", "9"])
        store.selectRange(.week)
        XCTAssertEqual(store.snapshot.cards.map(\.value), [StatisticsFormat.totalDurationValue(3789), "0", "13"])
        store.selectRange(.month)
        XCTAssertEqual(store.snapshot.cards.map(\.value), [StatisticsFormat.totalDurationValue(4499), "17", "29"])
    }

    // 产品保证：所有当前周期均隐藏比较，即使服务返回比较值；结束周期才显示。
    func testCurrentRangesHideComparisonButEndedRangesShowIt() {
        let statistics = StatisticsBridgeFake()
        var metric = ComparisonMetric(); metric.hasData = true; metric.displayText = "比昨天增加 20%"
        statistics.comparison.duration = metric; statistics.comparison.effectiveDays = metric
        statistics.comparison.sessionCount = metric; statistics.comparison.taskCompletion = metric
        let store = StatsStore(statistics: statistics, logicalDay: CountingDayBridge()); store.setActive(true)
        for range in StatisticsRange.allCases {
            store.selectRange(range)
            XCTAssertTrue(store.snapshot.period.current)
            XCTAssertTrue(store.snapshot.cards.allSatisfy { $0.comparison.isEmpty }, range.rawValue)
            store.movePeriod(-1); XCTAssertFalse(store.snapshot.period.current)
            XCTAssertTrue(store.snapshot.cards.allSatisfy { !$0.comparison.isEmpty }, range.rawValue)
        }
    }

    // 产品保证：今日柱只认服务日期关系；图表选择在读失败时保留，成功换数据后才清掉。
    func testChartSelectionAndTodayMarkFollowSuccessfulSnapshot() {
        let statistics = StatisticsBridgeFake(), day = CountingDayBridge()
        var row = WeekDayStatistics(); row.date = "2030-01-01"; row.duration = 123
        statistics.weekDays = [row]
        // 故意让与设备日期无关的日期得到 same，任何 Swift 日期比较都会给出错误标记。
        day.fake.relations["2030-01-01/2024-02-15"] = .same
        var category = CategoryStatisticsRow(); category.name = "数学"; category.duration = 987; category.percentage = 25
        statistics.categoryStats.categories = [category]
        let store = StatsStore(statistics: statistics, logicalDay: day); store.setActive(true)
        XCTAssertEqual(store.snapshot.bars.count, 1)
        XCTAssertTrue(store.snapshot.bars[0].today); XCTAssertEqual(store.snapshot.bars[0].date, row.date)
        let label = store.snapshot.bars[0].label
        store.selectBar(label); store.selectCategory(0)
        XCTAssertEqual(store.selectedBarLabel, label); XCTAssertEqual(store.selectedCategoryIndex, 0)
        statistics.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])
        store.refresh(); XCTAssertEqual(store.selectedBarLabel, label); XCTAssertEqual(store.selectedCategoryIndex, 0)
        statistics.error = nil; statistics.weekDays[0].duration = 456
        statistics.categoryStats.categories[0].duration = 999; store.refresh()
        XCTAssertNil(store.selectedBarLabel); XCTAssertNil(store.selectedCategoryIndex)
        store.selectBar("不存在"); store.selectCategory(99)
        XCTAssertNil(store.selectedBarLabel); XCTAssertNil(store.selectedCategoryIndex)
    }

}
