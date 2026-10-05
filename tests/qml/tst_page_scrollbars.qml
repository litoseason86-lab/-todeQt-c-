pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../../qml"

// 各页面的竖向滚动条统一贴窗口最右缘（仪表盘贴任务面板右边线外侧），玻璃框的左右下边距统一 24。
// 这类问题只在整页里才看得出来：组件单测里滚动条贴的是组件自己的右缘，挪进页面后它离窗口右缘
// 还差一个页边距，或者浮在玻璃框里面。所以这里装载整个主窗口，逐页量窗口坐标。
TestCase {
    id: testCase
    name: "PageScrollBars"
    when: windowShown
    // 可见性会沿父链级联，滚动条「放得下就隐藏」依赖它；根节点不可见时量出来的都不可信。
    visible: true
    width: 1024
    height: 640

    function task(id, title, completed) {
        return { id: id, title: title, completed: completed, categoryText: "专业课",
                 estimatedMinutes: 30, notes: "", completionNote: "", focusedMinutes: 0,
                 date: "2026-09-23", categoryId: -1 }
    }

    function session(id, start, end) {
        return { id: id, taskId: id, taskTitle: "记录 " + id,
                 startTime: "2026-09-23T" + start + ":00", endTime: "2026-09-23T" + end + ":00",
                 durationSeconds: 1800, date: "2026-09-23" }
    }

    // 每一页都要比 640 高的窗口多出一截内容，滚动条才会出现。
    readonly property var todayTasks: {
        var rows = []
        for (var i = 1; i <= 9; ++i)
            rows.push(task(i, "任务 " + i, i > 7))
        return rows
    }
    readonly property var sessions: {
        var rows = []
        for (var i = 1; i <= 9; ++i)
            rows.push(session(i, (8 + i) + ":00", (8 + i) + ":30"))
        return rows
    }

    QtObject {
        id: taskManager

        signal tasksChanged
        signal operationFailed(string message)

        readonly property int maxNotesLength: 2000
        readonly property int maxTitleLength: 200

        function getTodayTasks() { return testCase.todayTasks }
        function getOverdueUncompletedTasks() { return [] }
        function getWeekTasks(weekStart) {
            // 任务日期必须落在页面请求的这一周（weekStart 是 yyyy-MM-dd 的周一）。
            // 曾写死 2026-09-21 那一周：真实日期一跨周，本周计划就变空、内容不满一屏，
            // 滚动条断言随之失败。按本地年月日构造，不用 new Date("yyyy-MM-dd")——那会按 UTC 解析，差出一天。
            var parts = String(weekStart).split("-")
            var rows = []
            for (var d = 0; d < 7; ++d) {
                for (var k = 0; k < 3; ++k) {
                    var row = testCase.task(100 + d * 10 + k, "周任务 " + d + "-" + k, false)
                    row.date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]) + d)
                    rows.push(row)
                }
            }
            return rows
        }
        function getTasksByDate(date) { return testCase.todayTasks }
        function getTask(id) { return ({}) }
        function setTaskCompleted(id, completed) { return true }
        function completeTaskWithNote(id, note) { return true }
        function updateTask() { return true }
        function isRoutineGeneratedTask(id) { return false }
    }

    QtObject {
        id: categoryManager
        signal categoriesChanged
        function getCategories() { return [] }
        function getActiveCategories() { return [] }
        function readAllCategories() { return { ok: true, categories: getAllCategories() } }
        function getAllCategories() { return [] }
    }

    QtObject {
        id: routineManager
        signal routinesChanged
        function materializeToday() {}
        function getRoutines() { return [] }
    }

    QtObject {
        id: statisticsService

        signal operationFailed(string message)

        function comparison(text) { return { hasData: true, displayText: text, trend: 0 } }
        function getTodayStats() {
            return { totalDuration: 3600, completedTasks: 2, totalTasks: 9, completionRate: 0.2,
                     sessionCount: 9, pomodoroCount: 0 }
        }
        function getDayStats(date) { return getTodayStats() }
        function getDayComparison(date) {
            return { taskCompletion: comparison("→ 0%"), sessionCount: comparison("→ 0%"), duration: comparison("→ 0%") }
        }
        function getWeekStats() { return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 } }
        function getWeekComparison(weekStart) {
            return { effectiveDays: comparison("→ 0%"), sessionCount: comparison("→ 0%"), duration: comparison("→ 0%") }
        }
        function getWeeklyReview(weekStart, logicalTodayIso) {
            return { loadState: "ready", periodState: "current", hasData: false, hasDisplayContent: false,
                     goal: ({}), todayGoal: ({}), subjects: [], plannedTasks: ({}), facts: [] }
        }
        function getCategoryStats(startDate, endDate) { return [] }
        function getMonthStats(year, month) {
            return { totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 }
        }
        function getMonthComparison(year, month) {
            return { effectiveDays: comparison("→ 0%"), sessionCount: comparison("→ 0%"), duration: comparison("→ 0%") }
        }
        function getMonthWeeklySummary(year, month) { return [] }
        function getStreakDays() { return 0 }
        function getTotalFocusDuration() { return 0 }
        function getTodayTaskStats() { return ({ tasks: [], totalDuration: 0, taskCount: 0 }) }
    }

    QtObject {
        id: focusHistoryService

        signal historyChanged()

        function getDayTimeline(date) { return testCase.sessions }
        function getDaySessions(date) { return testCase.sessions }
        function getMonthSessions(year, month) { return testCase.sessions }
        function getTaskOptions(date) { return [] }
        function formatDuration(seconds) { return Math.floor(seconds / 60) + "分钟" }
        function lastError() { return "" }
        function invalidSessionCount() { return 0 }
        function addManualSession() { return 9 }
    }

    // 第 0 条是主目标，其余是次要目标列表；8 条次要目标超出 640 高窗口里的列表区。
    ListModel {
        id: countdownModel
        Component.onCompleted: {
            for (var i = 0; i < 9; ++i)
                append({ goalId: i + 1, name: "目标 " + (i + 1), targetDate: new Date(2026, 11, 1 + i),
                         daysRemaining: 60 + i })
        }
    }

    QtObject {
        id: countdownService

        signal goalsChanged()
        signal operationFailed(string message)

        property var model: countdownModel
        property var primaryGoal: ({ goalId: 1, name: "目标 1", targetDate: new Date(2026, 11, 1), daysRemaining: 60 })

        function reload() { return true }
    }

    QtObject {
        id: knowledgeGapService

        signal gapsChanged()
        signal operationFailed(string message)

        readonly property int maxTitleLength: 100

        function listGaps(statusFilter, categoryId, searchText, limit) {
            var rows = []
            for (var i = 0; i < 9; ++i) {
                rows.push({ id: i + 1, title: "知识缺口 " + (i + 1), detail: "", categoryId: 0,
                            categoryName: "", categoryColor: "", sourceTaskId: 0, sourceTaskTitle: "",
                            priority: 1, status: 1, dueDate: "2026-09-30", scheduled: true, overdue: false,
                            overdueDays: 0, dueToday: false, resolution: "", linkedTaskId: 0,
                            linkedTaskCompleted: false, linkedTaskTitle: "", linkedTaskOpen: false })
            }
            return rows
        }
        function getReminderSummary() {
            return { valid: true, dueToday: 0, overdue: 0, unscheduled: 0, openTotal: 9, oldestOverdueDays: 0 }
        }
    }

    QtObject {
        id: scheduleService

        signal scheduleChanged()
        signal periodsChanged()
        signal operationFailed(string message)

        readonly property int maxTitleLength: 60
        readonly property int maxLocationLength: 60
        readonly property int maxWeekIndex: 60
        readonly property int maxPeriodCount: 24

        // 早八到晚九：时间轴高度远超 640 高窗口里的网格区。
        readonly property var entries: [
            { id: 1, title: "早课", location: "A101", weekday: 1, startMinutes: 480, endMinutes: 570,
              durationMinutes: 90, weekStart: 1, weekEnd: 16, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" },
            { id: 2, title: "晚课", location: "B202", weekday: 3, startMinutes: 1170, endMinutes: 1260,
              durationMinutes: 90, weekStart: 1, weekEnd: 16, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" }
        ]
        function getEntriesForWeek(weekIndex) { return weekIndex < 1 ? [] : entries }
        function getPeriods() { return [] }
        function findConflicts() { return [] }
    }

    QtObject {
        id: focusTimer

        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int mode: 0
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
        property int minimumValidMinutes: 3
        property int completedPomodoros: 0
        property string sessionLogicalDate: ""
        property bool requiresFreeFocusStopConfirmation: false

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)

        function startFocus(id, title) { return true }
        function pauseFocus() {}
        function resumeFocus() { return true }
        function stopFocus() { return true }
        function resetPomodoroCount() {}
    }

    QtObject {
        id: appSettings

        signal settingsWriteSucceeded()
        signal settingsWriteFailed(string message)
        signal dailyFocusGoalChanged

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
        // 切页瞬时完成，不用等淡入淡出。
        property bool reduceMotion: true
        property bool slimClockFont: true
        property int dayStartHour: 4
        property string rolloverIgnoredDate: ""
        property string backgroundTheme: "jiangnan"
        property bool sidebarVisible: true
        property bool reduceTransparency: false
        property bool raiseOnPhaseComplete: true
        property bool autoStartBreak: false
        property bool autoStartNextPomodoro: false
        property bool quickStartEnabled: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property string nickname: ""
        property bool dashboardTimerVisible: true
        property int freeTimerWarningHours: 3
        property var sidebarOrder: []
        property bool sidebarOrderIsDefault: true
        property string semesterStartDate: "2026-08-31"
        property int semesterWeeks: 16
        property string scheduleDisplayMode: "time"
        property bool scheduleShowWeekend: true

        function dailyFocusGoalMinutesForDate(isoDate) { return 0 }
        function setDailyFocusGoal(isoDate, minutes) { return true }
    }

    QtObject {
        id: logicalDayService
        signal changed
    }

    QtObject {
        id: backupService
        property bool operationBlocksUi: false
        property string operationText: ""
    }

    QtObject {
        id: shortcutRegistry
        readonly property var inAppActions: []
        readonly property var actions: []
        readonly property var globalActions: []
        readonly property var groups: []
        signal globalActionTriggered(string actionId)
        signal globalRegistrationFailed(string actionId, string title)
        function normalize(key, modifiers) { return "" }
    }

    MainWindow {
        id: mainWindow

        width: testCase.width
        height: testCase.height
        taskManagerRef: taskManager
        categoryManagerRef: categoryManager
        routineManagerRef: routineManager
        statisticsServiceRef: statisticsService
        focusHistoryServiceRef: focusHistoryService
        countdownServiceRef: countdownService
        knowledgeGapServiceRef: knowledgeGapService
        appSettingsRef: appSettings
        focusTimerRef: focusTimer
        logicalDayServiceRef: logicalDayService
        backupServiceRef: backupService
        scheduleServiceRef: scheduleService
        shortcutRegistryRef: shortcutRegistry
    }

    function showPage(view) {
        mainWindow.switchToView(view)
        tryCompare(mainWindow, "currentView", view)
    }

    function boxOf(item) {
        return item.mapToItem(mainWindow, 0, 0)
    }

    // ScrollView 没有 contentY，它的内容由内部的 Flickable（contentItem）滚动。
    function flickableOf(item) {
        return item.contentY !== undefined ? item : item.contentItem
    }

    function test_scrollBarHugsWindowEdge_data() {
        return [
            { tag: "仪表盘", view: "dashboard", bar: "dashboardTaskScrollBar", scroll: "dashboardTaskScrollView" },
            { tag: "今日任务", view: "today", bar: "todayTaskScrollBar", scroll: "todayTaskList" },
            { tag: "今日专注", view: "todayFocus", bar: "focusTimelineVerticalScrollBar", scroll: "focusTimelineScrollView" },
            { tag: "课表", view: "schedule", bar: "scheduleScrollBar", scroll: "scheduleGridBody" },
            { tag: "本周计划", view: "week", bar: "weekScrollBar", scroll: "weekScroll" },
            { tag: "专注历史", view: "month", bar: "monthPageScrollBar", scroll: "monthPageScrollView" },
            { tag: "数据统计", view: "stats", bar: "statisticsScrollBar", scroll: "statisticsScrollView" },
            { tag: "知识缺口", view: "knowledgeGaps", bar: "knowledgeGapScrollBar", scroll: "knowledgeGapScrollView" },
            { tag: "目标倒计时", view: "countdown", bar: "countdownScrollBar", scroll: "countdownSecondaryList" }
        ]
    }

    function test_scrollBarHugsWindowEdge(data) {
        testCase.showPage(data.view)

        const bar = findChild(mainWindow, data.bar)
        const scroll = findChild(mainWindow, data.scroll)
        verify(bar !== null, data.bar)
        verify(scroll !== null, data.scroll)
        // 内容确实超出一屏，滚动条才有意义。
        tryVerify(function () { return bar.size > 0 && bar.size < 1 }, 3000)

        // 右缘贴窗口右缘；竖向完整落在窗口里。
        const box = testCase.boxOf(bar)
        compare(Math.round(box.x + bar.width), mainWindow.width)
        verify(box.y >= 0)
        verify(Math.round(box.y + bar.height) <= mainWindow.height)

        // 拖滚动条要真的带动内容：滚动条不一定是滚动区的子项，这条连接靠 ScrollBar.vertical。
        const flick = testCase.flickableOf(scroll)
        const before = flick.contentY
        bar.position = Math.min(0.5, 1 - bar.size)
        tryVerify(function () { return flick.contentY > before })
        bar.position = 0
    }

    // 默认窗口宽度下仪表盘的专注面板是收起的，任务清单的滚动条和其它页面一样贴窗口最右缘（上面的数据行）；
    // 右缘的展开把手只在任务面板上方那段感应，不能叠在滚动条上。
    // 专注面板展开时滚动条落在两块面板之间，那种情形由 tst_dashboard_view 覆盖。
    function test_dashboardRevealHandleStaysAboveTheTaskList() {
        testCase.showPage("dashboard")

        const bar = findChild(mainWindow, "dashboardTaskScrollBar")
        const reveal = findChild(mainWindow, "dashboardTimerRevealButton")
        verify(bar !== null)
        verify(reveal !== null)
        tryVerify(function () { return bar.size > 0 && bar.size < 1 }, 3000)
        verify(reveal.enabled)
        verify(Math.round(testCase.boxOf(reveal).y + reveal.height) <= Math.round(testCase.boxOf(bar).y))
    }

    // 今日任务的列表框原先没有内边距，任务卡的描边和框的描边叠在一起；现在与仪表盘任务面板同为 16。
    function test_todayTaskListIsInsetInsideItsFrame() {
        testCase.showPage("today")

        const frame = findChild(mainWindow, "todayTaskListContainer")
        const list = findChild(mainWindow, "todayTaskList")
        verify(frame !== null)
        verify(list !== null)
        tryVerify(function () { return list.width > 0 && list.count > 0 })

        const frameBox = testCase.boxOf(frame)
        const listBox = testCase.boxOf(list)
        compare(Math.round(listBox.x - frameBox.x), Theme.space16)
        compare(Math.round(listBox.y - frameBox.y), Theme.space16)
        compare(Math.round(frameBox.x + frame.width - (listBox.x + list.width)), Theme.space16)
        compare(Math.round(frameBox.y + frame.height - (listBox.y + list.height)), Theme.space16)
    }

    // 玻璃框的左右边距统一 24，填满页面的框底边也离窗口底 24；切页时框的边不再跳动。
    function test_glassFrameMargins_data() {
        return [
            { tag: "今日任务", view: "today", frame: "todayTaskListContainer", right: 24, fillsPage: true },
            { tag: "今日专注", view: "todayFocus", frame: "focusTimelineGlass", right: 24, fillsPage: true },
            { tag: "课表", view: "schedule", frame: "scheduleGridGlass", right: 24, fillsPage: true },
            { tag: "仪表盘", view: "dashboard", frame: "dashboardTaskPanel", right: 24, fillsPage: true },
            { tag: "专注历史", view: "month", frame: "monthCalendarContainer", right: 24, fillsPage: false },
            { tag: "目标倒计时", view: "countdown", frame: "countdownHeroCard", right: 24, fillsPage: false }
        ]
    }

    function test_glassFrameMargins(data) {
        testCase.showPage(data.view)

        const frame = findChild(mainWindow, data.frame)
        const stack = findChild(mainWindow, "mainViewStack")
        verify(frame !== null, data.frame)
        verify(stack !== null)
        // 页面在切出来之前不可见，布局不会排版；切出来后的第一帧才定下几何，先等左边距落定。
        const leftMargin = function () {
            return Math.round(testCase.boxOf(frame).x - testCase.boxOf(stack).x)
        }
        const rightMargin = function () {
            return Math.round(testCase.boxOf(stack).x + stack.width - (testCase.boxOf(frame).x + frame.width))
        }
        tryVerify(function () { return leftMargin() === 24 && rightMargin() === data.right }, 3000)

        const frameBox = testCase.boxOf(frame)
        const stackBox = testCase.boxOf(stack)
        compare(leftMargin(), 24)
        compare(rightMargin(), data.right)
        if (data.fillsPage)
            compare(Math.round(stackBox.y + stack.height - (frameBox.y + frame.height)), 24)
        // 描边与圆角同一套。
        verify(Qt.colorEqual(frame.border.color, Theme.glassBorder))
        compare(frame.radius, Theme.radiusLg)
    }
}
