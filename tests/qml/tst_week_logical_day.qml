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

        // 合计与排序用例按需注入；默认空，保持原有日界用例的行为不变。
        property var weekTasks: []
        property int completedId: -1
        property bool completedValue: false

        function getWeekTasks(weekStartIso) {
            return taskManager.weekTasks
        }
        function setTaskCompleted(id, completed) {
            completedId = Number(id)
            completedValue = Boolean(completed)
            // 真实服务会让它在当天内沉底；这里同样改掉标志位，
            // 好让「完成后焦点跟着任务走」这条用例验的是真实重排后的状态。
            var next = []
            for (var i = 0; i < weekTasks.length; ++i) {
                var task = weekTasks[i]
                if (Number(task.id) === Number(id)) {
                    next.push({ id: task.id, title: task.title, date: task.date,
                                completed: Boolean(completed),
                                estimatedMinutes: task.estimatedMinutes,
                                displayOrder: task.displayOrder })
                } else {
                    next.push(task)
                }
            }
            weekTasks = next
            return true
        }
        function updateTask(id, title, categoryId, date) { return true }
        function moveTaskToDate(id, iso) { return true }
    }

    WeekPlanView {
        taskManagerRef: taskManager
        logicalDayServiceRef: logicalDayService
        settingsRef: appSettings
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
        // 复位放在 init 而不是用例末尾：断言一失败就跳过还原的话，
        // 一条真实失败会污染后面每一条。
        taskManager.weekTasks = []
        taskManager.completedId = -1
        view.cursorTaskId = -1
        view.logicalToday = view.computeLogicalToday()
        view.weekStart = view.mondayOf(view.logicalToday)
        view.refresh()
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

    // —— 每日/每周预计用时合计，以及「已完成沉底」的排序 ——

    // 默认的 fakeNow 是 7/13 凌晨 3:59，dayStartHour=4 下逻辑日还算 7/12（周日），
    // 那一周的周一是 7/6。合计与排序用例要的是 7/13 那一周，所以先把时钟推过日界。
    // 2026-07-13 是周一，推过之后本周一到周日 = 7/13 – 7/19。
    function seedMonday(tasks) {
        fakeNow = new Date(2026, 6, 13, 10, 0)
        view.logicalToday = view.computeLogicalToday()
        view.weekStart = view.mondayOf(view.logicalToday)
        taskManager.weekTasks = tasks
        view.refresh()
        compare(isoDate(view.weekStart), "2026-07-13")
    }

    function test_dayTotalSumsEstimatesRegardlessOfCompletion() {
        seedMonday([
            { id: 1, title: "高数", date: new Date(2026, 6, 13), completed: true,  estimatedMinutes: 180, displayOrder: 1 },
            { id: 2, title: "英语", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 90,  displayOrder: 2 },
            { id: 3, title: "单词", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 45,  displayOrder: 3 }
        ])

        // 问的是「排了多少」，所以已完成的那 180 分钟照样算进去，
        // 与今日任务页 plannedMinutesToday 同一口径。
        compare(view.plannedMinutesForDay(0), 315)
        compare(view.plannedMinutesForWeek(), 315)
    }

    function test_dayTotalIsZeroWhenNothingEstimated() {
        seedMonday([
            { id: 1, title: "没写预计用时", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 0, displayOrder: 1 }
        ])

        // 合法零值：有任务但都没写预计用时。界面据此不显示「已排 0 分钟」。
        // 先确认这一天确实取到了那条任务——否则 0 只说明日期没匹配上，这条用例就是空过。
        compare(view.tasksForDay(0).length, 1)
        compare(view.plannedMinutesForDay(0), 0)
    }

    // —— 统一验收补测（2026-09-14）——
    // 原有用例只断言了求和函数；验收写的是「无任务的日子不显示 0」「副标题给出本周合计」，
    // 这两件是界面上的，函数对了不等于显示对了。

    function test_dayTotalLabelIsHiddenOnEmptyAndZeroEstimateDays() {
        seedMonday([
            { id: 1, title: "有预计", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 90, displayOrder: 1 },
            { id: 2, title: "没写预计", date: new Date(2026, 6, 14), completed: false, estimatedMinutes: 0, displayOrder: 1 }
        ])
        var monday = findChild(view, "weekDayPlannedTotal-0")
        var tuesday = findChild(view, "weekDayPlannedTotal-1")
        var wednesday = findChild(view, "weekDayPlannedTotal-2")
        verify(monday !== null && tuesday !== null && wednesday !== null, "找不到每日合计")

        compare(monday.showsTotal, true)
        compare(monday.text, "已排 1 小时 30 分")
        // 有任务但都没写预计用时，与一条任务都没有的日子一样保持安静。
        compare(tuesday.showsTotal, false)
        compare(wednesday.showsTotal, false)
    }

    function test_subtitleReportsWeekTotal() {
        seedMonday([
            { id: 1, title: "周一", date: new Date(2026, 6, 13), completed: true, estimatedMinutes: 60, displayOrder: 1 },
            { id: 2, title: "周三", date: new Date(2026, 6, 15), completed: false, estimatedMinutes: 150, displayOrder: 1 }
        ])
        var subtitle = findChild(view, "weekSummaryText")
        verify(subtitle !== null)
        compare(subtitle.text, "7.13 – 7.19 · 本周 2 个任务 · 已完成 1 · 共排 3 小时 30 分")
    }

    // 阶段七验收：「游标移出可视区时列表自动滚动到它，滚动后再按 ↑↓ 落点正确（虚拟化下不偏移）」。
    // 原有用例只测了游标编号怎么走，没测滚动。这里用真实按键，量任务行在列表视口里的位置。

    function taskRow(taskId) {
        var stack = [view]
        while (stack.length > 0) {
            var item = stack.pop()
            if (item && item.taskTitle !== undefined && Number(item.taskId) === Number(taskId))
                return item
            var kids = item ? item.children : []
            for (var i = 0; i < kids.length; ++i)
                stack.push(kids[i])
        }
        return null
    }

    function verifyRowInsideViewport(taskId) {
        var list = findChild(view, "weekScroll")
        // 滚动可能带过渡；等游标那一行被创建并落进视口。
        tryVerify(function () {
            var row = taskRow(taskId)
            if (!row)
                return false
            var top = row.mapToItem(list, 0, 0).y
            return top >= -0.5 && top + row.height <= list.height + 0.5
        }, 2000, "任务 " + taskId + " 的行不在列表视口内")
    }

    function weekOf(tasksPerDay) {
        var tasks = []
        var id = 1
        for (var d = 0; d < 7; ++d) {
            for (var n = 0; n < tasksPerDay[d]; ++n) {
                tasks.push({ id: id, title: "第" + (d + 1) + "天第" + (n + 1) + "条",
                             date: new Date(2026, 6, 13 + d), completed: false,
                             estimatedMinutes: 30, displayOrder: n + 1 })
                id += 1
            }
        }
        return tasks
    }

    function test_cursorScrollsIntoViewWithinAnOverfullDay() {
        // 一天 12 条，整天比视口高：只按天定位（ListView.Contain）会把这一天顶到视口上沿，
        // 当天靠后的任务仍在视口外。要看到的是游标那一行，不是那一天的开头。
        seedMonday(weekOf([12, 0, 0, 0, 0, 0, 0]))
        var list = findChild(view, "weekScroll")
        list.forceActiveFocus()
        keyClick(Qt.Key_Down)
        compare(view.cursorTaskId, 1)

        for (var i = 0; i < 11; ++i)
            keyClick(Qt.Key_Down)
        compare(view.cursorTaskId, 12)
        verifyRowInsideViewport(12)

        keyClick(Qt.Key_Up)
        compare(view.cursorTaskId, 11)
        verifyRowInsideViewport(11)

        // 往回按到当天第一条：这回是行跑到视口上沿之外，要往上补偏移。
        for (var j = 0; j < 10; ++j)
            keyClick(Qt.Key_Up)
        compare(view.cursorTaskId, 1)
        verifyRowInsideViewport(1)
    }

    function test_cursorScrollsAcrossVirtualizedDaysAndKeepsNavigating() {
        // 周日远在视口外、delegate 未创建；一路按到周日最后一条再往回按。
        seedMonday(weekOf([2, 2, 2, 2, 2, 2, 3]))
        var list = findChild(view, "weekScroll")
        list.forceActiveFocus()
        keyClick(Qt.Key_Down)
        for (var i = 0; i < 14; ++i)
            keyClick(Qt.Key_Down)
        compare(view.cursorTaskId, 15)
        verifyRowInsideViewport(15)

        keyClick(Qt.Key_Up)
        keyClick(Qt.Key_Up)
        compare(view.cursorTaskId, 13)
        verifyRowInsideViewport(13)

        // 回到开头同样可见。
        for (var j = 0; j < 12; ++j)
            keyClick(Qt.Key_Up)
        compare(view.cursorTaskId, 1)
        verifyRowInsideViewport(1)
    }

    function test_weekTotalSpansAllDays() {
        seedMonday([
            { id: 1, title: "周一", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 60, displayOrder: 1 },
            { id: 2, title: "周三", date: new Date(2026, 6, 15), completed: false, estimatedMinutes: 120, displayOrder: 1 },
            { id: 3, title: "周日", date: new Date(2026, 6, 19), completed: false, estimatedMinutes: 30, displayOrder: 1 }
        ])

        compare(view.plannedMinutesForDay(0), 60)
        compare(view.plannedMinutesForDay(2), 120)
        compare(view.plannedMinutesForDay(6), 30)
        compare(view.plannedMinutesForWeek(), 210)
    }

    function test_completedTasksSinkToEndOfTheirDay() {
        seedMonday([
            { id: 1, title: "做完的甲", date: new Date(2026, 6, 13), completed: true,  estimatedMinutes: 10, displayOrder: 1 },
            { id: 2, title: "没做的乙", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 10, displayOrder: 2 },
            { id: 3, title: "做完的丙", date: new Date(2026, 6, 13), completed: true,  estimatedMinutes: 10, displayOrder: 3 },
            { id: 4, title: "没做的丁", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 10, displayOrder: 4 }
        ])

        var day = view.tasksForDay(0)
        compare(day.length, 4)
        // 未完成在前、已完成在后。
        compare(day[0].id, 2)
        compare(day[1].id, 4)
        compare(day[2].id, 1)
        compare(day[3].id, 3)
    }

    function test_orderWithinSameCompletionStatusIsPreserved() {
        // 这条是「保留同完成状态内原有顺序」的门禁。服务层已按
        // display_order、创建时间、编号排好，界面这一层只做分区，不得引入第二种排序。
        seedMonday([
            { id: 11, title: "乙在前", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 5,   displayOrder: 1 },
            { id: 12, title: "甲在后", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 300, displayOrder: 2 },
            { id: 13, title: "做完的乙", date: new Date(2026, 6, 13), completed: true, estimatedMinutes: 5,   displayOrder: 3 },
            { id: 14, title: "做完的甲", date: new Date(2026, 6, 13), completed: true, estimatedMinutes: 300, displayOrder: 4 }
        ])

        var day = view.tasksForDay(0)
        // 若有人顺手按标题或按时长再排一次，这四条的相对位置就会变。
        compare(day[0].id, 11)
        compare(day[1].id, 12)
        compare(day[2].id, 13)
        compare(day[3].id, 14)
    }

    function test_otherDaysAreNotMixedIn() {
        seedMonday([
            { id: 21, title: "周一的", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 60, displayOrder: 1 },
            { id: 22, title: "周二的", date: new Date(2026, 6, 14), completed: false, estimatedMinutes: 60, displayOrder: 1 }
        ])

        var monday = view.tasksForDay(0)
        compare(monday.length, 1)
        compare(monday[0].id, 21)
        compare(view.plannedMinutesForDay(0), 60)
    }

    // —— 键盘导航 ——
    //
    // 外层列表的 model 是 7（一项一天），任务在内层 Repeater 里，
    // 所以不能直接用 ListView.currentIndex 当游标。这一组盯住四件事：
    // 跨日连续、空日跳过、完成后焦点跟着任务走、删除后的五级落点。

    function seedThreeDays() {
        seedMonday([
            // 周一两条
            { id: 1, title: "周一甲", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 30, displayOrder: 1 },
            { id: 2, title: "周一乙", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 30, displayOrder: 2 },
            // 周二空着（用来验证跳过）
            // 周三一条
            { id: 3, title: "周三甲", date: new Date(2026, 6, 15), completed: false, estimatedMinutes: 30, displayOrder: 1 },
            // 周日一条
            { id: 4, title: "周日甲", date: new Date(2026, 6, 19), completed: false, estimatedMinutes: 30, displayOrder: 1 }
        ])
    }

    function test_flatOrderSkipsEmptyDaysAndSpansTheWeek() {
        seedThreeDays()
        compare(view.flatTaskIds, [1, 2, 3, 4])
    }

    function test_cursorMovesAcrossDaysAndSkipsEmptyOnes() {
        seedThreeDays()

        view.moveCursor(1)
        compare(view.cursorTaskId, 1)
        view.moveCursor(1)
        compare(view.cursorTaskId, 2)
        // 周一最后一条按 ↓ 直接到周三——周二是空的，不能停在上面。
        view.moveCursor(1)
        compare(view.cursorTaskId, 3)
        view.moveCursor(1)
        compare(view.cursorTaskId, 4)
    }

    function test_cursorStopsAtBothEndsWithoutWrapping() {
        seedThreeDays()

        view.setCursor(4)
        view.moveCursor(1)
        // 到底就停，不绕回周一——绕回去会让人彻底失去位置感。
        compare(view.cursorTaskId, 4)

        view.setCursor(1)
        view.moveCursor(-1)
        compare(view.cursorTaskId, 1)
    }

    function test_cursorFollowsTaskAfterCompletionReorders() {
        seedThreeDays()
        view.setCursor(1)

        // 完成周一第一条，它会沉到当天末尾。
        compare(view.toggleCursorCompletion(), true)
        compare(taskManager.completedId, 1)

        // 完成时 delegate 上还挂着粒子动画，刷新被推迟 850ms（立刻刷会把 delegate 销毁，
        // 动画看不到结束）。这里要验的是重排之后的状态，所以等它落定。
        tryCompare(view, "completionRefreshDelayActive", false, 2000)

        var monday = view.tasksForDay(0)
        compare(monday[0].id, 2)
        compare(monday[1].id, 1)
        // 游标记的是编号不是下标，所以仍然指着刚被完成的那一条。
        compare(view.cursorTaskId, 1)
    }

    function test_deleteLandsOnNextTaskOfSameDay() {
        seedThreeDays()
        compare(view.cursorLandingAfterRemoving(1), 2)
    }

    function test_deleteOfLastTaskOfDayLandsOnItsPredecessor() {
        // 这一级上一版漏掉了：当天最后一条，但当天还有前序任务——
        // 应该落到前驱，而不是跳去别的一天。
        seedThreeDays()
        compare(view.cursorLandingAfterRemoving(2), 1)
    }

    function test_deleteOfOnlyTaskOfDayLandsOnNextNonEmptyDay() {
        seedThreeDays()
        // 周三只有一条，删掉后落到后面第一个非空日（周日）。
        compare(view.cursorLandingAfterRemoving(3), 4)
    }

    function test_deleteOfLastTaskOfWeekLandsOnPreviousNonEmptyDay() {
        // 这一级上一版也漏掉了：全周最后一条，但前几天还有任务——
        // 应该落到前序非空日的末条，而不是直接清空。
        seedThreeDays()
        compare(view.cursorLandingAfterRemoving(4), 3)
    }

    function test_deleteOfTheOnlyTaskInTheWeekClearsCursor() {
        seedMonday([
            { id: 9, title: "全周就这一条", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 10, displayOrder: 1 }
        ])
        compare(view.cursorLandingAfterRemoving(9), -1)
    }

    function test_cursorIsClearedWhenItsTaskDisappears() {
        seedThreeDays()
        view.setCursor(3)

        // 任务被改期到别的周或被删掉之后，同一个下标会指向另一条任务；
        // 按编号恢复就只能清空，不能留一个指向空气的游标。
        taskManager.weekTasks = [
            { id: 1, title: "周一甲", date: new Date(2026, 6, 13), completed: false, estimatedMinutes: 30, displayOrder: 1 }
        ]
        view.refresh()

        compare(view.cursorTaskId, -1)
    }

    function test_cursorSurvivesRefreshWhenTaskIsStillThere() {
        seedThreeDays()
        view.setCursor(3)

        view.refresh()

        compare(view.cursorTaskId, 3)
    }

    function test_enterOnlyStartsFocusForToday() {
        seedThreeDays()
        // fakeNow 已被 seedMonday 推到 7/13 10:00，逻辑今日是周一。
        view.setCursor(3)
        // 周三不是今天：回车不启动，与行内「开始」按钮只在今天出现同一口径。
        compare(view.startCursorFocus(), false)

        view.setCursor(1)
        compare(view.startCursorFocus(), true)
    }
}
