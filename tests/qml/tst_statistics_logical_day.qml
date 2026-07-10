import QtQuick
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
        currentDateProvider: function() {
            return new Date(2026, 6, 8, 1, 0)
        }
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

    function test_changedTriggersRefreshAndKeepsHistoricalSelection() {
        view.selectedDate = new Date(2026, 5, 1)
        var callsBefore = testCase.dayStatsCalls

        logicalDayService.changed()

        verify(testCase.dayStatsCalls > callsBefore)
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-06-01")
    }

    function test_changedFollowsCurrentPeriod() {
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
        logicalDayService.changed()
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
    }
}
