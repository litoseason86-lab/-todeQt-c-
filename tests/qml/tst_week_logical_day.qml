import QtQuick
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "WeekLogicalDay"
    when: windowShown
    width: 1000
    height: 700
    // QtTest.TestCase 默认隐藏；该用例要走真实 mouseClick，必须挂入 offscreen 可见场景。
    visible: true

    property var fakeNow: new Date(2026, 6, 13, 3, 59)

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: taskManager

        signal tasksChanged()

        function getWeekTasks(weekStartIso) {
            return []
        }
    }

    WeekPlanView {
        id: view

        width: 1000
        height: 700
        logicalNowProvider: function() {
            return testCase.fakeNow
        }
    }

    function isoDate(value) {
        return Qt.formatDate(value, "yyyy-MM-dd")
    }

    function init() {
        // provider 函数保持不变，只改它读取的时间，避免绑定提前重算破坏 prev 语义。
        fakeNow = new Date(2026, 6, 13, 3, 59)
        view.logicalToday = view.computeLogicalToday()
        view.weekStart = view.mondayOf(view.logicalToday)
    }

    function test_initialStateUsesLogicalSundayBeforeBoundary() {
        compare(isoDate(view.logicalToday), "2026-07-12")
        compare(isoDate(view.weekStart), "2026-07-06")
        verify(view.isTodayIndex(6))
        verify(view.isPastIndex(5))
        verify(!view.isPastIndex(6))
    }

    function test_boundaryChangeFollowsCurrentWeek() {
        fakeNow = new Date(2026, 6, 13, 4, 0)

        logicalDayService.changed()

        compare(isoDate(view.logicalToday), "2026-07-13")
        compare(isoDate(view.weekStart), "2026-07-13")
        verify(view.isTodayIndex(0))
    }

    function test_boundaryChangeKeepsHistoricalWeek() {
        view.weekStart = new Date(2026, 5, 29)
        fakeNow = new Date(2026, 6, 13, 4, 0)

        logicalDayService.changed()

        compare(isoDate(view.logicalToday), "2026-07-13")
        compare(isoDate(view.weekStart), "2026-06-29")
    }

    function test_thisWeekButtonReturnsToLogicalWeek() {
        view.weekStart = new Date(2026, 5, 29)
        var button = findChild(view, "weekThisWeekButton")

        verify(button !== null)
        mouseClick(button)

        compare(isoDate(view.weekStart), "2026-07-06")
    }
}
