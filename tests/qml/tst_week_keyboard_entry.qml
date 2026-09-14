pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import "../../qml"
import "../../qml/LogicalDay.js" as LogicalDay

TestCase {
    id: testCase
    name: "WeekKeyboardEntry"
    when: windowShown
    // 这组用例要发真实的鼠标点击与按键。TestCase 默认不可见，整条父链 visible 为假时
    // 点击进不去、焦点也落不下来——测到的就不是用户那条路径了。
    visible: true
    width: 1100
    height: 760

    QtObject {
        id: taskManager

        signal tasksChanged

        property int deleteTaskCalls: 0
        property int lastDeletedTaskId: -1
        property bool deleteSucceeds: true

        // 选择器的候选来源。用例按需替换，默认空——保持原有用例的行为不变。
        property var todayTasks: []
        property int maxTitleLength: 100
        property int createTaskCalls: 0
        property string createTaskTitle: ""
        property string createTaskDate: ""
        // createTask 要返回的新任务编号；<= 0 表示新建失败。
        property int createTaskResultId: 901

        function getTodayTasks() { return todayTasks }
        // 本周计划的数据：全部排在逻辑今日，避免跨周边界让用例随运行日期抖动。
        property var weekRows: []
        property int setCompletedCalls: 0
        function getWeekTasks(weekStart) { return weekRows }
        // 有这两个方法本周页才允许拖动（canMoveTasks）；拖动守护用例要用。
        function moveTaskToDate(id, date) { return true }
        function reorderTasks(date, ids) { return true }
        function getMonthTasks(year, month) { return [] }
        function getTask(id) {
            for (var i = 0; i < todayTasks.length; ++i) {
                if (Number(todayTasks[i].id) === Number(id))
                    return todayTasks[i]
            }
            return {}
        }
        // 与 TaskManager::createTask 同契约：成功返回新任务编号，失败返回 -1。
        function createTask(title, date, categoryId, estimatedMinutes, notes) {
            createTaskCalls += 1
            createTaskTitle = String(title)
            createTaskDate = String(date)
            if (createTaskResultId <= 0)
                return -1
            var next = todayTasks.slice()
            next.push({ id: createTaskResultId, title: String(title), completed: false,
                        displayOrder: 1, estimatedMinutes: 0, notes: "" })
            todayTasks = next
            return createTaskResultId
        }
        function setTaskCompleted(id, completed) {
            setCompletedCalls += 1
            var next = []
            for (var i = 0; i < weekRows.length; ++i) {
                var row = weekRows[i]
                if (Number(row.id) === Number(id))
                    row = Object.assign({}, row, { completed: completed })
                next.push(row)
            }
            weekRows = next
            tasksChanged()
            return true
        }
        function deleteTask(id) {
            deleteTaskCalls += 1
            lastDeletedTaskId = id
            return deleteSucceeds
        }
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
        property bool stopSucceeds: true
        // 服务端对已删除任务会插入 0 行而失败；用例按需置假模拟。
        property bool startFocusSucceeds: true
        property int pauseFocusCalls: 0
        property int stopFocusCalls: 0
        property int startPomodoroCalls: 0
        property int startFocusCalls: 0
        property int startFocusTaskId: 0
        property string startFocusTaskTitle: ""

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)
        signal sessionDiscarded(int duration)
        signal taskAutoCompleteFailed(int taskId)

        function startFocus(id, title) {
            startFocusCalls += 1
            if (!startFocusSucceeds)
                return false
            startFocusTaskId = id
            startFocusTaskTitle = title
            currentTaskId = id
            currentTaskTitle = title
            hasActiveSession = true
            isRunning = true
            return true
        }

        function startPomodoroWork(id, title, workSeconds) {
            startPomodoroCalls++
            currentTaskId = id
            currentTaskTitle = title
            mode = 1
            phase = 1
            hasActiveSession = true
            isRunning = true
            return true
        }
        function startBreak(breakSeconds) { return true }
        function startBreakForTask(breakSeconds, taskId, title) { return true }
        function resetPomodoroCount() { completedPomodoros = 0 }
        function pauseFocus() { pauseFocusCalls += 1 }
        function resumeFocus() { return true }

        function stopFocus() {
            stopFocusCalls += 1
            if (!stopSucceeds) return false
            hasActiveSession = false
            isRunning = false
            mode = 0
            phase = 0
            return true
        }
    }

    QtObject {
        id: appSettings

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
        property int dayStartHour: 4
        property string rolloverIgnoredDate: ""
        property string backgroundTheme: "warm"
        property bool sidebarVisible: true
        property bool reduceTransparency: false
        property bool raiseOnPhaseComplete: true
        property bool autoStartBreak: false
        property bool autoStartNextPomodoro: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property string nickname: ""
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 }
        }

        function makeComparison(displayText, trend) {
            return { hasData: true, displayText: displayText, trend: trend }
        }

        function getDayComparison(date) {
            return {
                taskCompletion: makeComparison("-> 0% vs 昨天", 0),
                sessionCount: makeComparison("-> 0% vs 昨天", 0),
                duration: makeComparison("-> 0% vs 昨天", 0)
            }
        }

        function getWeekStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 }
        }

        function getWeekComparison(weekStart) {
            return {
                effectiveDays: makeComparison("-> 0% vs 上周", 0),
                sessionCount: makeComparison("-> 0% vs 上周", 0),
                duration: makeComparison("-> 0% vs 上周", 0)
            }
        }

        function getCategoryStats(startDate, endDate) { return [] }

        function getMonthStats(year, month) {
            return { totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 }
        }

        function getMonthComparison(year, month) {
            return {
                effectiveDays: makeComparison("-> 0% vs 上月", 0),
                sessionCount: makeComparison("-> 0% vs 上月", 0),
                duration: makeComparison("-> 0% vs 上月", 0)
            }
        }

        function getMonthWeeklySummary(year, month) { return [] }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged

        function getCategories() { return [] }
        function getActiveCategories() { return [] }
    }

    QtObject {
        id: exportService
    }

    QtObject {
        id: knowledgeGapService

        signal gapsChanged()
        signal operationFailed(string message)

        property int maxTitleLength: 100
        property int captureCalls: 0
        property string lastTitle: ""
        property int lastSourceTaskId: -1

        function captureGap(title, categoryId, sourceTaskId) {
            captureCalls += 1
            lastTitle = String(title)
            lastSourceTaskId = Number(sourceTaskId)
            return captureCalls
        }
        function getReminderSummary() { return {} }
        function listGaps(filter, categoryId, keyword, limit) { return [] }
    }

    QtObject {
        id: historyService
        property int deletedId: -1
        property bool succeeds: true
        function deleteSession(id) { if (succeeds) deletedId = id; return succeeds }
        function getDayTimeline() { return [] }
        function getMonthSessions() { return [] }
        function lastError() { return "" }
    }
    MainWindow {
        id: mainWindow

        width: testCase.width
        height: testCase.height
        focusHistoryServiceRef: historyService
        taskManagerRef: taskManager
        categoryManagerRef: categoryManager
        exportServiceRef: exportService
        statisticsServiceRef: statisticsService
        appSettingsRef: appSettings
        focusTimerRef: focusTimer
        knowledgeGapServiceRef: knowledgeGapService
    }


    function logicalToday() {
        return LogicalDay.todayDate(appSettings.dayStartHour, new Date())
    }

    function seedWeek(rows) {
        var today = logicalToday()
        var list = []
        for (var i = 0; i < rows.length; ++i) {
            list.push(Object.assign({ date: today, estimatedMinutes: 30, notes: "", focusedMinutes: 0,
                                      displayOrder: i + 1, categoryText: "" }, rows[i]))
        }
        taskManager.weekRows = list
    }

    function weekView() {
        var list = findChild(mainWindow, "weekScroll")
        verify(list !== null)
        var view = list.parent
        while (view && view.cursorTaskId === undefined)
            view = view.parent
        verify(view !== null)
        return view
    }

    function clickSidebar(marker, target) {
        var hit = findChild(mainWindow, "sidebarHitArea-" + marker)
        verify(hit !== null, "找不到侧栏条目 " + marker)
        mouseClick(hit, hit.width / 2, hit.height / 2)
        tryVerify(function () { return mainWindow.currentView === target && !mainWindow.isSwitching }, 3000)
        wait(80)
    }

    function taskRow(taskId) {
        var found = null
        function walk(item) {
            if (!item || found)
                return
            if (item.keyboardFocused !== undefined && Number(item.taskId) === taskId && item.width > 0) {
                found = item
                return
            }
            var kids = item.children || []
            for (var i = 0; i < kids.length; ++i)
                walk(kids[i])
        }
        walk(findChild(mainWindow, "weekScroll"))
        verify(found !== null, "找不到任务行 " + taskId)
        return found
    }

    function init() {
        mainWindow.currentView = "today"
        mainWindow.pendingView = "today"
        mainWindow.queuedView = ""
        mainWindow.isSwitching = false
        focusTimer.startFocusCalls = 0
        focusTimer.startPomodoroCalls = 0
        focusTimer.startFocusTaskId = 0
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
        focusTimer.mode = 0
        focusTimer.phase = 0
        appSettings.lastMode = 0
        taskManager.setCompletedCalls = 0
        taskManager.deleteTaskCalls = 0
        mainWindow.cancelPendingDelete()
        weekView().cursorTaskId = -1
        seedWeek([
            { id: 501, title: "第一条", completed: false },
            { id: 502, title: "第二条", completed: false },
            { id: 503, title: "第三条", completed: false }
        ])
        wait(20)
    }

    // —— 键盘入口：真实点击、真实按键（2026-09-14 审查修复）——
    //
    // 原先的用例全部直接调 moveCursor，从来没发过按键，于是没发现：
    // 鼠标点侧栏进本周页后焦点停在侧栏条目上，↑↓ 全部无效，点任务行也拿不回焦点。

    function test_sidebarClickThenArrowMovesCursor() {
        clickSidebar("今", "today")
        clickSidebar("周", "week")
        var view = weekView()
        compare(view.cursorTaskId, -1)

        keyClick(Qt.Key_Down)

        compare(view.cursorTaskId, 501)
        keyClick(Qt.Key_Down)
        compare(view.cursorTaskId, 502)
    }

    function test_clickingTaskRowThenArrowContinuesFromThatRow() {
        clickSidebar("周", "week")
        var view = weekView()
        // 再点一次侧栏当前项：焦点回到侧栏，页面没有切换、也不会再次交接焦点。
        var hit = findChild(mainWindow, "sidebarHitArea-周")
        mouseClick(hit, hit.width / 2, hit.height / 2)
        wait(60)

        var row = taskRow(502)
        mouseClick(row, Math.min(40, row.width / 4), row.height / 2)
        wait(60)
        compare(view.cursorTaskId, 502)

        keyClick(Qt.Key_Down)
        compare(view.cursorTaskId, 503)
    }

    function test_renameFieldEditingDoesNotDriveTheList() {
        clickSidebar("周", "week")
        var view = weekView()
        // 这条只验「编辑时不抢键」，入口由上面两条负责；显式给焦点，不让两件事互相遮挡。
        findChild(mainWindow, "weekScroll").forceActiveFocus()
        keyClick(Qt.Key_Down)
        compare(view.cursorTaskId, 501)

        var row = taskRow(502)
        // 进入编辑态沿用 tst_task_item_edit 的做法：离屏平台下双击标题的 TapHandler 不稳定。
        // 这条要验的是编辑中的**真实按键**不被列表抢走，按键下面都是 keyClick。
        row.beginTitleEdit()
        var field = findChild(row, "taskTitleEditField")
        tryCompare(field, "activeFocus", true, 1000)

        // 单行输入框不接 ↑↓ 与 ⌘⌫，这些键会冒到列表上——编辑时列表不能动。
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Up)
        compare(view.cursorTaskId, 501)
        keyClick(Qt.Key_Backspace, Qt.ControlModifier)
        compare(mainWindow.pendingDeleteTaskId, -1)
        // 可打印字符照常进输入框，不触发完成与编辑。
        keyClick(Qt.Key_Space)
        keyClick(Qt.Key_E)
        compare(taskManager.setCompletedCalls, 0)
        compare(field.activeFocus, true)
        keyClick(Qt.Key_Escape)
    }

    // —— 回车启动与行内按钮共用可启动条件 ——

    function test_returnDoesNotStartCompletedTaskAndMatchesRowButton() {
        seedWeek([
            { id: 601, title: "还没做", completed: false },
            { id: 602, title: "已经做完", completed: true }
        ])
        clickSidebar("周", "week")
        var view = weekView()
        findChild(mainWindow, "weekScroll").forceActiveFocus()

        view.setCursor(602)
        keyClick(Qt.Key_Return)
        wait(40)
        compare(focusTimer.startFocusCalls + focusTimer.startPomodoroCalls, 0)
        // 行内「开始」按钮对同一条也不出现：两边读的是同一个条件。
        compare(taskRow(602).showStartFocus && !taskRow(602).visualTaskCompleted, false)
        compare(view.canStartFocusFor(602), false)

        view.setCursor(601)
        compare(view.canStartFocusFor(601), true)
        compare(taskRow(601).showStartFocus && !taskRow(601).visualTaskCompleted, true)
    }

    function test_returnRightAfterCompletingDoesNotStart() {
        // 空格完成后，列表要等完成动画结束才重载；这段时间里模型里的 completed 还是旧值，
        // 行内「开始」按钮却已经随完成态隐藏。回车必须与按钮同口径，不能趁这个窗口启动。
        clickSidebar("周", "week")
        var view = weekView()
        findChild(mainWindow, "weekScroll").forceActiveFocus()
        view.setCursor(501)

        keyClick(Qt.Key_Space)
        compare(taskManager.setCompletedCalls, 1)
        keyClick(Qt.Key_Return)
        wait(40)

        compare(focusTimer.startFocusCalls + focusTimer.startPomodoroCalls, 0)
        compare(view.canStartFocusFor(501), false)
    }

    function test_rowTapHandlerDoesNotStealDrag() {
        // 点行交接焦点用的 TapHandler 与任务行自带的 DragHandler 挂在同一个元素上。
        // 按住拖动必须仍然由 DragHandler 接管，拖完也不能被当成一次点击去改游标。
        clickSidebar("周", "week")
        var view = weekView()
        var row = taskRow(502)
        var sawDrag = false

        mousePress(row, 60, row.height / 2)
        for (var i = 1; i <= 12; ++i) {
            mouseMove(row, 60, row.height / 2 + i * 6)
            wait(16)
            if (view.draggingTaskId === 502)
                sawDrag = true
        }
        mouseRelease(row, 60, row.height / 2 + 72)
        wait(60)

        verify(sawDrag, "按住拖动没有进入拖动态")
        compare(view.cursorTaskId, -1)
    }
}
