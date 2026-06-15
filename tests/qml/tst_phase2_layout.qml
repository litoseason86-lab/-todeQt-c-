import QtQuick
import QtTest
import "../../qml/components"
import "../../qml/views"
import "../../qml"

TestCase {
    id: testCase
    name: "Phase2Layout"
    when: windowShown
    width: 900
    height: 640
    property date todaySnapshot: new Date()

    QtObject {
        id: taskManager

        signal tasksChanged()
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)
    }

    QtObject {
        id: statisticsService

        property int effectiveDaysCalls: 0
        property int focusSessionCountCalls: 0
        property int dayStatsCalls: 0
        property int weekStatsCalls: 0
        property int monthStatsCalls: 0
        property int monthWeeklySummaryCalls: 0
        property int dayComparisonCalls: 0
        property int weekComparisonCalls: 0
        property int monthComparisonCalls: 0
        property string lastDayStatsDate: ""
        property string lastDayComparisonDate: ""
        property string lastWeekStatsStartDate: ""
        property string lastWeekComparisonStartDate: ""
        property string lastEffectiveDaysStartDate: ""
        property string lastEffectiveDaysEndDate: ""
        property string lastFocusSessionCountStartDate: ""
        property string lastFocusSessionCountEndDate: ""
        property int lastMonthStatsYear: 0
        property int lastMonthStatsMonth: 0
        property int lastMonthComparisonYear: 0
        property int lastMonthComparisonMonth: 0
        property int lastMonthWeeklySummaryYear: 0
        property int lastMonthWeeklySummaryMonth: 0
        property string lastCategoryStartDate: ""
        property string lastCategoryEndDate: ""

        function resetTracking() {
            effectiveDaysCalls = 0
            focusSessionCountCalls = 0
            dayStatsCalls = 0
            weekStatsCalls = 0
            monthStatsCalls = 0
            monthWeeklySummaryCalls = 0
            dayComparisonCalls = 0
            weekComparisonCalls = 0
            monthComparisonCalls = 0
            lastDayStatsDate = ""
            lastDayComparisonDate = ""
            lastWeekStatsStartDate = ""
            lastWeekComparisonStartDate = ""
            lastEffectiveDaysStartDate = ""
            lastEffectiveDaysEndDate = ""
            lastFocusSessionCountStartDate = ""
            lastFocusSessionCountEndDate = ""
            lastMonthStatsYear = 0
            lastMonthStatsMonth = 0
            lastMonthComparisonYear = 0
            lastMonthComparisonMonth = 0
            lastMonthWeeklySummaryYear = 0
            lastMonthWeeklySummaryMonth = 0
            lastCategoryStartDate = ""
            lastCategoryEndDate = ""
        }

        function getDayStats(date) {
            dayStatsCalls += 1
            lastDayStatsDate = testCase.isoDateOrEmpty(date)
            return { totalDuration: 600, completedTasks: 1, totalTasks: 2, completionRate: 0.5, sessionCount: 4 }
        }

        function getTodayStats() {
            return { totalDuration: 600, completedTasks: 1, totalTasks: 2, completionRate: 0.5, sessionCount: 4 }
        }

        function makeComparison(displayText, trend) {
            return { hasData: true, displayText: displayText, trend: trend }
        }

        function getDayComparison(date) {
            dayComparisonCalls += 1
            lastDayComparisonDate = testCase.isoDateOrEmpty(date)
            return {
                taskCompletion: makeComparison("↘ -25% vs 昨天", -1),
                sessionCount: makeComparison("→ 0% vs 昨天", 0),
                duration: makeComparison("↗ +50% vs 昨天", 1)
            }
        }

        function getWeekStats(weekStart) {
            weekStatsCalls += 1
            lastWeekStatsStartDate = testCase.isoDateOrEmpty(weekStart)
            var start = lastWeekStatsStartDate.length > 0 ? testCase.dateOnly(weekStart) : testCase.mondayOf(testCase.todaySnapshot)
            return [
                { date: testCase.isoDate(testCase.addDays(start, 0)), duration: 1800 },
                { date: testCase.isoDate(testCase.addDays(start, 1)), duration: 0 },
                { date: testCase.isoDate(testCase.addDays(start, 2)), duration: 3600 },
                { date: testCase.isoDate(testCase.addDays(start, 3)), duration: 0 },
                { date: testCase.isoDate(testCase.addDays(start, 4)), duration: 0 },
                { date: testCase.isoDate(testCase.addDays(start, 5)), duration: 0 },
                { date: testCase.isoDate(testCase.addDays(start, 6)), duration: 0 }
            ]
        }

        function getWeekComparison(weekStart) {
            weekComparisonCalls += 1
            lastWeekComparisonStartDate = testCase.isoDateOrEmpty(weekStart)
            return {
                effectiveDays: makeComparison("↗ +20% vs 上周", 1),
                sessionCount: makeComparison("→ 0% vs 上周", 0),
                duration: makeComparison("↘ -25% vs 上周", -1)
            }
        }

        function getCategoryStats(startDate, endDate) {
            lastCategoryStartDate = String(startDate)
            lastCategoryEndDate = String(endDate)
            return {
                categories: [
                    { name: "数学", duration: 1800, color: "#d4a574" }
                ],
                totalDuration: 1800
            }
        }

        function getEffectiveDays(startDate, endDate) {
            effectiveDaysCalls += 1
            lastEffectiveDaysStartDate = testCase.isoDateOrEmpty(startDate)
            lastEffectiveDaysEndDate = testCase.isoDateOrEmpty(endDate)
            return 3
        }

        function getFocusSessionCount(startDate, endDate) {
            focusSessionCountCalls += 1
            lastFocusSessionCountStartDate = testCase.isoDateOrEmpty(startDate)
            lastFocusSessionCountEndDate = testCase.isoDateOrEmpty(endDate)
            return 4
        }

        function getMonthStats(year, month) {
            monthStatsCalls += 1
            lastMonthStatsYear = Number(year || 0)
            lastMonthStatsMonth = Number(month || 0)
            return {
                totalDuration: 7200,
                effectiveDays: 5,
                sessionCount: 8,
                completedTasks: 0,
                totalTasks: 0
            }
        }

        function getMonthComparison(year, month) {
            monthComparisonCalls += 1
            lastMonthComparisonYear = Number(year || 0)
            lastMonthComparisonMonth = Number(month || 0)
            return {
                effectiveDays: makeComparison("↗ +40% vs 上月", 1),
                sessionCount: makeComparison("↘ -10% vs 上月", -1),
                duration: makeComparison("→ 0% vs 上月", 0)
            }
        }

        function getMonthWeeklySummary(year, month) {
            monthWeeklySummaryCalls += 1
            lastMonthWeeklySummaryYear = Number(year || 0)
            lastMonthWeeklySummaryMonth = Number(month || 0)
            return [
                { label: "第1周", duration: 3600, startDate: "2026-06-01", endDate: "2026-06-07" },
                { label: "第2周", duration: 7200, startDate: "2026-06-08", endDate: "2026-06-14" }
            ]
        }
    }

    StatisticsView {
        id: statisticsView

        width: 520
        height: 360
        visible: false
    }

    TodayTaskView {
        id: todayTaskView

        width: 520
        height: 360
        visible: false
    }

    ChartBar {
        id: emptyBarChart
        width: 520
        height: 220
        dataPoints: []
    }

    ChartPie {
        id: emptyPieChart
        width: 520
        height: 220
        dataPoints: []
    }

    ChartBar {
        id: zeroBarChart
        width: 520
        height: 220
        dataPoints: [
            { label: "周一", value: 0 },
            { label: "周二", value: 0 }
        ]
    }

    ChartPie {
        id: zeroPieChart
        width: 520
        height: 220
        dataPoints: [
            { label: "数学", value: 0, color: "#d4a574" },
            { label: "英语", value: 0, color: "#8b7355" }
        ]
    }

    StatCard {
        id: warmShadowCard
        objectName: "warmShadowStatCard"
        visible: false
        title: "阴影"
        value: "1"
    }

    function init() {
        todaySnapshot = dateOnly(new Date())
        statisticsView.z = 10
        statisticsView.visible = false
        statisticsView.currentDateProvider = function() {
            return todaySnapshot
        }
        statisticsView.currentDateSnapshot = todaySnapshot
        statisticsView.selectedDate = todaySnapshot
        statisticsView.selectedWeekStart = mondayOf(todaySnapshot)
        statisticsView.selectedYear = todaySnapshot.getFullYear()
        statisticsView.selectedMonth = todaySnapshot.getMonth() + 1
        if (statisticsView.currentTimeRange === "today") {
            statisticsView.currentTimeRange = "week"
            wait(1)
        }
        statisticsView.currentTimeRange = "today"
        wait(20)
        statisticsService.resetTracking()
    }

    function dateOnly(value) {
        var date = new Date(value)
        date.setHours(0, 0, 0, 0)
        return date
    }

    function addDays(value, days) {
        var date = dateOnly(value)
        date.setDate(date.getDate() + days)
        return date
    }

    function mondayOf(value) {
        var date = dateOnly(value)
        var day = date.getDay()
        var diff = day === 0 ? -6 : 1 - day
        date.setDate(date.getDate() + diff)
        return date
    }

    function isoDate(value) {
        return Qt.formatDate(dateOnly(value), "yyyy-MM-dd")
    }

    function isoDateOrEmpty(value) {
        if (value === undefined || value === null) {
            return ""
        }
        var date = new Date(value)
        if (isNaN(date.getTime())) {
            return ""
        }
        return isoDate(date)
    }

    function dayDisplay(value) {
        var date = dateOnly(value)
        return (date.getMonth() + 1) + "月" + date.getDate() + "日"
    }

    function weekRangeDisplay(start) {
        var end = addDays(start, 6)
        return (start.getMonth() + 1) + "." + start.getDate() + "-" + (end.getMonth() + 1) + "." + end.getDate()
    }

    function previousMonthInfo() {
        var now = dateOnly(todaySnapshot)
        var year = now.getFullYear()
        var month = now.getMonth()
        if (month < 1) {
            month = 12
            year -= 1
        }
        return { year: year, month: month }
    }

    function selectTimeRange(itemName) {
        statisticsView.visible = true
        var menu = findChild(statisticsView, "statisticsTimeRangeMenu")
        var item = findChild(statisticsView, itemName)

        verify(menu !== null)
        verify(item !== null)
        menu.open()
        tryCompare(menu, "opened", true, 1000)
        mouseClick(item, item.width / 2, item.height / 2)
        wait(80)
    }

    function test_emptyChartsRenderStableFallbacks() {
        wait(50)

        // 空数据时应该显示兜底文案，不能露出 NaN 这类计算错误文本。
        var barEmptyLabel = findChild(emptyBarChart, "emptyStateLabel")
        var pieEmptyLabel = findChild(emptyPieChart, "emptyStateLabel")

        verify(barEmptyLabel !== null)
        verify(pieEmptyLabel !== null)
        verify(emptyBarChart.showEmptyState)
        verify(emptyPieChart.showEmptyState)
        verify(barEmptyLabel.text.indexOf("NaN") === -1)
        verify(pieEmptyLabel.text.indexOf("NaN") === -1)
    }

    function test_zeroChartsAvoidInvalidGeometry() {
        wait(50)

        // 全是 0 的数据也要能画图；这里验证比例计算不会产生无效数字。
        verify(zeroBarChart.maxValue === 0)
        verify(zeroPieChart.totalValue === 0)
        verify(isFinite(zeroBarChart.normalizedValue(0)))
        verify(isFinite(zeroPieChart.segmentSweep(0)))
        compare(zeroBarChart.normalizedValue(0), 0)
        compare(zeroPieChart.segmentSweep(0), 0)
    }

    function test_zeroPieChartShowsStableZeroState() {
        wait(50)

        var invalidLabel = findChild(zeroPieChart, "invalidDataLabel")
        verify(invalidLabel !== null)
        verify(zeroPieChart.showInvalidData)
        verify(invalidLabel.text.indexOf("NaN") === -1)
    }

    function test_statCardUsesWarmRestrainedShadow() {
        var effect = warmShadowCard.layer.effect

        verify(effect !== null)
        compare(warmShadowCard.layer.enabled, true)
        verify(warmShadowCard.cardShadowColor !== undefined)
        verify(warmShadowCard.cardShadowBlur !== undefined)
        verify(Qt.colorEqual(warmShadowCard.cardShadowColor, Theme.ink))
        verify(Math.abs(warmShadowCard.cardShadowBlur - 0.18) < 0.001)
        compare(warmShadowCard.cardShadowOpacity, 0.08)
        compare(warmShadowCard.cardShadowHorizontalOffset, 0)
        compare(warmShadowCard.cardShadowVerticalOffset, 2)
    }

    function test_statisticsDurationFormatsSubMinuteSessions() {
        compare(statisticsView.formatDuration(0), "0分钟")
        compare(statisticsView.formatDuration(2), "2秒")
        compare(statisticsView.formatDuration(61), "1分钟")
        compare(statisticsView.totalDurationValue(2), "2秒")
        compare(statisticsView.totalDurationUnit(2), "")
        compare(statisticsView.totalDurationValue(3660), "1.0")
        compare(statisticsView.totalDurationUnit(3660), "小时")
    }

    function test_statisticsTimeRangeDefaultsToToday() {
        wait(50)

        var firstCard = findChild(statisticsView, "statisticsPrimaryStatCard")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        var trendChart = findChild(statisticsView, "statisticsTrendChart")
        var pieChart = findChild(statisticsView, "statisticsCategoryChart")
        var selector = findChild(statisticsView, "statisticsTimeRangeSelector")
        var previousArea = findChild(statisticsView, "statisticsPreviousPeriodArea")
        var selectorText = findChild(statisticsView, "statisticsTimeRangeSelectorText")
        var nextArea = findChild(statisticsView, "statisticsNextPeriodArea")

        compare(statisticsView.currentTimeRange, "today")
        verify(firstCard !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)
        verify(trendChart !== null)
        verify(pieChart !== null)
        verify(selector !== null)
        verify(previousArea !== null)
        verify(selectorText !== null)
        verify(nextArea !== null)
        compare(previousArea.enabled, true)
        compare(nextArea.enabled, false)
        compare(selectorText.text, "今天")
        compare(firstCard.title, "任务完成")
        compare(firstCard.value, "1 / 2")
        compare(secondCard.title, "专注次数")
        compare(thirdCard.title, "今日专注")
        compare(trendChart.title, "本周专注趋势")
        compare(pieChart.emptyText, "今日还没有可归类的专注记录")
    }

    function test_statisticsDayArrowNavigationUsesSelectedDate() {
        statisticsView.visible = true
        wait(50)

        var previousButton = findChild(statisticsView, "statisticsPreviousPeriodButton")
        var previousArea = findChild(statisticsView, "statisticsPreviousPeriodArea")
        var selectorText = findChild(statisticsView, "statisticsTimeRangeSelectorText")
        var nextButton = findChild(statisticsView, "statisticsNextPeriodButton")
        var nextArea = findChild(statisticsView, "statisticsNextPeriodArea")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        var trendChart = findChild(statisticsView, "statisticsTrendChart")
        var pieChart = findChild(statisticsView, "statisticsCategoryChart")

        verify(previousButton !== null)
        verify(previousArea !== null)
        verify(selectorText !== null)
        verify(nextButton !== null)
        verify(nextArea !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)
        verify(trendChart !== null)
        verify(pieChart !== null)
        verify(previousButton.width > 0)
        verify(previousButton.height > 0)
        verify(previousArea.width > 0)
        verify(previousArea.height > 0)
        verify(nextButton.width > 0)
        verify(nextButton.height > 0)

        var yesterday = addDays(todaySnapshot, -1)
        statisticsService.resetTracking()
        statisticsView.goToPreviousPeriod()
        tryCompare(selectorText, "text", dayDisplay(yesterday), 1000)

        compare(statisticsView.currentTimeRange, "today")
        compare(nextArea.enabled, true)
        compare(secondCard.subtitle, "当日完成次数")
        compare(thirdCard.title, "当日专注")
        compare(thirdCard.subtitle, "所选自然日")
        compare(thirdCard.comparisonText, "↗ +50% vs 前天")
        compare(trendChart.title, "所在周专注趋势")
        compare(pieChart.emptyText, "当日还没有可归类的专注记录")
        compare(statisticsService.dayStatsCalls, 1)
        compare(statisticsService.lastDayStatsDate, isoDate(yesterday))
        compare(statisticsService.lastCategoryStartDate, isoDate(yesterday))
        compare(statisticsService.lastCategoryEndDate, isoDate(yesterday))

        statisticsService.resetTracking()
        statisticsView.goToNextPeriod()
        tryCompare(selectorText, "text", "今天", 1000)

        compare(nextArea.enabled, false)
        compare(secondCard.subtitle, "今日完成次数")
        compare(thirdCard.title, "今日专注")
        compare(thirdCard.subtitle, "当前自然日")
        compare(trendChart.title, "本周专注趋势")
        compare(pieChart.emptyText, "今日还没有可归类的专注记录")
        compare(statisticsService.dayStatsCalls, 1)
        compare(statisticsService.lastDayStatsDate, isoDate(todaySnapshot))
        compare(statisticsService.lastCategoryStartDate, isoDate(todaySnapshot))
        compare(statisticsService.lastCategoryEndDate, isoDate(todaySnapshot))
    }

    function test_statisticsComparisonDefaultsToTodayAndFollowsNavigation() {
        statisticsView.visible = true
        wait(50)

        var firstCard = findChild(statisticsView, "statisticsPrimaryStatCard")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        verify(firstCard !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)

        statisticsService.resetTracking()
        statisticsView.refresh()

        tryCompare(statisticsService, "dayComparisonCalls", 1, 1000)
        compare(statisticsService.dayComparisonCalls, 1)
        compare(statisticsService.lastDayComparisonDate, isoDate(todaySnapshot))
        compare(firstCard.showComparison, true)
        compare(firstCard.comparisonText, "↘ -25% vs 昨天")
        compare(firstCard.comparisonTrend, -1)
        compare(secondCard.comparisonText, "→ 0% vs 昨天")
        compare(secondCard.comparisonTrend, 0)
        compare(thirdCard.comparisonText, "↗ +50% vs 昨天")
        compare(thirdCard.comparisonTrend, 1)

        var comparisonText = findChild(thirdCard, "statCardComparisonText")
        verify(comparisonText !== null)
        compare(thirdCard.implicitHeight, 126)
        verify(Qt.colorEqual(comparisonText.color, "#4caf50"))

        var yesterday = addDays(todaySnapshot, -1)
        statisticsService.resetTracking()
        statisticsView.goToPreviousPeriod()
        compare(statisticsService.dayComparisonCalls, 1)
        compare(statisticsService.lastDayComparisonDate, isoDate(yesterday))
        compare(thirdCard.comparisonText, "↗ +50% vs 前天")

        var twoDaysAgo = addDays(todaySnapshot, -2)
        statisticsService.resetTracking()
        statisticsView.goToPreviousPeriod()
        compare(statisticsService.dayComparisonCalls, 1)
        compare(statisticsService.lastDayComparisonDate, isoDate(twoDaysAgo))
        compare(thirdCard.comparisonText, "↗ +50% vs 3天前")
    }

    function test_statisticsWeekArrowNavigationUsesSelectedWeek() {
        selectTimeRange("statisticsTimeRangeWeekItem")

        var previousButton = findChild(statisticsView, "statisticsPreviousPeriodButton")
        var previousArea = findChild(statisticsView, "statisticsPreviousPeriodArea")
        var selectorText = findChild(statisticsView, "statisticsTimeRangeSelectorText")
        var nextArea = findChild(statisticsView, "statisticsNextPeriodArea")
        var firstCard = findChild(statisticsView, "statisticsPrimaryStatCard")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        var trendChart = findChild(statisticsView, "statisticsTrendChart")
        var pieChart = findChild(statisticsView, "statisticsCategoryChart")

        verify(previousButton !== null)
        verify(previousArea !== null)
        verify(selectorText !== null)
        verify(nextArea !== null)
        verify(firstCard !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)
        verify(trendChart !== null)
        verify(pieChart !== null)
        compare(statisticsView.currentTimeRange, "week")
        compare(selectorText.text, "本周")
        compare(nextArea.enabled, false)

        var lastWeekStart = addDays(mondayOf(todaySnapshot), -7)
        var lastWeekEnd = addDays(lastWeekStart, 6)
        statisticsService.resetTracking()
        statisticsView.goToPreviousPeriod()
        tryCompare(selectorText, "text", weekRangeDisplay(lastWeekStart), 1000)

        compare(nextArea.enabled, true)
        compare(firstCard.subtitle, "所选周有记录天数")
        compare(secondCard.subtitle, "所选周完成次数")
        compare(thirdCard.title, "所选周累计")
        compare(thirdCard.subtitle, "所选周专注时长")
        compare(thirdCard.comparisonText, "↘ -25% vs 上上周")
        compare(trendChart.title, "所选周专注趋势")
        compare(pieChart.emptyText, "所选周还没有可归类的专注记录")
        compare(statisticsService.weekStatsCalls, 1)
        compare(statisticsService.lastWeekStatsStartDate, isoDate(lastWeekStart))
        compare(statisticsService.effectiveDaysCalls, 1)
        compare(statisticsService.lastEffectiveDaysStartDate, isoDate(lastWeekStart))
        compare(statisticsService.lastEffectiveDaysEndDate, isoDate(lastWeekEnd))
        compare(statisticsService.focusSessionCountCalls, 1)
        compare(statisticsService.lastFocusSessionCountStartDate, isoDate(lastWeekStart))
        compare(statisticsService.lastFocusSessionCountEndDate, isoDate(lastWeekEnd))
        compare(statisticsService.lastCategoryStartDate, isoDate(lastWeekStart))
        compare(statisticsService.lastCategoryEndDate, isoDate(lastWeekEnd))

        var twoWeeksAgoStart = addDays(mondayOf(todaySnapshot), -14)
        statisticsService.resetTracking()
        statisticsView.goToPreviousPeriod()
        compare(statisticsService.weekComparisonCalls, 1)
        compare(statisticsService.lastWeekComparisonStartDate, isoDate(twoWeeksAgoStart))
        compare(thirdCard.comparisonText, "↘ -25% vs 3周前")

        statisticsService.resetTracking()
        statisticsView.goToNextPeriod()
        statisticsView.goToNextPeriod()
        tryCompare(selectorText, "text", "本周", 1000)

        compare(nextArea.enabled, false)
        compare(firstCard.subtitle, "本周有记录天数")
        compare(secondCard.subtitle, "本周完成次数")
        compare(thirdCard.title, "本周累计")
        compare(thirdCard.subtitle, "本周专注时长")
        compare(trendChart.title, "本周专注趋势")
        compare(pieChart.emptyText, "本周还没有可归类的专注记录")
        compare(statisticsService.weekStatsCalls, 2)
        compare(statisticsService.lastWeekStatsStartDate, isoDate(mondayOf(todaySnapshot)))
    }

    function test_statisticsComparisonSwitchesWeekAndMonthData() {
        statisticsService.resetTracking()
        selectTimeRange("statisticsTimeRangeWeekItem")

        var firstCard = findChild(statisticsView, "statisticsPrimaryStatCard")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        verify(firstCard !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)

        tryCompare(statisticsService, "weekComparisonCalls", 1, 1000)
        compare(statisticsService.weekComparisonCalls, 1)
        compare(statisticsService.lastWeekComparisonStartDate, isoDate(mondayOf(todaySnapshot)))
        compare(firstCard.comparisonText, "↗ +20% vs 上周")
        compare(firstCard.comparisonTrend, 1)
        compare(secondCard.comparisonText, "→ 0% vs 上周")
        compare(secondCard.comparisonTrend, 0)
        compare(thirdCard.comparisonText, "↘ -25% vs 上周")
        compare(thirdCard.comparisonTrend, -1)

        var weekComparisonText = findChild(thirdCard, "statCardComparisonText")
        verify(weekComparisonText !== null)
        verify(Qt.colorEqual(weekComparisonText.color, Theme.danger))

        statisticsService.resetTracking()
        selectTimeRange("statisticsTimeRangeMonthItem")

        tryCompare(statisticsService, "monthComparisonCalls", 1, 1000)
        compare(statisticsService.monthComparisonCalls, 1)
        compare(statisticsService.lastMonthComparisonYear, todaySnapshot.getFullYear())
        compare(statisticsService.lastMonthComparisonMonth, todaySnapshot.getMonth() + 1)
        compare(firstCard.comparisonText, "↗ +40% vs 上月")
        compare(firstCard.comparisonTrend, 1)
        compare(secondCard.comparisonText, "↘ -10% vs 上月")
        compare(secondCard.comparisonTrend, -1)
        compare(thirdCard.comparisonText, "→ 0% vs 上月")
        compare(thirdCard.comparisonTrend, 0)

        var monthComparisonText = findChild(thirdCard, "statCardComparisonText")
        verify(monthComparisonText !== null)
        verify(Qt.colorEqual(monthComparisonText.color, Theme.inkSoft))
    }

    function test_statisticsMonthArrowNavigationUsesSelectedMonth() {
        selectTimeRange("statisticsTimeRangeMonthItem")

        var previousButton = findChild(statisticsView, "statisticsPreviousPeriodButton")
        var previousArea = findChild(statisticsView, "statisticsPreviousPeriodArea")
        var selectorText = findChild(statisticsView, "statisticsTimeRangeSelectorText")
        var nextArea = findChild(statisticsView, "statisticsNextPeriodArea")
        var firstCard = findChild(statisticsView, "statisticsPrimaryStatCard")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        var trendChart = findChild(statisticsView, "statisticsTrendChart")
        var pieChart = findChild(statisticsView, "statisticsCategoryChart")

        verify(previousButton !== null)
        verify(previousArea !== null)
        verify(selectorText !== null)
        verify(nextArea !== null)
        verify(firstCard !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)
        verify(trendChart !== null)
        verify(pieChart !== null)
        compare(statisticsView.currentTimeRange, "month")
        compare(selectorText.text, "本月")
        compare(nextArea.enabled, false)

        var expected = previousMonthInfo()
        var firstDay = new Date(expected.year, expected.month - 1, 1)
        var lastDay = new Date(expected.year, expected.month, 0)
        statisticsService.resetTracking()
        statisticsView.goToPreviousPeriod()
        tryCompare(selectorText, "text", expected.year + "年" + expected.month + "月", 1000)

        compare(nextArea.enabled, true)
        compare(firstCard.subtitle, "所选月有记录天数")
        compare(secondCard.subtitle, "所选月完成次数")
        compare(thirdCard.title, "所选月累计")
        compare(thirdCard.subtitle, "所选月专注时长")
        compare(thirdCard.comparisonText, "→ 0% vs 上上月")
        compare(trendChart.title, "所选月专注趋势")
        compare(pieChart.emptyText, "所选月还没有可归类的专注记录")
        compare(statisticsService.monthStatsCalls, 1)
        compare(statisticsService.lastMonthStatsYear, expected.year)
        compare(statisticsService.lastMonthStatsMonth, expected.month)
        compare(statisticsService.monthWeeklySummaryCalls, 1)
        compare(statisticsService.lastMonthWeeklySummaryYear, expected.year)
        compare(statisticsService.lastMonthWeeklySummaryMonth, expected.month)
        compare(statisticsService.lastCategoryStartDate, isoDate(firstDay))
        compare(statisticsService.lastCategoryEndDate, isoDate(lastDay))

        statisticsService.resetTracking()
        statisticsView.goToPreviousPeriod()
        compare(statisticsService.monthComparisonCalls, 1)
        compare(thirdCard.comparisonText, "→ 0% vs 3个月前")

        statisticsService.resetTracking()
        statisticsView.goToNextPeriod()
        statisticsView.goToNextPeriod()
        tryCompare(selectorText, "text", "本月", 1000)

        compare(nextArea.enabled, false)
        compare(firstCard.subtitle, "本月有记录天数")
        compare(secondCard.subtitle, "本月完成次数")
        compare(thirdCard.title, "本月累计")
        compare(thirdCard.subtitle, "本月专注时长")
        compare(trendChart.title, "本月专注趋势")
        compare(pieChart.emptyText, "本月还没有可归类的专注记录")
        compare(statisticsService.monthStatsCalls, 2)
        compare(statisticsService.lastMonthStatsYear, todaySnapshot.getFullYear())
        compare(statisticsService.lastMonthStatsMonth, todaySnapshot.getMonth() + 1)
        compare(statisticsService.monthWeeklySummaryCalls, 2)
        compare(statisticsService.lastMonthWeeklySummaryYear, todaySnapshot.getFullYear())
        compare(statisticsService.lastMonthWeeklySummaryMonth, todaySnapshot.getMonth() + 1)
    }

    function test_statisticsMenuItemResetsCurrentRangeToCurrentPeriod() {
        statisticsView.visible = true
        wait(50)

        var selectorText = findChild(statisticsView, "statisticsTimeRangeSelectorText")
        var todayItem = findChild(statisticsView, "statisticsTimeRangeTodayItem")
        var weekItem = findChild(statisticsView, "statisticsTimeRangeWeekItem")
        var monthItem = findChild(statisticsView, "statisticsTimeRangeMonthItem")

        verify(selectorText !== null)
        verify(todayItem !== null)
        verify(weekItem !== null)
        verify(monthItem !== null)

        statisticsView.goToPreviousPeriod()
        compare(selectorText.text, dayDisplay(addDays(todaySnapshot, -1)))
        statisticsService.resetTracking()
        todayItem.triggered()
        tryCompare(selectorText, "text", "今天", 1000)
        compare(statisticsService.lastDayStatsDate, isoDate(todaySnapshot))

        selectTimeRange("statisticsTimeRangeWeekItem")
        statisticsView.goToPreviousPeriod()
        compare(selectorText.text, weekRangeDisplay(addDays(mondayOf(todaySnapshot), -7)))
        statisticsService.resetTracking()
        weekItem.triggered()
        tryCompare(selectorText, "text", "本周", 1000)
        compare(statisticsService.lastWeekStatsStartDate, isoDate(mondayOf(todaySnapshot)))

        selectTimeRange("statisticsTimeRangeMonthItem")
        statisticsView.goToPreviousPeriod()
        verify(selectorText.text !== "本月")
        statisticsService.resetTracking()
        monthItem.triggered()
        tryCompare(selectorText, "text", "本月", 1000)
        compare(statisticsService.lastMonthStatsYear, todaySnapshot.getFullYear())
        compare(statisticsService.lastMonthStatsMonth, todaySnapshot.getMonth() + 1)
    }

    function test_statisticsRefreshTracksCurrentPeriodAfterDateSnapshotChanges() {
        statisticsView.visible = true
        wait(50)

        var selectorText = findChild(statisticsView, "statisticsTimeRangeSelectorText")
        verify(selectorText !== null)

        var simulatedToday = new Date(2026, 5, 12)
        var simulatedTomorrow = addDays(simulatedToday, 1)
        var providedDate = simulatedToday
        statisticsView.currentDateProvider = function() {
            return providedDate
        }
        statisticsView.currentDateSnapshot = simulatedToday
        statisticsView.selectedDate = simulatedToday
        statisticsService.resetTracking()
        providedDate = simulatedTomorrow
        statisticsView.refresh()
        tryCompare(selectorText, "text", "今天", 1000)
        compare(statisticsService.lastDayStatsDate, isoDate(simulatedTomorrow))

        statisticsView.goToPreviousPeriod()
        var historicalDate = addDays(simulatedTomorrow, -1)
        statisticsService.resetTracking()
        providedDate = addDays(simulatedTomorrow, 1)
        statisticsView.refresh()
        compare(selectorText.text, dayDisplay(historicalDate))
        compare(statisticsService.lastDayStatsDate, isoDate(historicalDate))

        selectTimeRange("statisticsTimeRangeWeekItem")
        providedDate = simulatedToday
        statisticsView.currentDateSnapshot = simulatedToday
        statisticsView.selectedWeekStart = mondayOf(simulatedToday)
        statisticsService.resetTracking()
        providedDate = addDays(simulatedToday, 7)
        statisticsView.refresh()
        tryCompare(selectorText, "text", "本周", 1000)
        compare(statisticsService.lastWeekStatsStartDate, isoDate(mondayOf(addDays(simulatedToday, 7))))

        statisticsView.goToPreviousPeriod()
        var historicalWeekStart = addDays(mondayOf(addDays(simulatedToday, 7)), -7)
        statisticsService.resetTracking()
        providedDate = addDays(simulatedToday, 14)
        statisticsView.refresh()
        compare(selectorText.text, weekRangeDisplay(historicalWeekStart))
        compare(statisticsService.lastWeekStatsStartDate, isoDate(historicalWeekStart))

        selectTimeRange("statisticsTimeRangeMonthItem")
        providedDate = new Date(2026, 5, 12)
        statisticsView.currentDateSnapshot = providedDate
        statisticsView.selectedYear = 2026
        statisticsView.selectedMonth = 6
        statisticsService.resetTracking()
        providedDate = new Date(2026, 6, 1)
        statisticsView.refresh()
        tryCompare(selectorText, "text", "本月", 1000)
        compare(statisticsService.lastMonthStatsYear, 2026)
        compare(statisticsService.lastMonthStatsMonth, 7)

        statisticsView.goToPreviousPeriod()
        statisticsService.resetTracking()
        providedDate = new Date(2026, 7, 1)
        statisticsView.refresh()
        compare(selectorText.text, "2026年6月")
        compare(statisticsService.lastMonthStatsYear, 2026)
        compare(statisticsService.lastMonthStatsMonth, 6)
    }

    function test_statisticsTimeRangeSwitchesWeekAndMonthData() {
        wait(50)

        var firstCard = findChild(statisticsView, "statisticsPrimaryStatCard")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        var trendChart = findChild(statisticsView, "statisticsTrendChart")
        var pieChart = findChild(statisticsView, "statisticsCategoryChart")
        var selector = findChild(statisticsView, "statisticsTimeRangeSelector")
        var selectorArea = findChild(statisticsView, "statisticsTimeRangeSelectorArea")
        var menu = findChild(statisticsView, "statisticsTimeRangeMenu")
        var weekItem = findChild(statisticsView, "statisticsTimeRangeWeekItem")
        var monthItem = findChild(statisticsView, "statisticsTimeRangeMonthItem")

        verify(selector !== null)
        verify(selectorArea !== null)
        verify(menu !== null)
        verify(weekItem !== null)
        verify(monthItem !== null)

        statisticsService.resetTracking()
        statisticsView.visible = true
        wait(50)
        menu.open()
        tryCompare(menu, "opened", true, 1000)
        mouseClick(weekItem, weekItem.width / 2, weekItem.height / 2)
        wait(80)

        compare(statisticsView.currentTimeRange, "week")
        compare(firstCard.title, "有效天数")
        compare(firstCard.value, "3天")
        compare(secondCard.value, "4次")
        compare(thirdCard.title, "本周累计")
        compare(thirdCard.value, "1.5")
        compare(thirdCard.unit, "小时")
        compare(trendChart.title, "本周专注趋势")
        compare(trendChart.dataPoints.length, 7)
        compare(pieChart.emptyText, "本周还没有可归类的专注记录")
        compare(statisticsService.effectiveDaysCalls, 1)
        compare(statisticsService.focusSessionCountCalls, 1)

        statisticsService.resetTracking()
        menu.open()
        tryCompare(menu, "opened", true, 1000)
        mouseClick(monthItem, monthItem.width / 2, monthItem.height / 2)
        wait(80)

        compare(statisticsView.currentTimeRange, "month")
        compare(firstCard.title, "有效天数")
        compare(firstCard.value, "5天")
        compare(secondCard.value, "8次")
        compare(thirdCard.title, "本月累计")
        compare(thirdCard.value, "2.0")
        compare(thirdCard.unit, "小时")
        compare(trendChart.title, "本月专注趋势")
        compare(trendChart.dataPoints.length, 2)
        compare(trendChart.dataPoints[0].label, "第1周")
        compare(pieChart.emptyText, "本月还没有可归类的专注记录")
        compare(statisticsService.monthStatsCalls, 1)
        compare(statisticsService.monthWeeklySummaryCalls, 1)
    }

    function test_statisticsLayoutKeepsAlignedBoundaries() {
        statisticsView.visible = true
        statisticsView.width = 900
        statisticsView.height = 640
        wait(80)

        var firstCard = findChild(statisticsView, "statisticsPrimaryStatCard")
        var secondCard = findChild(statisticsView, "statisticsSessionCountStatCard")
        var thirdCard = findChild(statisticsView, "statisticsTotalDurationStatCard")
        var trendChart = findChild(statisticsView, "statisticsTrendChart")
        var pieChart = findChild(statisticsView, "statisticsCategoryChart")

        verify(firstCard !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)
        verify(trendChart !== null)
        verify(pieChart !== null)

        var firstPos = firstCard.mapToItem(statisticsView, 0, 0)
        var secondPos = secondCard.mapToItem(statisticsView, 0, 0)
        var thirdPos = thirdCard.mapToItem(statisticsView, 0, 0)
        var trendPos = trendChart.mapToItem(statisticsView, 0, 0)
        var piePos = pieChart.mapToItem(statisticsView, 0, 0)

        // 统计页所有大模块共享同一个内容边界，避免卡片区和图表区视觉上各走各的。
        compare(Math.round(firstPos.x), Math.round(trendPos.x))
        compare(Math.round(trendPos.x), Math.round(piePos.x))
        compare(Math.round(thirdPos.x + thirdCard.width), Math.round(trendPos.x + trendChart.width))
        compare(Math.round(trendPos.x + trendChart.width), Math.round(piePos.x + pieChart.width))
        verify(secondPos.x > firstPos.x + firstCard.width)
        verify(thirdPos.x > secondPos.x + secondCard.width)

        statisticsView.width = 520
        wait(80)

        firstPos = firstCard.mapToItem(statisticsView, 0, 0)
        secondPos = secondCard.mapToItem(statisticsView, 0, 0)
        thirdPos = thirdCard.mapToItem(statisticsView, 0, 0)
        trendPos = trendChart.mapToItem(statisticsView, 0, 0)

        // 窄宽下卡片纵向堆叠，不制造横向滚动和右侧越界。
        verify(firstPos.x >= 24)
        verify(firstPos.x + firstCard.width <= statisticsView.width - 24)
        verify(secondPos.x >= 24)
        verify(secondPos.x + secondCard.width <= statisticsView.width - 24)
        verify(thirdPos.x >= 24)
        verify(thirdPos.x + thirdCard.width <= statisticsView.width - 24)
        compare(Math.round(firstPos.x), Math.round(trendPos.x))
        compare(Math.round(firstCard.width), Math.round(trendChart.width))
        verify(secondPos.y > firstPos.y + firstCard.height)
        verify(thirdPos.y > secondPos.y + secondCard.height)
    }

    function test_todayDurationFormatsSubMinuteSessions() {
        compare(todayTaskView.formatDuration(0), "0分钟")
        compare(todayTaskView.formatDuration(2), "2秒")
        compare(todayTaskView.formatDuration(61), "1分钟")
    }
}
