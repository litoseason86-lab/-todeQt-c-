import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 统计页「本周」与复盘卡的接线：逻辑今天只生成一次、当前周隐藏涨跌、卡片出现条件、
// 契约缺失与整页异常的错误态、今日目标变更触发刷新，以及切换范围时统计卡高度不变。
TestCase {
    id: testCase
    name: "StatisticsWeeklyReview"
    when: windowShown
    width: 900
    height: 1400
    // 断言布局位置需要整条父链可见。
    visible: true

    QtObject {
        id: appSettings

        property int dayStartHour: 4
        property bool reduceMotion: true

        signal dailyFocusGoalChanged()
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: taskManager

        signal tasksChanged()
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged()
    }

    QtObject {
        id: statisticsService

        signal operationFailed(string message)

        property bool throwOnWeekStats: false
        property int weeklyReviewCalls: 0
        property string weekComparisonToday: ""
        property string weeklyReviewToday: ""
        property string weeklyReviewWeekStart: ""
        property var reviewData: ({})

        function reset() {
            throwOnWeekStats = false
            weeklyReviewCalls = 0
            weekComparisonToday = ""
            weeklyReviewToday = ""
            weeklyReviewWeekStart = ""
            reviewData = testCase.readyReview(false)
        }

        function comparison(text, trend) {
            return { hasData: true, displayText: text, trend: trend }
        }

        function getDayStats(day) {
            return { totalDuration: 600, completedTasks: 1, totalTasks: 2, completionRate: 0.5, sessionCount: 3 }
        }
        function getDayComparison(day) {
            return {
                taskCompletion: comparison("↘ -25% vs 昨天", -1),
                sessionCount: comparison("→ 0% vs 昨天", 0),
                duration: comparison("↗ +50% vs 昨天", 1)
            }
        }
        function getWeekStats(start) {
            if (throwOnWeekStats) {
                throw new Error("week stats failed")
            }
            return []
        }
        // 与服务契约一致：当前周（逻辑今天落在所选周内）三项指标 hasData 为假。
        function getWeekComparison(weekStart, logicalTodayIso) {
            weekComparisonToday = String(logicalTodayIso)
            var start = Qt.formatDate(weekStart, "yyyy-MM-dd")
            var end = Qt.formatDate(new Date(weekStart.getFullYear(), weekStart.getMonth(),
                                             weekStart.getDate() + 6), "yyyy-MM-dd")
            if (logicalTodayIso >= start && logicalTodayIso <= end) {
                var none = { hasData: false, displayText: "", trend: 0 }
                return { periodState: "current", effectiveDays: none, sessionCount: none, duration: none }
            }
            return {
                periodState: "ended",
                effectiveDays: comparison("↗ +20% vs 上周", 1),
                sessionCount: comparison("→ 0% vs 上周", 0),
                duration: comparison("↘ -25% vs 上周", -1)
            }
        }
        function getWeeklyReview(weekStart, logicalTodayIso) {
            weeklyReviewCalls += 1
            weeklyReviewToday = String(logicalTodayIso)
            weeklyReviewWeekStart = Qt.formatDate(weekStart, "yyyy-MM-dd")
            return reviewData
        }
        function getEffectiveDays(start, end) { return 2 }
        function getFocusSessionCount(start, end) { return 3 }
        function getCategoryStats(start, end) { return { categories: [], totalDuration: 0 } }
        function getMonthStats(year, month) {
            return { totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 }
        }
        function getMonthComparison(year, month, precomputed) {
            return {
                effectiveDays: comparison("↗ +40% vs 上月", 1),
                sessionCount: comparison("↘ -10% vs 上月", -1),
                duration: comparison("→ 0% vs 上月", 0)
            }
        }
        function getMonthWeeklySummary(year, month) { return [] }
    }

    // 旧上下文或接线错误：没有复盘接口。
    QtObject {
        id: statisticsServiceWithoutReview

        function getWeekStats(start) { return [] }
        function getWeekComparison(weekStart, logicalTodayIso) { return {} }
        function getEffectiveDays(start, end) { return 0 }
        function getFocusSessionCount(start, end) { return 0 }
        function getCategoryStats(start, end) { return { categories: [], totalDuration: 0 } }
        function getDayStats(day) {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0, sessionCount: 0 }
        }
        function getDayComparison(day) { return {} }
    }

    StatisticsView {
        id: view

        width: 900
        height: 1400
        taskManagerRef: taskManager
        statisticsServiceRef: statisticsService
        focusTimerRef: focusTimer
        logicalDayServiceRef: logicalDayService
        appSettingsRef: appSettings
        categoryManagerRef: categoryManager
        currentDateOverride: new Date(2026, 6, 15, 12, 0)
    }

    function readyReview(withContent) {
        return {
            loadState: "ready",
            periodState: "current",
            weekStart: "2026-07-13",
            weekEnd: "2026-07-19",
            hasData: withContent,
            hasDisplayContent: withContent,
            goal: { goalDays: withContent ? 2 : 0, metDays: 1, goalMinutesTotal: 120,
                    actualSecondsTotal: 3600, days: [] },
            todayGoal: {},
            subjects: [],
            plannedTasks: { rows: [], inProgress: true },
            facts: []
        }
    }

    function errorReview() {
        return {
            loadState: "error",
            errorMessage: "no such table: focus_sessions",
            periodState: "ended",
            hasData: false,
            hasDisplayContent: false,
            goal: {},
            todayGoal: {},
            subjects: [],
            plannedTasks: {},
            facts: []
        }
    }

    function init() {
        statisticsService.reset()
        view.statisticsServiceRef = statisticsService
        view.pageActive = true
        view.currentDateOverride = new Date(2026, 6, 15, 12, 0)
        view.currentTimeRange = "today"
        view.refreshCurrentDateSnapshot()
        view.applyCurrentPeriodSelection()
        view.refresh()
        wait(20)
    }

    function statCards() {
        return [findChild(view, "statisticsPrimaryStatCard"),
                findChild(view, "statisticsSessionCountStatCard"),
                findChild(view, "statisticsTotalDurationStatCard")]
    }

    function test_refreshPassesOneLogicalTodayToComparisonAndReview() {
        // 周一 03:59:59、日界 04:00：逻辑今天还是周日，本周仍是 7-13 那一周。
        view.currentDateOverride = new Date(2026, 6, 20, 3, 59, 59)
        view.currentTimeRange = "week"
        compare(statisticsService.weekComparisonToday, "2026-07-19")
        compare(statisticsService.weeklyReviewToday, "2026-07-19")
        compare(statisticsService.weeklyReviewWeekStart, "2026-07-13")

        // 04:00 进入周一逻辑日：两个接口收到同一个新日期，停在当前期的页面跟着进入新一周。
        view.currentDateOverride = new Date(2026, 6, 20, 4, 0, 0)
        view.refresh()
        compare(statisticsService.weekComparisonToday, "2026-07-20")
        compare(statisticsService.weeklyReviewToday, "2026-07-20")
        compare(statisticsService.weeklyReviewWeekStart, "2026-07-20")
    }

    function test_currentWeekHidesComparisonsAndHistoricWeekKeepsThem() {
        view.currentTimeRange = "week"
        var cards = statCards()
        for (var i = 0; i < cards.length; ++i) {
            compare(cards[i].showComparison, false)
        }

        view.goToPreviousPeriod()
        for (var j = 0; j < cards.length; ++j) {
            compare(cards[j].showComparison, true)
        }
        compare(cards[0].comparisonText, "↗ +20% vs 上上周")
        compare(cards[2].comparisonText, "↘ -25% vs 上上周")
    }

    function test_cardHeightsAndTrendPositionStayStableAcrossRanges() {
        var trend = findChild(view, "statisticsTrendChart")
        verify(trend)
        var cards = statCards()
        wait(50)
        const trendY = trend.y
        const expectHeights = function(tag) {
            for (var i = 0; i < cards.length; ++i) {
                compare(cards[i].implicitHeight, 126, tag)
            }
        }

        expectHeights("今日")
        view.currentTimeRange = "week"
        wait(50)
        // 当前周隐藏涨跌：比较行照样占位，卡片与下方趋势图都不跳。
        compare(cards[0].showComparison, false)
        expectHeights("本周")
        compare(trend.y, trendY)

        view.goToPreviousPeriod()
        wait(50)
        expectHeights("上一周")
        compare(trend.y, trendY)

        view.currentTimeRange = "month"
        wait(50)
        expectHeights("本月")
        compare(trend.y, trendY)
    }

    function test_reviewCardOccupiesLayoutOnlyWithContentOrError() {
        var trend = findChild(view, "statisticsTrendChart")
        var pie = findChild(view, "statisticsCategoryChart")
        var card = findChild(view, "statisticsWeeklyReviewCard")
        verify(trend && pie && card)

        // 加载成功但没有可展示的块：卡片不占位，饼图紧接趋势图。
        statisticsService.reviewData = readyReview(false)
        view.currentTimeRange = "week"
        wait(50)
        compare(pie.y, trend.y + trend.height + Theme.space16)

        // 有内容：卡片夹在两图之间，上下都是统一的列间距，没有额外底边距。
        statisticsService.reviewData = readyReview(true)
        view.refresh()
        wait(50)
        verify(card.height > 0)
        compare(card.y, trend.y + trend.height + Theme.space16)
        compare(pie.y, card.y + card.height + Theme.space16)

        // 查询失败：错误态必须占位显示，不能当成空周藏起来。
        statisticsService.reviewData = errorReview()
        view.refresh()
        wait(50)
        compare(card.y, trend.y + trend.height + Theme.space16)
        compare(pie.y, card.y + card.height + Theme.space16)
        compare(card.errorState, true)
    }

    function test_missingReviewInterfaceIsContractError() {
        view.statisticsServiceRef = statisticsServiceWithoutReview
        view.currentTimeRange = "week"
        compare(view.weeklyReview.loadState, "error")
        compare(view.weeklyReview.errorMessage, "复盘接口缺失")
    }

    function test_pageExceptionMarksReviewAsError() {
        statisticsService.throwOnWeekStats = true
        view.currentTimeRange = "week"
        compare(view.loadError, "统计数据加载失败")
        compare(view.weeklyReview.loadState, "error")

        // 恢复后经正常刷新回到成功状态。
        statisticsService.throwOnWeekStats = false
        view.refresh()
        compare(view.loadError, "")
        compare(view.weeklyReview.loadState, "ready")
    }

    function test_dailyGoalChangeRefreshesReview() {
        view.currentTimeRange = "week"
        var before = statisticsService.weeklyReviewCalls
        appSettings.dailyFocusGoalChanged()
        tryCompare(statisticsService, "weeklyReviewCalls", before + 1, 3000)

        // 页面不活跃时不查询；重新激活时刷新。
        view.pageActive = false
        before = statisticsService.weeklyReviewCalls
        appSettings.dailyFocusGoalChanged()
        wait(50)
        compare(statisticsService.weeklyReviewCalls, before)
        view.pageActive = true
        tryVerify(function() { return statisticsService.weeklyReviewCalls > before }, 3000)
    }
}
