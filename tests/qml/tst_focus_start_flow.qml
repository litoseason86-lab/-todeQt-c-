pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import "../../qml"

TestCase {
    id: testCase
    name: "FocusStartFlow"
    when: windowShown
    width: 960
    height: 640

    QtObject {
        id: taskManager

        signal tasksChanged

        property int deleteTaskCalls: 0
        property int lastDeletedTaskId: -1
        property bool deleteSucceeds: true

        function getTodayTasks() { return [] }
        function getWeekTasks(weekStart) { return [] }
        function getMonthTasks(year, month) { return [] }
        function addTask(title, date, categoryId) {}
        function setTaskCompleted(id, completed) {}
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
        function pauseFocus() {}
        function resumeFocus() { return true }

        function stopFocus() {
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
    }

    function init() {
        mainWindow.currentView = "today"
        mainWindow.pendingView = "today"
        mainWindow.queuedView = ""
        mainWindow.isSwitching = false
        focusTimer.startFocusCalls = 0
        focusTimer.startFocusTaskId = 0
        focusTimer.startFocusTaskTitle = ""
        focusTimer.currentTaskId = -1
        focusTimer.currentTaskTitle = ""
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
        focusTimer.mode = 0
        focusTimer.phase = 0
        appSettings.lastMode = 0
        taskManager.deleteTaskCalls = 0
        taskManager.lastDeletedTaskId = -1
        taskManager.deleteSucceeds = true
        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        findChild(focusView, "focusSwitchDialog").close()
        focusTimer.stopSucceeds = true
        focusTimer.startPomodoroCalls = 0
        focusView.toPomodoroTab(false)
        focusView.clearSelectedTask()
        mainWindow.cancelPendingDelete()
        wait(20)
    }

    function test_freeModeStartsImmediately() {
        appSettings.lastMode = 0

        mainWindow.startFocusForTask(7, "自由任务")
        wait(20)

        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        compare(focusTimer.startFocusCalls, 1)
        compare(focusView.selectedTaskId, 7)
        compare(focusView.selectedTaskTitle, "自由任务")
        compare(focusView.taskTitle(), "自由任务")
        var startButton = findChild(focusView, "freeStartButton")
        verify(startButton)
        compare(startButton.visible, false)
        compare(mainWindow.pendingView, "focus")
    }

    function test_freeStartReplacesStalePomodoroTaskState() {
        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)

        // 用户上次停留在番茄页，但持久化模式仍是自由专注时，两个状态源会发生漂移。
        focusView.pomodoroModeSelected = true
        focusView.selectedTaskId = 7
        focusView.selectedTaskTitle = "旧任务"
        appSettings.lastMode = 0

        mainWindow.startFocusForTask(12, "操作系统")
        wait(20)

        compare(focusTimer.startFocusCalls, 1)
        compare(focusView.pomodoroModeSelected, false)
        compare(focusView.selectedTaskId, 12)
        compare(focusView.selectedTaskTitle, "操作系统")
        compare(focusView.taskTitle(), "操作系统")

        var startButton = findChild(focusView, "freeStartButton")
        verify(startButton)
        wait(20)
        compare(focusTimer.startFocusTaskId, 12)
        compare(focusTimer.startFocusTaskTitle, "操作系统")
        compare(focusView.pomodoroModeSelected, false)
        compare(focusView.taskTitle(), "操作系统")
        compare(mainWindow.pendingView, "focus")
    }

    function test_pomodoroModeStartsImmediately() {
        appSettings.lastMode = 1

        mainWindow.startFocusForTask(9, "番茄任务")
        wait(20)

        compare(focusTimer.startPomodoroCalls, 1)
        compare(focusTimer.phase, 1)
        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        compare(focusView.pomodoroModeSelected, true)
        compare(focusView.selectedTaskId, 9)
        compare(focusView.selectedTaskTitle, "番茄任务")
        compare(mainWindow.pendingView, "focus")
    }

    function test_conflictNavigatesWithoutStarting() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        focusTimer.currentTaskId = 4
        focusTimer.currentTaskTitle = "正在专注的任务"
        focusTimer.mode = 0
        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        focusView.pomodoroModeSelected = true
        focusView.selectedTaskId = 7
        focusView.selectedTaskTitle = "旧番茄任务"

        mainWindow.startFocusForTask(11, "第二个任务")

        compare(focusTimer.startFocusCalls, 0)
        compare(focusView.pomodoroModeSelected, false)
        compare(focusView.taskTitle(), "正在专注的任务")
        compare(mainWindow.pendingView, "focus")
    }

    function test_repeatedStartDoesNotCreateSecondSession() {
        appSettings.lastMode = 0
        mainWindow.startFocusForTask(7, "自由任务")
        mainWindow.startFocusForTask(7, "自由任务")
        compare(focusTimer.startFocusCalls, 1)
        compare(appSettings.lastMode, 0)
    }

    function test_switchFailureKeepsOriginalTimer() {
        mainWindow.startFocusForTask(7, "原任务")
        focusTimer.stopSucceeds = false
        mainWindow.startFocusForTask(8, "新任务")
        var view = findChild(mainWindow, "focusViewPage")
        findChild(view, "focusSwitchDialog").accept()
        compare(focusTimer.currentTaskId, 7)
        compare(focusTimer.startFocusCalls, 1)
        verify(view.errorText.length > 0)
    }

    function test_switchStartsNewTaskAfterConfirmation() {
        mainWindow.startFocusForTask(7, "原任务")
        mainWindow.startFocusForTask(8, "新任务")
        compare(focusTimer.currentTaskId, 7)
        findChild(mainWindow, "focusSwitchDialog").accept()
        compare(focusTimer.currentTaskId, 8)
        compare(focusTimer.startFocusCalls, 2)
    }

    function test_modeSwitchWithoutTaskStillEndsCurrentTimer() {
        mainWindow.startFocusForTask(7, "原任务")
        var view = findChild(mainWindow, "focusViewPage")
        // 活动任务被删除后计时器会解绑任务 ID；此时切模式不能变成点了没反应。
        focusTimer.currentTaskId = -1
        focusTimer.currentTaskTitle = ""
        view.clearSelectedTask()
        view.requestModeSwitch(true)
        compare(view.pomodoroModeSelected, true)
        compare(focusTimer.hasActiveSession, false)
    }

    function test_windowTitleReflectsTimerState() {
        compare(mainWindow.windowTitleText, "番茄Todo")

        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        focusTimer.mode = 1
        focusTimer.phase = 1
        focusTimer.remainingSeconds = 932
        compare(mainWindow.windowTitleText, "15:32 · 番茄Todo")

        focusTimer.isRunning = false
        compare(mainWindow.windowTitleText, "⏸ 15:32 · 番茄Todo")

        focusTimer.mode = 0
        focusTimer.phase = 0
        focusTimer.elapsedSeconds = 1934
        focusTimer.isRunning = true
        compare(mainWindow.windowTitleText, "00:32:14 · 番茄Todo")
    }

    function test_toastShowsAndAutoHides() {
        var toast = findChild(mainWindow, "globalToast")
        verify(toast)
        toast.displayDurationMs = 60

        mainWindow.showToast("测试提示")
        compare(toast.shown, true)
        compare(toast.yOffset, 0)
        var moveAnimation = findChild(mainWindow, "toastMoveAnimation")
        verify(moveAnimation)
        compare(moveAnimation.duration <= 200, true)
        var label = findChild(mainWindow, "toastText")
        verify(label)
        compare(label.text, "测试提示")

        tryCompare(toast, "shown", false, 2000)
        verify(toast.yOffset > 0)
        compare(toast.actionText, "")
        compare(toast.actionCallback, null)
        toast.displayDurationMs = 3000
    }

    function test_sessionDiscardedShowsToast() {
        var toast = findChild(mainWindow, "globalToast")
        verify(toast)

        focusTimer.sessionDiscarded(60)
        wait(20)

        compare(toast.shown, true)
        var label = findChild(mainWindow, "toastText")
        compare(label.text, "本次专注不足 3 分钟，未计入记录")
    }

    function test_cancelSwitchLeavesTimerRunning() {
        mainWindow.startFocusForTask(7, "原任务")
        mainWindow.startFocusForTask(11, "第二个任务")
        var dialog = findChild(mainWindow, "focusSwitchDialog")
        verify(dialog.visible)
        dialog.reject()
        compare(focusTimer.currentTaskId, 7)
        compare(focusTimer.hasActiveSession, true)
        compare(focusTimer.startFocusCalls, 1)
    }

    function test_toastActionShowsAndFires() {
        var toast = findChild(mainWindow, "globalToast")
        verify(toast)
        var fired = false

        mainWindow.showToast("已删除「测试」", "撤销", function () { fired = true })
        compare(toast.shown, true)
        compare(toast.actionText, "撤销")

        toast.triggerAction()
        compare(fired, true)
        compare(toast.shown, false)
    }

    function test_toastWithoutActionKeepsOldBehavior() {
        var toast = findChild(mainWindow, "globalToast")
        verify(toast)

        mainWindow.showToast("普通提示")
        compare(toast.shown, true)
        compare(toast.actionText, "")
    }

    function test_sessionDeleteCanUndoAndFailureRestoresState() {
        historyService.deletedId = -1
        historyService.succeeds = true
        mainWindow.requestDeleteSession(12, "数学")
        compare(historyService.deletedId, -1)
        findChild(mainWindow, "globalToast").triggerAction()
        compare(mainWindow.pendingDeleteSessionId, -1)
        compare(historyService.deletedId, -1)
        mainWindow.requestDeleteSession(12, "数学")
        mainWindow.requestDeleteTask(30, "下一条")
        compare(historyService.deletedId, 12)
        mainWindow.cancelPendingDelete()
        historyService.succeeds = false
        mainWindow.requestDeleteSession(13, "失败记录")
        verify(!mainWindow.commitPendingDelete())
        compare(mainWindow.pendingDeleteSessionId, -1)
        historyService.succeeds = true
    }

    function test_deleteIsDeferredAndUndoable() {
        mainWindow.deleteCommitDelayMs = 60

        mainWindow.requestDeleteTask(21, "误删任务")
        compare(mainWindow.pendingDeleteTaskId, 21)
        compare(taskManager.deleteTaskCalls, 0)

        var toast = findChild(mainWindow, "globalToast")
        verify(toast)
        compare(toast.shown, true)
        compare(toast.actionText, "撤销")

        toast.triggerAction()
        compare(mainWindow.pendingDeleteTaskId, -1)
        wait(120)
        compare(taskManager.deleteTaskCalls, 0)

        mainWindow.deleteCommitDelayMs = 5000
    }

    function test_deleteCommitsAfterTimeout() {
        mainWindow.deleteCommitDelayMs = 60

        mainWindow.requestDeleteTask(22, "真删任务")
        tryCompare(taskManager, "deleteTaskCalls", 1, 2000)
        compare(taskManager.lastDeletedTaskId, 22)
        compare(mainWindow.pendingDeleteTaskId, -1)

        mainWindow.deleteCommitDelayMs = 5000
    }

    function test_secondDeleteCommitsFirstImmediately() {
        mainWindow.deleteCommitDelayMs = 5000

        mainWindow.requestDeleteTask(23, "第一个")
        mainWindow.requestDeleteTask(24, "第二个")

        compare(taskManager.deleteTaskCalls, 1)
        compare(taskManager.lastDeletedTaskId, 23)
        compare(mainWindow.pendingDeleteTaskId, 24)

        mainWindow.cancelPendingDelete()
    }

    function test_deleteFailureRestoresHiddenTaskAndReportsError() {
        taskManager.deleteSucceeds = false
        mainWindow.requestDeleteTask(25, "删除失败任务")

        compare(mainWindow.commitPendingDelete(), false)
        compare(mainWindow.pendingDeleteTaskId, -1)
        var toast = findChild(mainWindow, "globalToast")
        verify(toast)
        var toastText = findChild(toast, "toastText")
        verify(toastText)
        verify(toastText.text.indexOf("失败") >= 0)
    }
}
