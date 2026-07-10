import QtQuick
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "MonthLogicalDay"
    when: windowShown
    width: 1000
    height: 800

    property var fakeNow: new Date(2026, 6, 8, 3, 59)

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    MonthGoalView {
        id: view

        width: 1000
        height: 800
        logicalNowProvider: function() {
            return testCase.fakeNow
        }
    }

    function init() {
        // 固定 provider 函数，只改其读取值，确保 changed 槽能拿到真正的旧逻辑日。
        fakeNow = new Date(2026, 6, 8, 3, 59)
        view.logicalToday = view.computeLogicalToday()
        view.setMonth(view.logicalToday.getFullYear(), view.logicalToday.getMonth() + 1,
                      view.logicalToday.getDate())
        wait(20)
    }

    function test_initialSelectionAndHighlightUseLogicalToday() {
        compare(view.currentYear, 2026)
        compare(view.currentMonth, 7)
        compare(view.selectedDay, 7)

        var cell7 = findChild(view, "monthDayCell-7")
        var cell8 = findChild(view, "monthDayCell-8")
        verify(cell7 !== null)
        verify(cell8 !== null)
        verify(cell7.todayCell)
        verify(!cell8.todayCell)
    }

    function test_boundaryChangeFollowsOldLogicalToday() {
        fakeNow = new Date(2026, 6, 8, 4, 0)

        logicalDayService.changed()

        compare(view.selectedDay, 8)
        verify(findChild(view, "monthDayCell-8").todayCell)
        verify(!findChild(view, "monthDayCell-7").todayCell)
    }

    function test_boundaryChangeKeepsUserSelectedDay() {
        view.setMonth(2026, 7, 5)
        fakeNow = new Date(2026, 6, 8, 4, 0)

        logicalDayService.changed()

        compare(view.currentMonth, 7)
        compare(view.selectedDay, 5)
        verify(findChild(view, "monthDayCell-8").todayCell)
    }
}
