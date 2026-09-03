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
        // baseEntries 是基线，allEntries 是各条用例可以随意增删的工作副本；
        // 每条用例开始前由 init() 从基线整体重置。
        // 用例末尾「用完再改回去」那种写法看着也行，但断言一失败就跳过了还原，
        // 一条真实失败会污染后面每一条，把排查引到完全无关的地方去。
        property var baseEntries: [
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

        property var allEntries: scheduleService.baseEntries

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
        scheduleService.allEntries = scheduleService.baseEntries
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

    function test_thisWeekButtonIsDisabledOnceSemesterIsOver() {
        view.anchorSemesterToThisWeek()
        compare(view.currentWeekIndex, 1)
        verify(view.currentWeekInSemester)

        // 学期只有 16 周，把「今天」推到第 20 周（2027-01-11 那个周一）。
        testCase.fakeNow = new Date(2027, 0, 11, 10, 0)
        logicalDayService.changed()
        compare(view.currentWeekIndex, 20)
        verify(!view.currentWeekInSemester)

        // 关键点：weekIndex 被夹在 16，怎么按「本周」都到不了第 20 周。
        // 按钮必须灰掉——之前它是可点的，点下去页面纹丝不动，也没有任何解释。
        var button = findChild(view, "scheduleThisWeekButton")
        verify(button !== null)
        verify(!button.enabled, "学期结束后「本周」按钮不能还是可点的")

        view.goToWeek(view.currentWeekIndex)
        compare(view.weekIndex, appSettings.semesterWeeks)
        verify(!view.viewingCurrentWeek)

        testCase.fakeNow = new Date(2026, 8, 2, 10, 0)
    }

    function test_weekendEntryIsReportedByExactlyOneReason() {
        view.anchorSemesterToThisWeek()
        // 周六 12:30 的一项：既落在被隐藏的周末列，又不在任何节次里。
        scheduleService.allEntries = scheduleService.allEntries.concat([{
            id: 4, title: "周六补习", location: "", weekday: 6,
            startMinutes: 750, endMinutes: 780, durationMinutes: 30,
            weekStart: 1, weekEnd: 16, weekParity: 0,
            categoryId: undefined, categoryName: "", categoryColor: ""
        }])
        appSettings.scheduleDisplayMode = "period"
        appSettings.scheduleShowWeekend = false
        view.refresh()

        var grid = findChild(view, "scheduleGrid")
        verify(grid !== null)
        compare(grid.hiddenWeekendEntries.length, 1)
        compare(grid.hiddenWeekendEntries[0].title, "周六补习")
        // 同一条目不能被两条理由各认领一次：否则横幅会同时说「有 1 项在周末」
        // 和「有 1 项不在任何节次内」，用户会以为自己丢了两项。
        for (var i = 0; i < grid.unplacedEntries.length; ++i) {
            verify(grid.unplacedEntries[i].title !== "周六补习",
                   "周末被隐藏的条目不该再计入「不在任何节次内」")
        }

        // 周末列打开后，它重新变成一个纯粹的「落不进节次」问题。
        appSettings.scheduleShowWeekend = true
        compare(grid.hiddenWeekendEntries.length, 0)
        var found = false
        for (var j = 0; j < grid.unplacedEntries.length; ++j) {
            if (grid.unplacedEntries[j].title === "周六补习") {
                found = true
            }
        }
        verify(found, "周末列打开后它必须被「不在任何节次内」认领")

    }

    function test_hiddenWeekendEntriesDoNotStretchTheTimeAxis() {
        view.anchorSemesterToThisWeek()
        // 周六早上 6:00 的一项。周末列关掉时它一列都没有，
        // 却不该让周一到周五凭空多出两小时无人认领的空白。
        scheduleService.allEntries = scheduleService.allEntries.concat([{
            id: 5, title: "周六晨练", location: "", weekday: 6,
            startMinutes: 360, endMinutes: 420, durationMinutes: 60,
            weekStart: 1, weekEnd: 16, weekParity: 0,
            categoryId: undefined, categoryName: "", categoryColor: ""
        }])
        view.refresh()

        var grid = findChild(view, "scheduleGrid")
        verify(grid !== null)
        compare(grid.axisStartMinutes, 360)

        appSettings.scheduleShowWeekend = false
        compare(grid.axisStartMinutes, 480)

    }

    function test_headerControlsAllHaveAccessibleNames() {
        view.anchorSemesterToThisWeek()
        // 「‹」「›」这类符号按钮对读屏毫无意义，必须有显式名称；
        // 「本周」曾经因为用了自定义属性而不是内建 text，成了一颗念不出名字的按钮。
        var expected = {
            "schedulePrevWeekButton": "上一周",
            "scheduleThisWeekButton": "本周",
            "scheduleNextWeekButton": "下一周",
            "scheduleSettingsButton": "课表设置"
        }
        for (var name in expected) {
            var button = findChild(view, name)
            verify(button !== null, "找不到 " + name)
            compare(String(button.Accessible.name), expected[name],
                    name + " 缺少无障碍名称")
        }
    }

    function test_serviceFailureSurfacesLoadError() {
        view.anchorSemesterToThisWeek()
        compare(view.loadError, "")
        scheduleService.operationFailed("节次保存失败")
        compare(view.loadError, "节次保存失败")
    }
}
