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

        function getTodayStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 }
        }

        function getWeekStats() {
            return []
        }

        function getCategoryStats(startDate, endDate) {
            return { categories: [], totalDuration: 0 }
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

    function test_todayDurationFormatsSubMinuteSessions() {
        compare(todayTaskView.formatDuration(0), "0分钟")
        compare(todayTaskView.formatDuration(2), "2秒")
        compare(todayTaskView.formatDuration(61), "1分钟")
    }
}
