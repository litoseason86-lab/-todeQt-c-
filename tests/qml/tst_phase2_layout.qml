import QtQuick
import QtTest
import "../../qml/components"
import "../../qml/views"

TestCase {
    id: testCase
    name: "Phase2Layout"
    when: windowShown
    width: 900
    height: 640

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
        property int monthStatsCalls: 0
        property int monthWeeklySummaryCalls: 0
        property string lastCategoryStartDate: ""
        property string lastCategoryEndDate: ""

        function resetTracking() {
            effectiveDaysCalls = 0
            focusSessionCountCalls = 0
            monthStatsCalls = 0
            monthWeeklySummaryCalls = 0
            lastCategoryStartDate = ""
            lastCategoryEndDate = ""
        }

        function getTodayStats() {
            return { totalDuration: 600, completedTasks: 1, totalTasks: 2, completionRate: 0.5 }
        }

        function getWeekStats() {
            return [
                { date: "2026-06-08", duration: 1800 },
                { date: "2026-06-09", duration: 0 },
                { date: "2026-06-10", duration: 3600 },
                { date: "2026-06-11", duration: 0 },
                { date: "2026-06-12", duration: 0 },
                { date: "2026-06-13", duration: 0 },
                { date: "2026-06-14", duration: 0 }
            ]
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
            return 3
        }

        function getFocusSessionCount(startDate, endDate) {
            focusSessionCountCalls += 1
            return 4
        }

        function getMonthStats() {
            monthStatsCalls += 1
            return {
                totalDuration: 7200,
                effectiveDays: 5,
                sessionCount: 8,
                completedTasks: 0,
                totalTasks: 0
            }
        }

        function getMonthWeeklySummary() {
            monthWeeklySummaryCalls += 1
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

        compare(statisticsView.currentTimeRange, "today")
        verify(firstCard !== null)
        verify(secondCard !== null)
        verify(thirdCard !== null)
        verify(trendChart !== null)
        verify(pieChart !== null)
        verify(selector !== null)
        compare(firstCard.title, "任务完成")
        compare(firstCard.value, "1 / 2")
        compare(secondCard.title, "专注次数")
        compare(thirdCard.title, "今日专注")
        compare(trendChart.title, "本周专注趋势")
        compare(pieChart.emptyText, "今日还没有可归类的专注记录")
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
