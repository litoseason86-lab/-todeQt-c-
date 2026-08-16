import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "StatisticsLogicalDay"
    when: windowShown
    width: 900
    height: 700

    property int dayStatsCalls: 0

    QtObject {
        id: appSettings

        property int dayStartHour: 4
        property bool reduceMotion: false
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    // StatisticsView 的两个未限定 Connections 需要显式 signal-only mock。
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

        function getDayStats(day) {
            testCase.dayStatsCalls++
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0,
                     completionRate: 0, sessionCount: 0 }
        }
        function getDayComparison(day) { return {} }
        function getWeekStats(start) { return [] }
        function getCategoryStats(startIso, endIso) {
            return { categories: [], totalDuration: 0 }
        }
    }

    StatisticsView {
        id: view

        width: 900
        height: 700
        taskManagerRef: taskManager
        statisticsServiceRef: statisticsService
        focusTimerRef: focusTimer
        logicalDayServiceRef: logicalDayService
        appSettingsRef: appSettings
        categoryManagerRef: categoryManager
        currentDateOverride: new Date(2026, 6, 8, 1, 0)
    }

    function init() {
        view.currentTimeRange = "today"
        view.refreshCurrentDateSnapshot()
        view.applyCurrentPeriodSelection()
        testCase.dayStatsCalls = 0
    }

    function test_snapshotIsLogicalToday() {
        compare(Qt.formatDate(view.currentDateSnapshot, "yyyy-MM-dd"), "2026-07-07")
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
    }

    function test_horizontal_scrollbar_remains_disabled() {
        const horizontalBar = findChild(view, "statisticsHorizontalScrollBar")
        verify(horizontalBar)
        compare(horizontalBar.policy, ScrollBar.AlwaysOff)
    }

    function test_changedTriggersRefreshAndKeepsHistoricalSelection() {
        view.selectedDate = new Date(2026, 5, 1)
        var callsBefore = testCase.dayStatsCalls

        logicalDayService.changed()

        tryVerify(function() { return testCase.dayStatsCalls > callsBefore }, 1000)
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-06-01")
    }

    function test_changedFollowsCurrentPeriod() {
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
        logicalDayService.changed()
        tryCompare(testCase, "dayStatsCalls", 1, 3000)
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
    }

    function test_synchronous_data_invalidations_share_one_refresh() {
        var callsBefore = testCase.dayStatsCalls

        taskManager.tasksChanged()
        focusTimer.focusCompleted(1500)
        categoryManager.categoriesChanged()
        logicalDayService.changed()

        // 同一事件循环内的多条失效链只做一次整页查询。
        tryCompare(testCase, "dayStatsCalls", callsBefore + 1, 3000)
    }

    function test_cross_event_loop_invalidations_are_not_swallowed() {
        var callsBefore = testCase.dayStatsCalls

        taskManager.tasksChanged()
        tryCompare(testCase, "dayStatsCalls", callsBefore + 1, 3000)

        focusTimer.focusCompleted(1500)
        tryCompare(testCase, "dayStatsCalls", callsBefore + 2, 3000)
    }

}
