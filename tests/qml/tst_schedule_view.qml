import QtQuick
import QtTest
import "../../qml/views"

// 课表页的装配与周次导航。服务用假对象替身，验证的是视图如何消费数据、
// 如何在缺少学期锚点时降级，以及节次模式下漏排的条目会不会被说出来。
TestCase {
    id: testCase
    name: "ScheduleView"
    when: windowShown
    width: 1100
    height: 760
    visible: true

    property var fakeNow: new Date(2026, 8, 2, 10, 0)   // 2026-09-02 周三 10:00

    QtObject {
        id: appSettings

        property int dayStartHour: 4
        property string semesterStartDate: ""
        property int semesterWeeks: 16
        property string scheduleDisplayMode: "time"
        property bool scheduleShowWeekend: true
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged()

        function getAllCategories() {
            return []
        }
    }

    QtObject {
        id: scheduleService

        signal scheduleChanged()
        signal periodsChanged()
        signal operationFailed(string message)

        // 每项都带全字段，视图读到的形状与真实服务返回的一致。
        property var allEntries: [
            {
                id: 1, title: "高等数学", location: "A101", weekday: 1,
                startMinutes: 480, endMinutes: 580, durationMinutes: 100,
                weekStart: 1, weekEnd: 16, weekParity: 0,
                categoryId: undefined, categoryName: "", categoryColor: ""
            },
            {
                id: 2, title: "英语", location: "B203", weekday: 3,
                startMinutes: 600, endMinutes: 700, durationMinutes: 100,
                weekStart: 1, weekEnd: 8, weekParity: 0,
                categoryId: undefined, categoryName: "", categoryColor: ""
            },
            {
                id: 3, title: "午间例会", location: "", weekday: 3,
                startMinutes: 750, endMinutes: 780, durationMinutes: 30,
                weekStart: 1, weekEnd: 16, weekParity: 0,
                categoryId: undefined, categoryName: "", categoryColor: ""
            }
        ]

        property int lastRequestedWeek: -1
        property int deletedId: -1

        function getEntriesForWeek(weekIndex) {
            scheduleService.lastRequestedWeek = weekIndex
            if (weekIndex < 1) {
                return []
            }
            var result = []
            for (var i = 0; i < scheduleService.allEntries.length; ++i) {
                var entry = scheduleService.allEntries[i]
                if (entry.weekStart <= weekIndex && entry.weekEnd >= weekIndex) {
                    result.push(entry)
                }
            }
            return result
        }

        // 只覆盖上午两节；12:30 的例会故意落在节次之外。
        function getPeriods() {
            return [
                { index: 1, startMinutes: 480, endMinutes: 525 },
                { index: 2, startMinutes: 600, endMinutes: 645 }
            ]
        }

        function findConflicts() {
            return []
        }

        function deleteEntry(id) {
            scheduleService.deletedId = id
            return true
        }
    }

    SchedulePlanView {
        id: view

        scheduleServiceRef: scheduleService
        settingsRef: appSettings
        categoryManagerRef: categoryManager
        logicalDayServiceRef: logicalDayService
        width: 1100
        height: 760
        logicalNowProvider: function () {
            return testCase.fakeNow
        }
    }

    function init() {
        appSettings.semesterStartDate = ""
        appSettings.semesterWeeks = 16
        appSettings.scheduleDisplayMode = "time"
        appSettings.scheduleShowWeekend = true
        scheduleService.deletedId = -1
        view.logicalToday = view.computeLogicalToday()
        view.weekIndex = 1
        view.refresh()
    }

    function test_withoutAnchorSemesterIsNotConfigured() {
        // 没有学期起始日就算不出周次，页面必须停在引导态而不是画一张错误的网格。
        verify(!view.semesterConfigured)
        compare(view.currentWeekIndex, 0)
        compare(view.highlightWeekday, 0)
    }

    function test_anchorToThisWeekSetsMondayAndFirstWeek() {
        view.anchorSemesterToThisWeek()
        // 2026-09-02 是周三，锚点必须落在该周周一 2026-08-31。
        compare(appSettings.semesterStartDate, "2026-08-31")
        verify(view.semesterConfigured)
        compare(view.currentWeekIndex, 1)
        compare(view.weekIndex, 1)
    }

    function test_highlightWeekdayMatchesLogicalTodayOnCurrentWeek() {
        view.anchorSemesterToThisWeek()
        // 周三 = 3。
        compare(view.highlightWeekday, 3)
        verify(view.viewingCurrentWeek)

        // 翻到别的周就不该再高亮「今天」那一列，否则会误导。
        view.goToWeek(2)
        verify(!view.viewingCurrentWeek)
        compare(view.highlightWeekday, 0)
    }

    function test_weekNavigationClampsToSemesterBounds() {
        view.anchorSemesterToThisWeek()

        view.goToWeek(0)
        compare(view.weekIndex, 1)

        view.goToWeek(-5)
        compare(view.weekIndex, 1)

        view.goToWeek(999)
        compare(view.weekIndex, appSettings.semesterWeeks)

        // 总周数调小后，当前周次要被夹回有效范围。
        appSettings.semesterWeeks = 10
        view.goToWeek(view.weekIndex)
        compare(view.weekIndex, 10)
    }

    function test_weekIndexDrivesServiceQueryAndEntryCount() {
        view.anchorSemesterToThisWeek()
        compare(scheduleService.lastRequestedWeek, 1)
        compare(view.entries.length, 3)

        // 第 9 周之后「英语」已经结课，只剩两项。
        view.goToWeek(9)
        compare(scheduleService.lastRequestedWeek, 9)
        compare(view.entries.length, 2)
    }

    function test_periodModeReportsEntriesOutsideAnyPeriod() {
        view.anchorSemesterToThisWeek()
        appSettings.scheduleDisplayMode = "period"
        view.refresh()

        var grid = findChild(view, "scheduleGrid")
        verify(grid !== null)
        compare(grid.displayMode, "period")
        // 12:30 的例会不在任何一节里。它必须被显式统计出来——
        // 悄悄从网格消失会让用户以为数据丢了。
        compare(grid.unplacedEntries.length, 1)
        compare(grid.unplacedEntries[0].title, "午间例会")

        // 时间轴模式下所有条目都有位置，不存在漏排。
        appSettings.scheduleDisplayMode = "time"
        view.refresh()
        compare(grid.unplacedEntries.length, 0)
    }

    function test_timeAxisCoversAllEntriesOfTheWeek() {
        view.anchorSemesterToThisWeek()
        var grid = findChild(view, "scheduleGrid")
        verify(grid !== null)
        // 轴范围必须裹住当周最早开始与最晚结束，否则块会画到网格外面。
        verify(grid.axisStartMinutes <= 480)
        verify(grid.axisEndMinutes >= 780)
        // 轴按整点对齐，刻度线才落在 08:00 而不是 08:05。
        compare(grid.axisStartMinutes % 60, 0)
        compare(grid.axisEndMinutes % 60, 0)
    }

    function test_weekendColumnsFollowSetting() {
        view.anchorSemesterToThisWeek()
        var grid = findChild(view, "scheduleGrid")
        verify(grid !== null)
        compare(grid.visibleDayCount, 7)

        appSettings.scheduleShowWeekend = false
        compare(grid.visibleDayCount, 5)
    }

    function test_logicalDayChangeFollowsCurrentWeek() {
        view.anchorSemesterToThisWeek()
        compare(view.weekIndex, 1)

        // 跨到下一周：正在跟随当前周的用户应该被带到第 2 周。
        testCase.fakeNow = new Date(2026, 8, 9, 10, 0)
        logicalDayService.changed()
        compare(view.currentWeekIndex, 2)
        compare(view.weekIndex, 2)

        // 用户手动翻回第 1 周后，再次跨日不应该把他拽走。
        view.goToWeek(1)
        testCase.fakeNow = new Date(2026, 8, 16, 10, 0)
        logicalDayService.changed()
        compare(view.currentWeekIndex, 3)
        compare(view.weekIndex, 1)

        testCase.fakeNow = new Date(2026, 8, 2, 10, 0)
    }

    function test_serviceFailureSurfacesLoadError() {
        view.anchorSemesterToThisWeek()
        compare(view.loadError, "")
        scheduleService.operationFailed("节次保存失败")
        compare(view.loadError, "节次保存失败")
    }
}
