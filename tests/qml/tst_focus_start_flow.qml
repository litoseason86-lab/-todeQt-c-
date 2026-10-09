pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
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

        // 选择器的候选来源。用例按需替换，默认空——保持原有用例的行为不变。
        property var todayTasks: []
        // getTask 查询全库，不能把“移出今天”伪装成“任务已删除”。
        property var otherDateTasks: []
        property int maxTitleLength: 100
        property int createTaskCalls: 0
        property string createTaskTitle: ""
        property string createTaskDate: ""
        // createTask 要返回的新任务编号；<= 0 表示新建失败。
        property int createTaskResultId: 901

        function getTodayTasks() { return todayTasks }
        function getWeekTasks(weekStart) { return [] }
        function getMonthTasks(year, month) { return [] }
        function getTask(id) {
            for (var task of todayTasks.concat(otherDateTasks)) {
                if (Number(task.id) === Number(id))
                    return task
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
        property int setCompletedCalls: 0
        property int lastSetCompletedId: -1
        property var lastSetCompletedValue: undefined
        // 与 TaskManager::setTaskCompleted 同契约：成功返回 true。完成用例要走到页面的成功分支。
        function setTaskCompleted(id, completed) {
            setCompletedCalls += 1
            lastSetCompletedId = id
            lastSetCompletedValue = completed
            return true
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
        // 模拟不足 3 分钟：真实 FocusTimer 会丢弃这段会话、照常返回成功，并同步发 sessionDiscarded。
        property bool stopDiscards: false
        // 服务端对已删除任务会插入 0 行而失败；用例按需置假模拟。
        property bool startFocusSucceeds: true
        property int pauseFocusCalls: 0
        property int stopFocusCalls: 0
        property int startPomodoroCalls: 0
        property int startFocusCalls: 0
        property int startFocusTaskId: 0
        property string startFocusTaskTitle: ""
        property int lastWorkSeconds: 0

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
            lastWorkSeconds = workSeconds
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
            if (stopDiscards)
                sessionDiscarded(elapsedSeconds)
            return true
        }
    }

    // 专注计时控制器（FocusSessionController）的替身，接口同 C++，同步返回、记录调用。
    // 结束的分发、超长阈值、失败文案、连续计数归零由 tests/FocusSessionControllerTests.cpp 保证；
    // 本文件只验证 MainWindow / FocusView 把什么交给了控制器、按返回结果做了什么界面动作。
    // 替身会照常推动 focusTimer 替身的状态，让页面的状态同步继续运行。
    QtObject {
        id: focusSessionController

        property bool needsConfirmation: false
        property int warningHours: 8
        // 非空时 endCurrent 原样返回它，不碰计时器替身。
        property var endOutcome: null
        property int endCurrentCalls: 0
        property var finishCalls: []

        function freeTimerWarningHours() { return warningHours }
        // 长休息与自动衔接的判定表在 C++（FocusSessionControllerTests），替身照同一口径读设置与计时器替身。
        function nextBreakMinutes(selected) {
            var interval = appSettings.longBreakInterval
            var done = focusTimer.completedPomodoros
            return appSettings.longBreakEnabled && interval > 0 && done > 0 && done % interval === 0
                    ? appSettings.longBreakMinutes : selected
        }
        function autoAdvanceAfter(phase) {
            return (phase === 1 && appSettings.autoStartBreak) || (phase === 2 && appSettings.autoStartNextPomodoro)
        }
        function needsLongFreeStopConfirmation() { return needsConfirmation }

        function endCurrent() {
            endCurrentCalls += 1
            if (endOutcome)
                return endOutcome
            if (!focusTimer.hasActiveSession && focusTimer.phase === 0)
                return { result: "none", kind: "", discarded: false, error: "" }
            var kind = (focusTimer.mode === 2 && focusTimer.phase === 3) ? "manualRest"
                     : focusTimer.mode === 1 ? "pomodoro" : "free"
            if (kind === "free" && needsConfirmation)
                return { result: "needsConfirmation", kind: kind, discarded: false, error: "" }
            if (!focusTimer.stopFocus())
                return { result: "failed", kind: kind, discarded: false, error: "控制器给的失败文案" }
            return { result: "ended", kind: kind, discarded: focusTimer.stopDiscards, error: "" }
        }

        // 规则 2、6 的接口。默认按与 C++ 相同的判定表从计时器 / 设置替身推出结果（判定表本身由
        // FocusSessionControllerTests 保证），好让下面依赖真实分流的流程用例照常运行；
        // 接线用例设置 *Override 后，替身原样返回，验证页面只听控制器的、不自己再判断。
        property var planOverride: null
        property var consequenceOverride: null
        property var stopForSwitchOverride: null
        property var modeSwitchOverride: null
        property var planCalls: []
        property var stopForSwitchCalls: []
        property var modeSwitchCalls: []
        property int captureCalls: 0

        function planTaskEntry(taskId, title) {
            planCalls = planCalls.concat([{ taskId: taskId, title: title }])
            if (planOverride)
                return planOverride
            var trimmed = String(title || "").trim()
            var kind = (taskId <= 0 || trimmed.length === 0) ? "invalid"
                     : (focusTimer.hasActiveSession && focusTimer.currentTaskId === taskId) ? "returnToCurrent"
                     : (focusTimer.hasActiveSession || focusTimer.phase !== 0) ? "confirmSwitch" : "apply"
            return { kind: kind, usePomodoro: appSettings.lastMode === 1,
                     autoStart: appSettings.quickStartEnabled, title: trimmed }
        }

        // 注意：确认框文案是绑定，会反复调用这里，替身不能在其中写属性（会触发 Binding loop）。
        function switchConsequence() {
            if (consequenceOverride)
                return consequenceOverride
            var kind = (focusTimer.phase === 2 || focusTimer.phase === 3) ? "restKept"
                     : focusTimer.elapsedSeconds < focusTimer.minimumValidMinutes * 60 ? "notSaved" : "saved"
            return { kind: kind, minimumMinutes: focusTimer.minimumValidMinutes }
        }

        function captureSwitchSource() {
            captureCalls += 1
            return { taskId: focusTimer.currentTaskId, mode: focusTimer.mode, phase: focusTimer.phase }
        }

        function stopForSwitch(source) {
            stopForSwitchCalls = stopForSwitchCalls.concat([source])
            if (stopForSwitchOverride)
                return stopForSwitchOverride
            if (focusTimer.currentTaskId !== source.taskId || focusTimer.mode !== source.mode
                    || focusTimer.phase !== source.phase)
                return "stateChanged"
            if (needsConfirmation && focusTimer.mode === 0 && focusTimer.hasActiveSession)
                return "needsLongFreeConfirmation"
            return focusTimer.stopFocus() ? "stopped" : "stopFailed"
        }

        function planModeSwitch(selectedTaskId, selectedTitle) {
            modeSwitchCalls = modeSwitchCalls.concat([{ taskId: selectedTaskId, title: selectedTitle }])
            if (modeSwitchOverride)
                return modeSwitchOverride
            var busy = focusTimer.hasActiveSession || focusTimer.phase !== 0
            var taskId = focusTimer.currentTaskId > 0 ? focusTimer.currentTaskId : selectedTaskId
            var title = String(focusTimer.currentTaskTitle || selectedTitle || "").trim()
            return busy && taskId > 0 && title.length > 0
                    ? { kind: "confirmSwitch", taskId: taskId, title: title } : { kind: "pageOnly" }
        }

        // 规则 3：完成任务时是否顺带结束专注。默认按 C++ 的判定（有会话且正是这个任务才结束，其余 none），
        // completedOverride 用于接线用例。
        property var completedOverride: null
        property var completedCalls: []

        function handleTaskCompleted(taskId) {
            completedCalls = completedCalls.concat([taskId])
            if (completedOverride)
                return completedOverride
            if (!focusTimer.hasActiveSession || focusTimer.currentTaskId !== taskId)
                return { focusResult: "none", kind: "", discarded: false, error: "" }
            var r = endCurrent()
            return { focusResult: r.result, kind: r.kind, discarded: r.discarded, error: r.error }
        }

        // 规则 5、8。默认同样按 C++ 的判定从 taskManager / pendingDeletion 替身推出，*Override 用于接线用例。
        property var candidateOverride: null
        property var createTodayOverride: null
        property var candidateCalls: []
        property var createTodayCalls: []

        function autoStartCandidate(selectedTaskId, selectedTitle) {
            candidateCalls = candidateCalls.concat([{ taskId: selectedTaskId, title: selectedTitle }])
            if (candidateOverride)
                return candidateOverride
            var title = String(selectedTitle || "").trim()
            var stale = false
            if (selectedTaskId > 0 && title.length > 0) {
                var found = taskManager.getTask(selectedTaskId)
                if (Number(found.id) === selectedTaskId)
                    return { id: selectedTaskId, title: title, selectionStale: false }
                stale = true
            }
            var tasks = taskManager.getTodayTasks()
            for (var i = 0; i < tasks.length; ++i) {
                if (!tasks[i].completed && Number(tasks[i].id) !== pendingDeletion.taskId)
                    return { id: Number(tasks[i].id), title: String(tasks[i].title), selectionStale: stale }
            }
            return { id: -1, title: "", selectionStale: stale }
        }

        function createTodayTask(title) {
            createTodayCalls = createTodayCalls.concat([title])
            if (createTodayOverride !== null)
                return createTodayOverride
            var trimmed = String(title || "").trim()
            if (trimmed.length === 0)
                return -1
            // 日期（逻辑今日）是 C++ 的事，这里只给个占位串。
            return taskManager.createTask(trimmed, "2000-01-01", -1, 0, "")
        }

        // 番茄页的结束：与 C++ 一致，空档里的 none 转成 ended/pomodoro。
        function endPomodoroCycle() {
            var r = endCurrent()
            if (r.result === "none")
                return { result: "ended", kind: "pomodoro", discarded: false, error: "" }
            return r
        }

        function finishLongFree(recordSession, correctedSeconds) {
            finishCalls = finishCalls.concat([{ record: recordSession, seconds: correctedSeconds }])
            if (recordSession)
                focusTimer.stopFocus()
            return { ok: true, error: "" }
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
        // 本文件多数用例验证的是「点了就开始」那条路径，替身默认开启快速开始；
        // 关闭时的待机路径由专门的用例显式关掉再测。
        property bool quickStartEnabled: true
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

        // 复盘接口是统计页契约的一部分，替身必须提供；这里返回没有可展示内容的成功结果。
        function getWeeklyReview(weekStart, logicalTodayIso) {
            return { loadState: "ready", periodState: "current", hasData: false, hasDisplayContent: false,
                     goal: ({}), todayGoal: ({}), subjects: [], plannedTasks: ({}), facts: [] }
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
        id: backupService

        signal restoreStarted()
        signal backupInfoReady(string sourcePath, var info)

        // 与 BackupService 同名：备份/恢复临界区期间为真，界面整体阻断输入。
        property bool operationBlocksUi: false
        property string operationText: ""
    }

    QtObject {
        id: historyService

        // 主窗口也挂载月历；取档走真实服务，避免桩缺方法被运行时门禁拦截。
        function bandForMinutes(minutes) { return historyCalibers.bandForMinutes(minutes) }
        function getDayTimeline() { return [] }
        function getMonthSessions() { return [] }
        function lastError() { return "" }
    }
    // 设备间同步的替身：主窗口只接它的提示、日志入口和「开没开」。
    QtObject {
        id: syncController

        property bool enabled: false
        property string statusKey: "stopped"
        property bool hasProblem: false
        property string summaryText: ""
        property string statusText: ""
        property string statusDetail: ""
        property int pendingCount: 0
        property bool busy: false
        property bool choosesFolder: false
        property bool hasFolder: true
        property string folderDisplayPath: ""
        property bool choosingFolder: false
        property string folderProblem: ""
        property int logRevision: 0
        property int logCount: 0
        // 恢复确认框里的提醒，由测试决定这一次控制器给什么。
        property string restoreWarningText: ""

        signal notice(string message)
        signal logChanged()

        function syncLog(limit) { return [] }
        function restoreWarning() { return restoreWarningText }
    }

    // 单槽撤销删除（PendingDeletion）的替身：属性与信号同 C++，行为同步模拟。
    // 计时、真正删库、被别处删掉时退场等业务由 PendingDeletionTests 负责，这里只测 MainWindow 的接线。
    QtObject {
        id: pendingDeletion

        property int taskId: -1
        property int sessionId: -1
        property bool sessionIsRest: false
        property string title: ""
        readonly property bool active: taskId > 0 || sessionId > 0
        property int delayMs: 5000
        property bool commitSucceeds: true

        property int requestTaskCalls: 0
        property int lastTaskId: -1
        property string lastTaskTitle: ""
        property int requestSessionCalls: 0
        property int lastSessionId: -1
        property string lastSessionTitle: ""
        property bool lastSessionIsRest: false
        property int commitCalls: 0
        property int cancelCalls: 0

        signal changed()
        signal retired()
        signal commitFailed(string failedTitle)

        function clearSlot() {
            taskId = -1
            sessionId = -1
            sessionIsRest = false
            title = ""
        }
        function resetForTest() {
            clearSlot()
            commitSucceeds = true
            delayMs = 5000
            requestTaskCalls = 0; lastTaskId = -1; lastTaskTitle = ""
            requestSessionCalls = 0; lastSessionId = -1; lastSessionTitle = ""; lastSessionIsRest = false
            commitCalls = 0
            cancelCalls = 0
        }
        function requestTask(id, titleText) {
            requestTaskCalls += 1
            lastTaskId = id
            lastTaskTitle = titleText
            if (id <= 0)
                return false
            if (active && !commit())
                return false
            taskId = id
            sessionId = -1
            sessionIsRest = false
            title = titleText
            changed()
            return true
        }
        function requestSession(id, titleText, isRest) {
            requestSessionCalls += 1
            lastSessionId = id
            lastSessionTitle = titleText
            lastSessionIsRest = isRest
            if (id <= 0)
                return false
            if (active && !commit())
                return false
            taskId = -1
            sessionId = id
            sessionIsRest = isRest
            title = titleText
            changed()
            return true
        }
        function commit() {
            commitCalls += 1
            if (!active)
                return true
            retired()
            var failedTitle = title
            clearSlot()
            changed()
            if (!commitSucceeds) {
                commitFailed(failedTitle)
                return false
            }
            return true
        }
        function cancel() {
            cancelCalls += 1
            if (!active)
                return
            clearSlot()
            changed()
        }
        // 模拟「待删任务被别处先删掉」：撤销窗口失效，槽清空。
        function retireElsewhere() {
            retired()
            clearSlot()
            changed()
        }
    }

    // 交互协调器替身：只记 MainWindow 同步过来的待删任务编号。
    QtObject {
        id: interactionCoordinator

        property int pendingDeleteReports: 0
        property int lastPendingDeleteId: -1

        function setPendingDelete(owner, id) {
            pendingDeleteReports += 1
            lastPendingDeleteId = id
        }
        function end(owner) {}
    }

    MainWindow {
        id: mainWindow
        pendingDeletionRef: pendingDeletion
        focusSessionControllerRef: focusSessionController
        interactionCoordinatorRef: interactionCoordinator

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
        backupServiceRef: backupService
        syncControllerRef: syncController
    }

    SignalSpy {
        id: activationSpy

        target: mainWindow
        signalName: "windowActivationRequested"
    }

    function init() {
        // 上一用例可能刚触发切页动画，先等它收尾再重置状态，防止延迟 ScriptAction 串入下一用例。
        tryCompare(mainWindow, "isSwitching", false, 2000)
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
        appSettings.quickStartEnabled = true
        appSettings.workMinutes = 25
        // 复位写在 init 而不是用例末尾：断言一失败就跳过还原的话，
        // 一条真实失败会污染后面每一条（docs/业务规则.md「界面与验证约定」记过这个坑）。
        taskManager.otherDateTasks = []
        taskManager.todayTasks = []
        taskManager.createTaskCalls = 0
        taskManager.createTaskTitle = ""
        taskManager.createTaskDate = ""
        taskManager.createTaskResultId = 901
        knowledgeGapService.captureCalls = 0
        knowledgeGapService.lastTitle = ""
        knowledgeGapService.lastSourceTaskId = -1
        backupService.operationBlocksUi = false
        backupService.operationText = ""
        mainWindow.windowActive = true
        mainWindow.cancelPendingGapCapture()
        mainWindow.gapCaptureRequestTimeoutMs = 3000
        findChild(mainWindow, "settingsDialog").recordingShortcut = false
        findChild(mainWindow, "globalKnowledgeGapCapturePopup").close()
        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        findChild(focusView, "focusSwitchDialog").close()
        // 专注页那个捕获框也要关：一条用例中途失败留下它开着，焦点就一直在弹窗里，
        // 后面每条捕获用例都会被 overlayHoldsFocus 挡住而连带变红。
        findChild(focusView, "knowledgeGapCapturePopup").close()
        // 选择器同理：「…OpensPicker」几条用例展开它后不收起，用例按名字字母序跑，
        // 留着它开着，后面的捕获用例会被 overlayHoldsFocus 挡住。
        findChild(focusView, "focusTaskPicker").collapse()
        focusTimer.stopSucceeds = true
        focusTimer.stopDiscards = false
        taskManager.setCompletedCalls = 0
        taskManager.lastSetCompletedId = -1
        taskManager.lastSetCompletedValue = undefined
        focusTimer.startFocusSucceeds = true
        focusTimer.pauseFocusCalls = 0
        focusTimer.stopFocusCalls = 0
        focusTimer.startPomodoroCalls = 0
        focusTimer.lastWorkSeconds = 0
        focusTimer.elapsedSeconds = 0
        focusTimer.completedPomodoros = 0
        focusSessionController.needsConfirmation = false
        focusSessionController.warningHours = 8
        focusSessionController.endOutcome = null
        focusSessionController.endCurrentCalls = 0
        focusSessionController.finishCalls = []
        focusSessionController.planOverride = null
        focusSessionController.consequenceOverride = null
        focusSessionController.stopForSwitchOverride = null
        focusSessionController.modeSwitchOverride = null
        focusSessionController.planCalls = []
        focusSessionController.completedOverride = null
        focusSessionController.completedCalls = []
        focusSessionController.candidateOverride = null
        focusSessionController.createTodayOverride = null
        focusSessionController.candidateCalls = []
        focusSessionController.createTodayCalls = []
        focusSessionController.stopForSwitchCalls = []
        focusSessionController.modeSwitchCalls = []
        focusSessionController.captureCalls = 0
        findChild(focusView, "longFreeFocusConfirmDialog").close()
        focusView.toPomodoroTab(false)
        focusView.clearSelectedTask()
        mainWindow.cancelPendingDelete()
        pendingDeletion.resetForTest()
        interactionCoordinator.pendingDeleteReports = 0
        interactionCoordinator.lastPendingDeleteId = -1
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

    // ===== 规则 2、6 的接线用例（判定表在 C++ FocusSessionControllerTests）=====
    // 这些用例让替身返回与计时器实际状态不一致的结果，证明页面只听控制器的。

    function test_taskEntryUsesControllerPlanForModeAndAutoStart() {
        // 接线：MainWindow.startFocusForTask 把任务交给 planTaskEntry，用返回的 usePomodoro / autoStart 分流，
        // 而不是读设置：设置里记着自由 + 快速开始，替身却说「番茄 + 不自动开始」。
        appSettings.lastMode = 0
        appSettings.quickStartEnabled = true
        focusSessionController.planOverride = { kind: "apply", usePomodoro: true, autoStart: false, title: "任务" }

        mainWindow.startFocusForTask(7, "任务")
        wait(20)

        compare(focusSessionController.planCalls.length >= 1, true)
        compare(focusSessionController.planCalls[0].taskId, 7)
        compare(focusTimer.startFocusCalls, 0)
        compare(focusTimer.startPomodoroCalls, 0)
        var view = focusPage()
        compare(view.pomodoroModeSelected, true)
        compare(view.selectedTaskId, 7)
        compare(view.panelExpanded, true)
    }

    function test_taskEntryAutoStartFollowsControllerNotSettings() {
        // 对照：设置里快速开始关着，替身说自动开始 + 自由，页面就立即开始自由计时。
        appSettings.quickStartEnabled = false
        appSettings.lastMode = 1
        focusSessionController.planOverride = { kind: "apply", usePomodoro: false, autoStart: true, title: "任务" }

        mainWindow.startFocusForTask(7, "任务")
        wait(20)

        compare(focusTimer.startFocusCalls, 1)
        compare(focusTimer.startPomodoroCalls, 0)
    }

    function test_taskEntryKindDrivesThePageAction() {
        // 接线：openTask 按 kind 分流。同一个空闲计时器，替身依次说 invalid / returnToCurrent / confirmSwitch / apply。
        var view = focusPage()
        view.errorText = ""
        focusSessionController.planOverride = { kind: "invalid", usePomodoro: false, autoStart: true, title: "" }
        compare(view.openTask(7, "任务", false, true), false)
        compare(view.errorText, "任务信息无效，无法开始计时")
        compare(focusTimer.startFocusCalls, 0)

        focusSessionController.planOverride = { kind: "returnToCurrent", usePomodoro: false, autoStart: true, title: "任务" }
        compare(view.openTask(7, "任务", false, true), true)
        compare(focusTimer.startFocusCalls, 0)
        compare(findChild(view, "focusSwitchDialog").opened, false)

        focusSessionController.planOverride = { kind: "confirmSwitch", usePomodoro: false, autoStart: true, title: "任务" }
        compare(view.openTask(7, "任务", false, true), true)
        tryCompare(findChild(view, "focusSwitchDialog"), "opened", true, 2000)
        compare(focusSessionController.captureCalls, 1)
        compare(focusTimer.startFocusCalls, 0)
        findChild(view, "focusSwitchDialog").close()

        focusSessionController.planOverride = { kind: "apply", usePomodoro: false, autoStart: true, title: "任务" }
        compare(view.openTask(7, "任务", false, true), true)
        compare(focusTimer.startFocusCalls, 1)
    }

    function test_switchDialogTextFollowsControllerConsequence() {
        // 接线：确认框的后果文案只由控制器的 kind 决定，页面不再看已用秒数和阶段（计时器替身此刻是 0 秒的专注）。
        var view = focusPage()
        focusSessionController.planOverride = { kind: "confirmSwitch", usePomodoro: false, autoStart: true, title: "新任务" }
        focusSessionController.consequenceOverride = { kind: "restKept", minimumMinutes: 3 }
        view.openTask(8, "新任务", false, true)
        compare(view.switchDialogText().indexOf("当前休息会保留在时间轴中。") >= 0, true)

        focusSessionController.consequenceOverride = { kind: "notSaved", minimumMinutes: 5 }
        compare(view.switchDialogText().indexOf("当前专注不足 5 分钟，不会保存。") >= 0, true)

        focusSessionController.consequenceOverride = { kind: "saved", minimumMinutes: 3 }
        compare(view.switchDialogText().indexOf("当前专注会先保存。") >= 0, true)
        findChild(view, "focusSwitchDialog").close()
    }

    function test_confirmSwitchFollowsStopForSwitchResult() {
        // 接线：确认时页面把打开确认框时记下的来源交给 stopForSwitch，再按四种返回做界面动作。
        var view = focusPage()
        mainWindow.startFocusForTask(7, "原任务")
        var dialog = findChild(view, "focusSwitchDialog")

        focusSessionController.stopForSwitchOverride = "stateChanged"
        mainWindow.startFocusForTask(8, "新任务")
        dialog.accept()
        compare(view.errorText, "计时状态已变化，请重新选择任务")
        compare(focusTimer.currentTaskId, 7)
        compare(focusSessionController.stopForSwitchCalls.length, 1)
        compare(focusSessionController.stopForSwitchCalls[0].taskId, 7)

        focusSessionController.stopForSwitchOverride = "stopFailed"
        mainWindow.startFocusForTask(8, "新任务")
        dialog.accept()
        compare(view.errorText, "当前计时保存失败，未切换")
        compare(focusTimer.currentTaskId, 7)

        focusSessionController.stopForSwitchOverride = "needsLongFreeConfirmation"
        mainWindow.startFocusForTask(8, "新任务")
        dialog.accept()
        tryCompare(findChild(view, "longFreeFocusConfirmDialog"), "opened", true, 2000)
        compare(focusTimer.currentTaskId, 7)
        findChild(view, "longFreeFocusConfirmDialog").close()

        // stopped：替身只返回结果，计时器替身要自己停；页面接着落到新任务。
        focusSessionController.stopForSwitchOverride = "stopped"
        mainWindow.startFocusForTask(8, "新任务")
        focusTimer.stopFocus()
        dialog.accept()
        compare(focusTimer.currentTaskId, 8)
    }

    function test_modeSwitchFollowsControllerPlan() {
        // 接线：切页签时页面把选中项交给 planModeSwitch；confirmSwitch 才弹确认框并带上控制器给的任务，pageOnly 只换页签。
        mainWindow.startFocusForTask(7, "原任务")
        var view = focusPage()
        view.selectedTaskId = 7
        view.selectedTaskTitle = "原任务"

        focusSessionController.modeSwitchOverride = { kind: "pageOnly" }
        view.requestModeSwitch(true)
        compare(focusSessionController.modeSwitchCalls.length, 1)
        compare(focusSessionController.modeSwitchCalls[0].taskId, 7)
        compare(findChild(view, "focusSwitchDialog").opened, false)
        compare(view.pomodoroModeSelected, true)
        view.toPomodoroTab(false)

        focusSessionController.modeSwitchOverride = { kind: "confirmSwitch", taskId: 55, title: "控制器选的任务" }
        view.requestModeSwitch(true)
        tryCompare(findChild(view, "focusSwitchDialog"), "opened", true, 2000)
        compare(view.pendingSwitch.taskId, 55)
        compare(view.pendingSwitch.title, "控制器选的任务")
        compare(view.pendingSwitch.autoStart, false)
        findChild(view, "focusSwitchDialog").close()

        // 要切的就是当前页签：页面状态，根本不问控制器。
        var before = focusSessionController.modeSwitchCalls.length
        view.requestModeSwitch(view.pomodoroModeSelected)
        compare(focusSessionController.modeSwitchCalls.length, before)
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

    // —— 快速开始关闭（默认）：任务入口只进入待机，用户确认模式和时长后再开始 ——

    function test_quickStartOffEntersFreeStandbyWithoutStarting() {
        appSettings.quickStartEnabled = false
        appSettings.lastMode = 0

        mainWindow.startFocusForTask(7, "自由任务")

        var view = findChild(mainWindow, "focusViewPage")
        compare(mainWindow.pendingView, "focus")
        compare(focusTimer.startFocusCalls, 0)
        compare(focusTimer.hasActiveSession, false)
        compare(view.state, "free")
        compare(view.selectedTaskId, 7)
        compare(view.selectedTaskTitle, "自由任务")
        // 只做准备，不改偏好：上次模式要等真正开始后才记。
        compare(appSettings.lastMode, 0)

        // 待机之后由用户点开始，走的是专注页原有的开始逻辑。
        verify(view.canStartFreeFocus())
        verify(view.startFreeFocus())
        compare(focusTimer.startFocusCalls, 1)
        compare(focusTimer.startFocusTaskId, 7)
    }

    function test_quickStartOffPomodoroOpensDurationPanelAndUsesChosenMinutes() {
        appSettings.quickStartEnabled = false
        appSettings.lastMode = 1

        mainWindow.startFocusForTask(9, "番茄任务")

        var view = findChild(mainWindow, "focusViewPage")
        compare(focusTimer.startPomodoroCalls, 0)
        compare(focusTimer.phase, 0)
        compare(view.state, "pomoIdle")
        compare(view.panelExpanded, true)
        compare(view.selectedTaskId, 9)

        // 待机时调的时长就是本轮实际倒计时。
        view.selectWorkMinutes(40)
        verify(view.startPomodoro())
        compare(focusTimer.startPomodoroCalls, 1)
        compare(focusTimer.lastWorkSeconds, 40 * 60)
        compare(focusTimer.currentTaskId, 9)
    }

    function test_quickStartOffRepeatedClicksDoNotStartAnything() {
        appSettings.quickStartEnabled = false
        mainWindow.startFocusForTask(7, "自由任务")
        mainWindow.startFocusForTask(7, "自由任务")
        mainWindow.startFocusForTask(8, "另一个任务")

        var view = findChild(mainWindow, "focusViewPage")
        compare(focusTimer.startFocusCalls + focusTimer.startPomodoroCalls, 0)
        compare(focusTimer.stopFocusCalls, 0)
        compare(view.selectedTaskId, 8)
        compare(findChild(view, "focusSwitchDialog").visible, false)
    }

    function test_quickStartOffConflictEndsOldTimerThenWaits() {
        mainWindow.startFocusForTask(7, "原任务")
        compare(focusTimer.startFocusCalls, 1)
        appSettings.quickStartEnabled = false

        mainWindow.startFocusForTask(8, "新任务")

        var view = findChild(mainWindow, "focusViewPage")
        var dialog = findChild(view, "focusSwitchDialog")
        tryCompare(dialog, "opened", true, 2000)
        compare(dialog.standardButton(Dialog.Ok).text, "结束并切换")
        verify(view.switchDialogText().indexOf("不会自动开始") >= 0)
        // 确认之前旧计时原封不动。
        compare(focusTimer.stopFocusCalls, 0)

        dialog.accept()

        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.startFocusCalls, 1)
        compare(focusTimer.hasActiveSession, false)
        compare(view.selectedTaskId, 8)
        compare(view.selectedTaskTitle, "新任务")
        compare(view.state, "free")
    }

    function test_quickStartOnConflictStillAsksAndSaysStart() {
        mainWindow.startFocusForTask(7, "原任务")
        mainWindow.startFocusForTask(8, "新任务")

        var view = findChild(mainWindow, "focusViewPage")
        var dialog = findChild(view, "focusSwitchDialog")
        tryCompare(dialog, "opened", true, 2000)
        // 快速开始也不能绕过「结束当前计时」的确认。
        compare(dialog.standardButton(Dialog.Ok).text, "结束并开始")
        compare(focusTimer.stopFocusCalls, 0)
    }

    function test_clickingRunningTaskReturnsToItRegardlessOfRememberedMode() {
        appSettings.lastMode = 0
        mainWindow.startFocusForTask(7, "正在做的")
        // 记住的模式是下一次的偏好，不能拿它去结束正在进行的同一任务。
        appSettings.lastMode = 1

        mainWindow.startFocusForTask(7, "正在做的")
        appSettings.quickStartEnabled = false
        mainWindow.startFocusForTask(7, "正在做的")

        var view = findChild(mainWindow, "focusViewPage")
        compare(findChild(view, "focusSwitchDialog").visible, false)
        compare(focusTimer.stopFocusCalls, 0)
        compare(focusTimer.startPomodoroCalls, 0)
        compare(focusTimer.hasActiveSession, true)
        compare(view.pomodoroModeSelected, false)
    }

    // —— 计时中切换模式：确认结束后停在新模式待机，快速开始开着也不自动开始 ——

    function test_modeSwitchWhileRunningEndsThenWaitsInPomodoroStandby() {
        appSettings.lastMode = 0
        mainWindow.startFocusForTask(7, "原任务")
        var view = findChild(mainWindow, "focusViewPage")

        view.requestModeSwitch(true)

        var dialog = findChild(view, "focusSwitchDialog")
        tryCompare(dialog, "opened", true, 2000)
        compare(dialog.standardButton(Dialog.Ok).text, "结束并切换")
        verify(view.switchDialogText().indexOf("番茄专注") >= 0)
        compare(focusTimer.stopFocusCalls, 0)

        dialog.accept()

        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.startPomodoroCalls, 0)
        compare(focusTimer.hasActiveSession, false)
        compare(view.state, "pomoIdle")
        compare(view.panelExpanded, true)
        compare(view.selectedTaskId, 7)

        view.selectWorkMinutes(50)
        verify(view.startPomodoro())
        compare(focusTimer.lastWorkSeconds, 50 * 60)
        compare(focusTimer.currentTaskId, 7)
    }

    function test_pausedPomodoroSwitchToFreeEndsThenWaits() {
        appSettings.lastMode = 1
        mainWindow.startFocusForTask(9, "番茄任务")
        focusTimer.isRunning = false
        var view = findChild(mainWindow, "focusViewPage")

        view.requestModeSwitch(false)
        var dialog = findChild(view, "focusSwitchDialog")
        tryCompare(dialog, "opened", true, 2000)
        dialog.accept()

        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.startFocusCalls, 0)
        compare(view.state, "free")
        compare(view.selectedTaskId, 9)
        verify(view.canStartFreeFocus())
    }

    function test_breakSwitchToFreeKeepsTaskAndWaits() {
        focusTimer.mode = 1
        focusTimer.phase = 2
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = true
        focusTimer.currentTaskId = 9
        focusTimer.currentTaskTitle = "番茄任务"
        var view = findChild(mainWindow, "focusViewPage")
        view.syncToActiveTimer()
        compare(view.state, "pomoBreak")

        view.requestModeSwitch(false)
        // 休息段不是专注，提示不能说「专注不足 3 分钟」。
        verify(view.switchDialogText().indexOf("休息") >= 0)
        findChild(view, "focusSwitchDialog").accept()

        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.startFocusCalls, 0)
        compare(view.state, "free")
        compare(view.selectedTaskId, 9)
    }

    function test_modeSwitchCancelKeepsTimerAndMode() {
        mainWindow.startFocusForTask(7, "原任务")
        var view = findChild(mainWindow, "focusViewPage")

        view.requestModeSwitch(true)
        findChild(view, "focusSwitchDialog").reject()

        compare(focusTimer.stopFocusCalls, 0)
        compare(focusTimer.hasActiveSession, true)
        compare(focusTimer.mode, 0)
        compare(view.pomodoroModeSelected, false)
    }

    function test_modeSwitchStopFailureKeepsOriginalTimer() {
        mainWindow.startFocusForTask(7, "原任务")
        focusTimer.stopSucceeds = false
        var view = findChild(mainWindow, "focusViewPage")

        view.requestModeSwitch(true)
        findChild(view, "focusSwitchDialog").accept()

        compare(focusTimer.hasActiveSession, true)
        compare(focusTimer.currentTaskId, 7)
        compare(focusTimer.startPomodoroCalls, 0)
        compare(view.pomodoroModeSelected, false)
        verify(view.errorText.length > 0)
    }

    function test_overlongFreeModeSwitchRecordsThenWaits() {
        mainWindow.startFocusForTask(7, "忘了停的任务")
        focusTimer.elapsedSeconds = 9 * 60 * 60
        focusSessionController.needsConfirmation = true
        var view = findChild(mainWindow, "focusViewPage")

        view.requestModeSwitch(true)
        findChild(view, "focusSwitchDialog").accept()
        // 控制器说需要超长确认：先弹确认框，此时还不能结束。
        tryCompare(findChild(view, "longFreeFocusConfirmDialog"), "opened", true, 2000)
        compare(focusTimer.stopFocusCalls, 0)

        view.finishLongFreeAction(true, -1)

        // 接线：「记录」交给控制器收尾，之后才进入番茄待机。
        compare(focusSessionController.finishCalls.length, 1)
        compare(focusSessionController.finishCalls[0].record, true)
        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.startPomodoroCalls, 0)
        compare(view.state, "pomoIdle")
        compare(view.selectedTaskId, 7)
        compare(view.panelExpanded, true)
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

    // 以下删除用例只测 MainWindow 的接线：撤销条、各页拿到的待删编号、对 PendingDeletion 的调用。
    // 计时到点提交、提前提交、被别处删掉时退场、提交失败的业务行为由 PendingDeletionTests 负责。

    function test_sessionDeleteCanUndoAndFailureRestoresState() {
        var toast = findChild(mainWindow, "globalToast")
        verify(mainWindow.requestDeleteSession(12, "数学", false))
        compare(pendingDeletion.lastSessionId, 12)
        compare(pendingDeletion.lastSessionTitle, "数学")
        compare(pendingDeletion.lastSessionIsRest, false)
        compare(mainWindow.pendingDeleteSessionId, 12)
        compare(mainWindow.pendingDeleteIsRest, false)
        compare(toast.actionText, "撤销")
        compare(findChild(toast, "toastText").text, "已删除专注记录「数学」")

        toast.triggerAction()
        compare(pendingDeletion.cancelCalls, 1)
        compare(mainWindow.pendingDeleteSessionId, -1)

        // 休息记录文案；标题缺省时用「专注记录」。
        verify(mainWindow.requestDeleteSession(13, "", true))
        compare(pendingDeletion.lastSessionTitle, "专注记录")
        compare(pendingDeletion.lastSessionIsRest, true)
        compare(mainWindow.pendingDeleteIsRest, true)
        compare(findChild(toast, "toastText").text, "已删除休息记录「专注记录」")
        mainWindow.cancelPendingDelete()

        // 无效编号被替身（同真实类）拒绝：没有撤销条。
        toast.show("占位", "", null)
        verify(!mainWindow.requestDeleteSession(-1, "无效", false))
        compare(findChild(toast, "toastText").text, "占位")
    }

    function test_deleteIsDeferredAndUndoable() {
        verify(mainWindow.requestDeleteTask(21, "误删任务"))
        compare(pendingDeletion.requestTaskCalls, 1)
        compare(pendingDeletion.lastTaskId, 21)
        compare(pendingDeletion.lastTaskTitle, "误删任务")
        compare(mainWindow.pendingDeleteTaskId, 21)
        // 今日专注页的补录候选也要知道待删任务，否则用户能在撤销窗口内选中它去补录。
        compare(findChild(mainWindow, "todayFocusViewPage").pendingDeleteTaskId, 21)
        // 待删任务编号要同步给交互协调器（外部 AI 接入据此回避这条任务）。
        compare(interactionCoordinator.lastPendingDeleteId, 21)

        var toast = findChild(mainWindow, "globalToast")
        verify(toast)
        compare(toast.shown, true)
        compare(toast.actionText, "撤销")

        toast.triggerAction()
        compare(pendingDeletion.cancelCalls, 1)
        compare(mainWindow.pendingDeleteTaskId, -1)
        compare(findChild(mainWindow, "todayFocusViewPage").pendingDeleteTaskId, -1)
        compare(interactionCoordinator.lastPendingDeleteId, -1)
    }

    function test_earlyCommitRetiresTheUndoToast() {
        // 补录或修改记录、备份、恢复、关窗之前都会先提交待删除项。提交之后撤销条若还挂着，
        // 用户点「撤销」时提示条照常消失、看起来像撤销成功，记录其实已经永久删除。
        var toast = findChild(mainWindow, "globalToast")

        mainWindow.requestDeleteTask(26, "提前落库的任务")
        compare(toast.actionText, "撤销")

        verify(mainWindow.commitPendingDelete())
        compare(pendingDeletion.commitCalls, 1)
        compare(toast.actionText, "")
        compare(toast.shown, false)
    }

    function test_earlyCommitLeavesUnrelatedToastAlone() {
        // 只收起属于这次删除的撤销条；提示条已经被别的提示顶掉时不能误关。
        var toast = findChild(mainWindow, "globalToast")

        mainWindow.requestDeleteTask(27, "待删任务")
        // 直接走 globalToast，模拟不经 showToast、不会触发提交的另一条带动作提示。
        toast.show("另一条提示", "查看", function() {})

        verify(mainWindow.commitPendingDelete())
        compare(toast.shown, true)
        compare(toast.actionText, "查看")
    }

    function test_commitDelayFollowsTheWindowSetting() {
        // 撤销窗口时长由主窗口的 deleteCommitDelayMs 决定，同步给 PendingDeletion；到点提交由 PendingDeletionTests 负责。
        mainWindow.deleteCommitDelayMs = 60
        compare(pendingDeletion.delayMs, 60)
        mainWindow.deleteCommitDelayMs = 5000
        compare(pendingDeletion.delayMs, 5000)
    }

    function test_secondDeleteCommitsFirstImmediately() {
        var toast = findChild(mainWindow, "globalToast")

        mainWindow.requestDeleteTask(23, "第一个")
        compare(pendingDeletion.commitCalls, 0)
        compare(toast.shown, true)
        mainWindow.requestDeleteTask(24, "第二个")

        // 第二次请求时替身先提交了第一条：旧撤销条收起，新的撤销条出现。
        compare(pendingDeletion.commitCalls, 1)
        compare(mainWindow.pendingDeleteTaskId, 24)
        compare(toast.shown, true)
        compare(toast.actionText, "撤销")
        compare(findChild(toast, "toastText").text, "已删除「第二个」")

        mainWindow.cancelPendingDelete()
    }

    function test_pendingTaskDeletedElsewhereRetiresUndoSlot() {
        // 待删任务被别的路径先删掉：撤销条要收起，否则用户点「撤销」只会看到提示消失，任务却回不来。
        // 退场本身由 PendingDeletion 判断，这里用替身模拟它发出的 retired 与清槽。
        var toast = findChild(mainWindow, "globalToast")
        verify(toast)

        mainWindow.requestDeleteTask(28, "随例行收回的任务")
        compare(toast.actionText, "撤销")

        pendingDeletion.retireElsewhere()
        compare(mainWindow.pendingDeleteTaskId, -1)
        compare(findChild(mainWindow, "todayFocusViewPage").pendingDeleteTaskId, -1)
        compare(toast.actionText, "")
        compare(toast.shown, false)
    }

    function test_deleteFailureRestoresHiddenTaskAndReportsError() {
        pendingDeletion.commitSucceeds = false
        mainWindow.requestDeleteTask(25, "删除失败任务")

        compare(mainWindow.commitPendingDelete(), false)
        compare(mainWindow.pendingDeleteTaskId, -1)
        var toast = findChild(mainWindow, "globalToast")
        verify(toast)
        var toastText = findChild(toast, "toastText")
        verify(toastText)
        verify(toastText.text.indexOf("失败") >= 0)
        verify(toastText.text.indexOf("删除失败任务") >= 0)
    }

    function test_newToastCommitsThePendingDeletion() {
        // 提示条是单槽：别的提示要顶掉撤销条时先提交，不让看不见的倒计时在背后走完。
        mainWindow.requestDeleteTask(31, "待删任务")
        compare(pendingDeletion.commitCalls, 0)

        mainWindow.showToast("别的提示")
        compare(pendingDeletion.commitCalls, 1)
        compare(mainWindow.pendingDeleteTaskId, -1)
        compare(findChild(findChild(mainWindow, "globalToast"), "toastText").text, "别的提示")
    }

    // —— 专注页任务选择器与 ⌘↩ 的口径 ——
    //
    // 这一组的核心是那条兜底分支：取不到可自动启动的任务时必须展开选择器。
    // 「今日零任务」与「今日任务全部已完成」是两种不同的到达方式，
    // 只测其中一条抓不到另一条——早先的实现正是只处理了前者。

    function focusPage() {
        var view = findChild(mainWindow, "focusViewPage")
        verify(view)
        return view
    }

    function test_shortcutStartsFirstPendingTodayTask() {
        taskManager.todayTasks = [
            { id: 31, title: "高数", completed: false, displayOrder: 1 },
            { id: 32, title: "英语", completed: false, displayOrder: 2 }
        ]
        appSettings.lastMode = 0

        mainWindow.triggerShortcutAction("focus.toggle")
        wait(40)

        compare(focusTimer.startFocusCalls, 1)
        compare(focusTimer.startFocusTaskId, 31)
        compare(focusTimer.startFocusTaskTitle, "高数")
    }

    function test_shortcutSkipsCompletedTasksWhenPicking() {
        // getTodayTasks 的真实顺序是未完成在前；这里刻意把已完成的排在最前面，
        // 确认挑选走的是 completed 判断，而不是「无脑取第 0 条」。
        taskManager.todayTasks = [
            { id: 41, title: "已完成的", completed: true, displayOrder: 1 },
            { id: 42, title: "还没做的", completed: false, displayOrder: 2 }
        ]
        appSettings.lastMode = 0

        mainWindow.triggerShortcutAction("focus.toggle")
        wait(40)

        compare(focusTimer.startFocusCalls, 1)
        compare(focusTimer.startFocusTaskId, 42)
    }

    function test_shortcutPrefersAlreadySelectedTask() {
        taskManager.todayTasks = [
            { id: 51, title: "列表第一条", completed: false, displayOrder: 1 },
            { id: 52, title: "用户点过的", completed: false, displayOrder: 2 }
        ]
        var view = focusPage()
        view.selectedTaskId = 52
        view.selectedTaskTitle = "用户点过的"
        appSettings.lastMode = 0

        mainWindow.triggerShortcutAction("focus.toggle")
        wait(40)

        // 刚在今日页点过某条再按快捷键，不该被换成列表第一条。
        compare(focusTimer.startFocusTaskId, 52)
    }

    function test_shortcutWithNoTodayTasksOpensPicker() {
        taskManager.todayTasks = []
        var view = focusPage()

        mainWindow.triggerShortcutAction("focus.toggle")
        wait(40)

        compare(focusTimer.startFocusCalls, 0)
        compare(focusTimer.startPomodoroCalls, 0)
        var picker = findChild(view, "focusTaskPicker")
        verify(picker)
        // 断言选择器确实展开了，而不是停在一个「按了没反应」的终态。
        compare(picker.expanded, true)
    }

    function test_shortcutWithAllTodayTasksCompletedOpensPicker() {
        // 这条是上一版漏掉的空分支：有任务、但全部已完成。
        // 既取不到未完成任务可自动启动，也不满足「今日零任务」。
        taskManager.todayTasks = [
            { id: 61, title: "上午做完了", completed: true, displayOrder: 1 },
            { id: 62, title: "下午也做完了", completed: true, displayOrder: 2 }
        ]
        var view = focusPage()

        mainWindow.triggerShortcutAction("focus.toggle")
        wait(40)

        compare(focusTimer.startFocusCalls, 0)
        compare(focusTimer.startPomodoroCalls, 0)
        var picker = findChild(view, "focusTaskPicker")
        verify(picker)
        compare(picker.expanded, true)
        // 已完成的任务必须仍然可选——「今天排的都做完了，还想再练一轮」是真实场景。
        compare(picker.candidates.length, 2)
    }

    function test_pickerStartsChosenCompletedTask() {
        taskManager.todayTasks = [
            { id: 71, title: "做完的数学", completed: true, displayOrder: 1 }
        ]
        var view = focusPage()
        appSettings.lastMode = 0
        view.reloadTodayTasks()

        var picker = findChild(view, "focusTaskPicker")
        verify(picker)
        picker.taskChosen(71, "做完的数学")
        compare(view.selectedTaskId, 71)

        compare(view.startCurrentMode(), true)
        compare(focusTimer.startFocusTaskId, 71)
    }

    function test_pickerCreatesTodayTaskAndStarts() {
        taskManager.todayTasks = []
        taskManager.createTaskResultId = 901
        var view = focusPage()
        appSettings.lastMode = 0

        compare(view.createTaskAndStart("临时补一道题"), true)

        compare(taskManager.createTaskCalls, 1)
        compare(taskManager.createTaskTitle, "临时补一道题")
        // 接线：页面把标题交给控制器；建在逻辑今日由控制器保证（C++ createTodayTaskLandsOnLogicalToday…）。
        compare(focusSessionController.createTodayCalls.length, 1)
        compare(focusSessionController.createTodayCalls[0], "临时补一道题")
        compare(focusTimer.startFocusCalls, 1)
        compare(focusTimer.startFocusTaskId, 901)
        compare(focusTimer.startFocusTaskTitle, "临时补一道题")
    }

    function test_createdTaskIdentityComesFromTheServiceNotFromTheTitle() {
        // 身份契约用例：今天已经有一条同名未完成任务，而且 display_order 更大。
        // 计时必须绑到 createTask 返回的那条，不能绑到同名的旧任务上——
        // 「标题 + display_order 最大」不是唯一键，靠它反查会把这段专注记到别人头上，
        // 而且用户看不出来。这里刻意让两者不一致，任何回退到按标题反查的改动都会转红。
        taskManager.todayTasks = [
            { id: 12, title: "同名任务", completed: false, displayOrder: 99 }
        ]
        taskManager.createTaskResultId = 902
        var view = focusPage()
        appSettings.lastMode = 0

        compare(view.createTaskAndStart("同名任务"), true)

        compare(view.selectedTaskId, 902)
        compare(focusTimer.startFocusTaskId, 902)
    }

    function test_createTaskTitleIsTrimmedTheSameWayTheServiceTrimsIt() {
        // 服务端存的是 trim 过的标题；页面显示的当前任务必须是同一个串。
        taskManager.todayTasks = []
        var view = focusPage()
        appSettings.lastMode = 0

        compare(view.createTaskAndStart("  带空格的标题  "), true)

        compare(taskManager.createTaskTitle, "带空格的标题")
        compare(view.selectedTaskTitle, "带空格的标题")
        compare(focusTimer.startFocusTaskTitle, "带空格的标题")
    }

    function test_createTaskFailureDoesNotStartAnything() {
        // createTask 返回 -1：新建失败，或者行写进去了却拿不到编号。
        // 两种情况都不能猜一个编号启动——猜错就是把专注记到别的任务上。
        taskManager.createTaskResultId = -1
        var view = focusPage()

        compare(view.createTaskAndStart("建不出来的任务"), false)

        compare(taskManager.createTaskCalls, 1)
        compare(focusTimer.startFocusCalls, 0)
        compare(focusTimer.startPomodoroCalls, 0)
        verify(view.errorText.length > 0)
    }

    function test_createTaskAndStartUsesTheControllerResultOnly() {
        // 接线（规则 8）：新任务编号以控制器返回为准，页面不再自己调 taskManager.createTask；
        // 返回 -1 报错且不启动。
        var view = focusPage()
        appSettings.lastMode = 0
        focusSessionController.createTodayOverride = 77
        compare(view.createTaskAndStart("  控制器建的  "), true)
        compare(taskManager.createTaskCalls, 0)
        compare(view.selectedTaskId, 77)
        compare(view.selectedTaskTitle, "控制器建的")
        compare(focusTimer.startFocusTaskId, 77)

        focusTimer.stopFocus()
        focusTimer.startFocusCalls = 0
        view.errorText = ""
        focusSessionController.createTodayOverride = -1
        compare(view.createTaskAndStart("失败的"), false)
        compare(view.errorText, "新建任务失败，请重试")
        compare(focusTimer.startFocusCalls, 0)
    }

    function test_shortcutFollowsControllerCandidate() {
        // 接线（规则 5）：快捷键把当前选中项交给控制器，开始的是控制器返回的候选，不是页面自己从今日列表里挑的。
        taskManager.todayTasks = [{ id: 61, title: "页面看得到的第一条", completed: false, displayOrder: 1 }]
        var view = focusPage()
        appSettings.lastMode = 0
        view.selectedTaskId = 61
        view.selectedTaskTitle = "页面看得到的第一条"
        focusSessionController.candidateOverride = { id: 55, title: "控制器选的", selectionStale: false }

        compare(view.startFromShortcut(), true)

        compare(focusSessionController.candidateCalls[0].taskId, 61)
        compare(focusSessionController.candidateCalls[0].title, "页面看得到的第一条")
        compare(focusTimer.startFocusTaskId, 55)
        compare(focusTimer.startFocusTaskTitle, "控制器选的")
    }

    function test_shortcutClearsSelectionWhenControllerSaysStale() {
        // 接线（规则 5）：控制器标 selectionStale 时页面清掉选中；没有候选就展开选择器。
        // 任务替身里仍有这条任务，页面自己的回查（reconcileSelectedTask）不会清它，清掉只能归功于控制器的标记。
        taskManager.todayTasks = [{ id: 61, title: "已经不在的任务", completed: true, displayOrder: 1 }]
        var view = focusPage()
        view.selectedTaskId = 61
        view.selectedTaskTitle = "已经不在的任务"
        focusSessionController.candidateOverride = { id: -1, title: "", selectionStale: true }

        compare(view.selectedTaskId, 61)
        compare(view.startFromShortcut(), false)

        compare(view.selectedTaskId, -1)
        compare(view.shortcutOpenedSelector, true)
        compare(focusTimer.startFocusCalls, 0)
        findChild(view, "focusTaskPicker").collapse()
    }

    function test_taskSelectorIsInactiveWhileTimerRuns() {
        taskManager.todayTasks = [
            { id: 81, title: "正在做的", completed: false, displayOrder: 1 }
        ]
        appSettings.lastMode = 0
        var view = focusPage()

        compare(view.taskSelectorActive, true)

        mainWindow.startFocusForTask(81, "正在做的")
        wait(40)

        // 计时中任务由计时器说了算，换任务要走既有的确认流程，这里不能再给选择器。
        compare(view.taskSelectorActive, false)
    }

    function test_runningTimerShortcutStillTogglesPause() {
        // 回归：有会话时 ⌘↩ 仍然是暂停/继续，没有被新的启动分支抢走。
        taskManager.todayTasks = [
            { id: 91, title: "在跑的任务", completed: false, displayOrder: 1 }
        ]
        appSettings.lastMode = 0
        mainWindow.startFocusForTask(91, "在跑的任务")
        wait(40)
        compare(focusTimer.startFocusCalls, 1)

        mainWindow.triggerShortcutAction("focus.toggle")
        wait(40)

        // 没有开出第二段会话。
        compare(focusTimer.startFocusCalls, 1)
    }

    // —— 记一笔的键盘入口 ——
    //
    // 捕获框本身的行为在 tst_knowledge_gap_capture 里测；这里只测经由 dispatch
    // 走完的那条集成路径，尤其是「窗口还没激活时不能直接开框」这条时序。

    // —— 统一验收补测（2026-09-14）——
    // 阶段二验收写的是「捕获框打开且输入框已获焦点，回车即存」「计时进行中触发捕获，计时不暂停」，
    // 原有集成用例只断言了 opened。这里用真实按键走完：快捷键 → 打字 → 回车。

    function test_shortcutCaptureTakesKeyboardAndSavesOnReturnWithoutPausingTimer() {
        taskManager.todayTasks = [
            { id: 56, title: "正在做的英语", completed: false, displayOrder: 1, notes: "" }
        ]
        appSettings.lastMode = 0
        mainWindow.startFocusForTask(56, "正在做的英语")
        wait(40)
        compare(focusTimer.isRunning, true)
        mainWindow.currentView = "focus"
        wait(40)

        mainWindow.triggerShortcutAction("gap.capture")

        var focusView = focusPage()
        var popup = findChild(focusView, "knowledgeGapCapturePopup")
        tryCompare(popup, "opened", true)
        var field = findChild(popup, "knowledgeGapCaptureField")
        verify(field)
        tryCompare(field, "activeFocus", true)

        keyClick(Qt.Key_A)
        keyClick(Qt.Key_B)
        keyClick(Qt.Key_C)
        keyClick(Qt.Key_Return)

        compare(knowledgeGapService.captureCalls, 1)
        compare(knowledgeGapService.lastTitle, "abc")
        compare(knowledgeGapService.lastSourceTaskId, 56)
        compare(focusTimer.isRunning, true)
        compare(focusTimer.pauseFocusCalls, 0)
        compare(focusTimer.stopFocusCalls, 0)
        popup.close()
        // 关闭有退出过渡，过渡期间焦点仍在 overlay 里，会把下一条用例的捕获当成「弹窗占着焦点」挡掉。
        tryVerify(function () { return !mainWindow.overlayHoldsFocus }, 2000)
    }

    function test_windowLevelCaptureTakesKeyboardAndSavesOnReturn() {
        mainWindow.currentView = "today"
        tryVerify(function () { return !mainWindow.overlayHoldsFocus }, 2000)

        mainWindow.triggerShortcutAction("gap.capture")

        var popup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        tryCompare(popup, "opened", true)
        var field = findChild(popup, "knowledgeGapCaptureField")
        verify(field)
        tryCompare(field, "activeFocus", true)

        keyClick(Qt.Key_X)
        keyClick(Qt.Key_Return)

        compare(knowledgeGapService.captureCalls, 1)
        compare(knowledgeGapService.lastTitle, "x")
        compare(knowledgeGapService.lastSourceTaskId, 0)
        popup.close()
        tryVerify(function () { return !mainWindow.overlayHoldsFocus }, 2000)
    }

    // 阶段一验收：「当前绑定任务被标记完成后，它仍出现在候选里且保持选中」。
    function test_boundTaskStaysInPickerAndSelectedAfterItIsCompleted() {
        taskManager.todayTasks = [
            { id: 81, title: "先做的", completed: false, displayOrder: 1 },
            { id: 82, title: "绑定的这条", completed: false, displayOrder: 2 }
        ]
        // 专注页只在自己是当前页时响应 tasksChanged（切回本页时另有重读），所以先切过去。
        mainWindow.currentView = "focus"
        wait(40)
        var view = focusPage()
        view.reloadTodayTasks()
        var picker = findChild(view, "focusTaskPicker")
        picker.taskChosen(82, "绑定的这条")
        compare(view.selectedTaskId, 82)

        // 在别处把它标成已完成：服务端顺序变为未完成在前、已完成在后，并发 tasksChanged。
        taskManager.todayTasks = [
            { id: 81, title: "先做的", completed: false, displayOrder: 1 },
            { id: 82, title: "绑定的这条", completed: true, displayOrder: 2 }
        ]
        taskManager.tasksChanged()
        wait(40)

        compare(view.selectedTaskId, 82)
        compare(picker.currentTaskId, 82)
        var ids = picker.candidates.map(function (task) { return Number(task.id) })
        verify(ids.indexOf(82) >= 0, "绑定任务不在候选里：" + JSON.stringify(ids))
    }

    function test_boundTaskMovedOffTodayStaysInPicker() {
        // 绑定的那条被改期到明天：今日列表里没有它了，也必须留在候选里，
        // 否则从选择器走一圈回来会把归属静默改成别的任务。
        taskManager.todayTasks = [
            { id: 83, title: "今天的", completed: false, displayOrder: 1 },
            { id: 84, title: "要改期的", completed: false, displayOrder: 2 }
        ]
        mainWindow.currentView = "focus"
        wait(40)
        var view = focusPage()
        view.reloadTodayTasks()
        var picker = findChild(view, "focusTaskPicker")
        picker.taskChosen(84, "要改期的")

        taskManager.otherDateTasks = [{ id: 84, title: "要改期的", completed: false }]
        taskManager.todayTasks = [
            { id: 83, title: "今天的", completed: false, displayOrder: 1 }
        ]
        taskManager.tasksChanged()
        wait(40)

        compare(picker.currentTaskId, 84)
        compare(Number(picker.candidates[0].id), 84)
    }

    function test_shortcutOpensGlobalCaptureOffFocusPage() {
        mainWindow.currentView = "today"

        mainWindow.triggerShortcutAction("gap.capture")

        var popup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        verify(popup)
        compare(popup.opened, true)
        // 今日页没有「当前任务」概念，这条捕获不带来源。
        compare(popup.sourceTaskId, 0)
        popup.close()
    }

    function test_shortcutOnFocusPageCarriesSourceTask() {
        taskManager.todayTasks = [
            { id: 55, title: "正在做的数学", completed: false, displayOrder: 1, notes: "" }
        ]
        appSettings.lastMode = 0
        mainWindow.startFocusForTask(55, "正在做的数学")
        wait(40)
        mainWindow.currentView = "focus"

        mainWindow.triggerShortcutAction("gap.capture")

        // 专注页那条路径带来源任务；窗口级的那个框不该被打开。
        var globalPopup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        verify(globalPopup)
        compare(globalPopup.opened, false)

        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        var focusPopup = findChild(focusView, "knowledgeGapCapturePopup")
        verify(focusPopup)
        compare(focusPopup.sourceTaskId, 55)
        focusPopup.close()
    }

    function test_globalHotkeyDefersCaptureUntilWindowIsActive() {
        // 这条是阶段二要落实的时序。窗口没激活时键盘焦点还在原来那个应用里，
        // 此刻把框开出来，用户打的字会落到别处——必须先前置，等激活了再开。
        mainWindow.currentView = "today"
        mainWindow.windowActive = false
        activationSpy.clear()

        mainWindow.triggerShortcutAction("global.captureGap")

        var popup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        verify(popup)
        // 还没激活：只发了前置请求，框没有开。
        compare(popup.opened, false)
        compare(mainWindow.pendingGapCapture, true)
        compare(activationSpy.count, 1)

        // 窗口真正激活之后才开。
        mainWindow.windowActive = true
        compare(popup.opened, true)
        compare(mainWindow.pendingGapCapture, false)
        popup.close()
    }

    function test_captureDoesNotFireWhileADialogHoldsFocus() {
        mainWindow.currentView = "today"
        // 弹窗接管焦点时应用内快捷键整体让路；全局热键不经过 AppShortcuts 的 suspended，
        // 所以捕获入口要自己判一次，否则会在弹窗背后弹出第二个框。
        var switchDialog = findChild(mainWindow, "focusSwitchDialog")
        verify(switchDialog)
        switchDialog.open()
        wait(60)

        if (!mainWindow.overlayHoldsFocus) {
            // 离屏平台下弹窗不一定真的拿到焦点；拿不到就不断言这条，
            // 免得变成一条看着绿、其实什么都没验的用例。
            switchDialog.close()
            skip("离屏平台未把焦点交给弹窗，无法验证让路")
            return
        }

        mainWindow.triggerShortcutAction("global.captureGap")

        var popup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        verify(popup)
        compare(popup.opened, false)
        compare(mainWindow.pendingGapCapture, false)
        switchDialog.close()
    }

    // —— 审查修复：失效选中项（2026-09-14）——

    function test_shortcutSkipsDeletedSelectionAndStartsTodayCandidate() {
        // 选中项只在少数路径里清空，删掉任务不会清它。旧实现直接拿它启动：
        // 服务端 INSERT … SELECT … WHERE t.id = :taskId 插入 0 行而失败，
        // 选择器不展开，还提示「今天还没有可以开始的任务」。
        taskManager.todayTasks = [
            { id: 31, title: "还在的高数", completed: false, displayOrder: 1 }
        ]
        var view = focusPage()
        view.selectedTaskId = 77
        view.selectedTaskTitle = "已经删掉的任务"
        appSettings.lastMode = 0

        compare(view.startFromShortcut(), true)

        compare(focusTimer.startFocusTaskId, 31)
        compare(view.selectedTaskId, 31)
    }

    function test_shortcutWithDeletedSelectionAndNoCandidateOpensPicker() {
        taskManager.todayTasks = []
        var view = focusPage()
        view.selectedTaskId = 77
        view.selectedTaskTitle = "已经删掉的任务"

        compare(view.startFromShortcut(), false)

        compare(focusTimer.startFocusCalls, 0)
        compare(focusTimer.startPomodoroCalls, 0)
        compare(findChild(view, "focusTaskPicker").expanded, true)
        // 失效的选中项要清掉，不能留着下次再撞。
        compare(view.selectedTaskId, -1)
    }

    function test_startFailureIsNotReportedAsNoTaskToStart() {
        // 取到了可启动的任务、只是启动本身失败时，不能说「今天还没有可以开始的任务」——
        // 那句话只属于「选择器已展开」这一种结果。
        taskManager.todayTasks = [
            { id: 41, title: "能取到的任务", completed: false, displayOrder: 1 }
        ]
        focusTimer.startFocusSucceeds = false
        appSettings.lastMode = 0
        mainWindow.showToast("基线提示")

        mainWindow.triggerShortcutAction("focus.toggle")
        wait(40)

        var label = findChild(mainWindow, "toastText")
        verify(label)
        verify(label.text.indexOf("今天还没有可以开始的任务") < 0,
               "启动失败被报成了「没有可以开始的任务」：" + label.text)
    }

    // —— 审查修复：挂起的后台捕获（2026-09-14）——

    function test_pendingCaptureExpires() {
        // 系统若拒绝把窗口提到前台，挂起请求不能一直留着——
        // 否则一小时后用户随手打开应用，捕获框会莫名其妙弹出来。
        mainWindow.currentView = "today"
        mainWindow.gapCaptureRequestTimeoutMs = 60
        mainWindow.windowActive = false

        mainWindow.triggerShortcutAction("global.captureGap")
        compare(mainWindow.pendingGapCapture, true)
        tryCompare(mainWindow, "pendingGapCapture", false, 1000)

        mainWindow.windowActive = true
        var popup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        compare(popup.opened, false)
        mainWindow.gapCaptureRequestTimeoutMs = 3000
    }

    function test_pendingCaptureCanBeCancelled() {
        mainWindow.currentView = "today"
        mainWindow.windowActive = false

        mainWindow.triggerShortcutAction("global.captureGap")
        compare(mainWindow.pendingGapCapture, true)
        mainWindow.cancelPendingGapCapture()
        compare(mainWindow.pendingGapCapture, false)

        mainWindow.windowActive = true
        compare(findChild(mainWindow, "globalKnowledgeGapCapturePopup").opened, false)
    }

    function test_pendingCaptureRechecksInputBlockersOnActivation() {
        // 请求挂起时没有阻断、激活那一刻出现了阻断（这里是正在录快捷键）：
        // 执行前必须再判一次，不能在录制器上面弹框抢键。
        mainWindow.currentView = "today"
        mainWindow.windowActive = false
        mainWindow.triggerShortcutAction("global.captureGap")
        compare(mainWindow.pendingGapCapture, true)

        findChild(mainWindow, "settingsDialog").recordingShortcut = true
        mainWindow.windowActive = true

        compare(findChild(mainWindow, "globalKnowledgeGapCapturePopup").opened, false)
        // 被阻断的请求直接作废，不留到下一次激活。
        compare(mainWindow.pendingGapCapture, false)
        findChild(mainWindow, "settingsDialog").recordingShortcut = false
    }

    function test_pendingCaptureRechecksDialogOnActivation() {
        mainWindow.currentView = "today"
        mainWindow.windowActive = false
        mainWindow.triggerShortcutAction("global.captureGap")
        compare(mainWindow.pendingGapCapture, true)

        var switchDialog = findChild(mainWindow, "focusSwitchDialog")
        switchDialog.open()
        wait(60)
        if (!mainWindow.overlayHoldsFocus) {
            switchDialog.close()
            mainWindow.cancelPendingGapCapture()
            skip("离屏平台未把焦点交给弹窗，无法验证让路")
            return
        }

        mainWindow.windowActive = true
        compare(findChild(mainWindow, "globalKnowledgeGapCapturePopup").opened, false)
        compare(mainWindow.pendingGapCapture, false)
        switchDialog.close()
    }

    function pendingCaptureStaysBlockedByBackup(viewName) {
        // 请求挂起后开始了备份/恢复：激活时数据库正处在临界区。
        // 初次分发时的守卫挡不住这条延后执行的路径，执行前必须把数据库阻断也判进去。
        mainWindow.currentView = viewName
        wait(40)
        mainWindow.windowActive = false
        mainWindow.triggerShortcutAction("global.captureGap")
        compare(mainWindow.pendingGapCapture, true)

        backupService.operationBlocksUi = true
        mainWindow.windowActive = true
        wait(60)

        var globalPopup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        var focusPopup = findChild(findChild(mainWindow, "focusViewPage"),
                                   "knowledgeGapCapturePopup")
        compare(globalPopup.opened, false)
        compare(focusPopup.opened, false)
        // 被阻断的请求直接作废。
        compare(mainWindow.pendingGapCapture, false)

        // 阻断结束后也不补弹，再切一次前后台同样不弹。
        backupService.operationBlocksUi = false
        wait(60)
        compare(globalPopup.opened, false)
        compare(focusPopup.opened, false)
        mainWindow.windowActive = false
        mainWindow.windowActive = true
        wait(60)
        compare(globalPopup.opened, false)
        compare(focusPopup.opened, false)
        compare(knowledgeGapService.captureCalls, 0)
    }

    function test_pendingCaptureRechecksBackupBlockOnActivation() {
        pendingCaptureStaysBlockedByBackup("today")
    }

    function test_pendingCaptureRechecksBackupBlockOnFocusPage() {
        pendingCaptureStaysBlockedByBackup("focus")
    }

    // —— 审查修复：主动休息时的捕获（2026-09-14）——

    function test_captureDuringManualRestOpensWindowLevelWithoutSource() {
        // 休息期间也可能想到知识缺口。没有任务上下文只意味着不附带任务和科目，
        // 不是禁止捕获的理由；专注页那颗钮在休息时隐藏，所以走窗口级的无来源捕获。
        mainWindow.currentView = "focus"
        focusTimer.mode = 2
        focusTimer.phase = 3
        focusTimer.isRunning = true
        focusTimer.currentTaskId = 55
        focusTimer.currentTaskTitle = "休息前做的任务"
        wait(40)
        var focusView = findChild(mainWindow, "focusViewPage")
        compare(focusView.state, "manualRest")

        mainWindow.triggerShortcutAction("gap.capture")

        var globalPopup = findChild(mainWindow, "globalKnowledgeGapCapturePopup")
        compare(globalPopup.opened, true)
        compare(globalPopup.sourceTaskId, 0)
        compare(globalPopup.sourceTaskTitle, "")
        compare(globalPopup.categoryId, 0)
        compare(findChild(focusView, "knowledgeGapCapturePopup").opened, false)

        // 休息计时不受影响。
        compare(focusTimer.mode, 2)
        compare(focusTimer.phase, 3)
        compare(focusTimer.isRunning, true)
        compare(focusTimer.pauseFocusCalls, 0)
        compare(focusTimer.stopFocusCalls, 0)
        globalPopup.close()
    }

    // —— 仪表盘「结束」与其它结束入口同口径（2026-09-15 审查修复）——
    // 仪表盘面板曾直接调 stopFocus()：忘了停的 8 小时自由专注被原样写进统计和目标进度，
    // 没有专注页、菜单栏都有的「记录 / 丢弃 / 向下修正」确认。

    function dashboardStopButton() {
        var dashboard = findChild(mainWindow, "dashboardViewPage")
        verify(dashboard)
        var button = findChild(dashboard, "dashboardTimerStopButton")
        verify(button)
        return button
    }

    function test_dashboardStopOnOverlongFreeFocusAsksForConfirmation() {
        mainWindow.currentView = "dashboard"
        focusTimer.mode = 0
        focusTimer.phase = 0
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        focusTimer.currentTaskId = 7
        focusTimer.currentTaskTitle = "忘了停的任务"
        // 需不需要确认由控制器判断（阈值边界见 C++ 测试），这里只验证页面听它的。
        focusTimer.elapsedSeconds = 9 * 60 * 60
        focusSessionController.needsConfirmation = true

        dashboardStopButton().clicked()

        compare(focusSessionController.endCurrentCalls, 1)
        compare(focusTimer.stopFocusCalls, 0)
        var focusView = findChild(mainWindow, "focusViewPage")
        var dialog = findChild(focusView, "longFreeFocusConfirmDialog")
        tryCompare(dialog, "opened", true, 2000)
        // 确认弹窗属于专注页，要切过去它才看得见。
        tryCompare(mainWindow, "currentView", "focus", 2000)
    }

    function test_dashboardStopEndsPomodoroCycleAndStaysOnDashboard() {
        mainWindow.currentView = "dashboard"
        focusTimer.mode = 1
        focusTimer.phase = 1
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        focusTimer.completedPomodoros = 3

        dashboardStopButton().clicked()

        // 接线：结束交给控制器；连续计数归零由控制器负责（C++ endPomodoroResetsConsecutiveCount）。
        compare(focusSessionController.endCurrentCalls, 1)
        compare(focusTimer.stopFocusCalls, 1)
        wait(40)
        // 从仪表盘结束就留在仪表盘；「结束后回今日页」只针对从专注页结束。
        compare(mainWindow.currentView, "dashboard")
    }

    function test_dashboardStopFailureIsVisible() {
        mainWindow.currentView = "dashboard"
        focusTimer.mode = 0
        focusTimer.phase = 0
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        focusTimer.elapsedSeconds = 600
        focusTimer.stopSucceeds = false

        dashboardStopButton().clicked()

        compare(focusSessionController.endCurrentCalls, 1)
        var toast = findChild(mainWindow, "globalToast")
        compare(toast.shown, true)
        // 提示条显示的是控制器返回的失败文案（三句文案本身见 C++ endFailureReportsPerModeMessageAndKeepsTimer）。
        compare(findChild(mainWindow, "toastText").text, "控制器给的失败文案")
    }

    function test_deletingSelectedIdleTaskClearsSelection() {
        taskManager.todayTasks = [{ id: 84, title: "待删除", completed: false }]
        var view = focusPage()
        view.selectedTaskId = 84
        view.selectedTaskTitle = "待删除"
        mainWindow.currentView = "today"
        taskManager.todayTasks = []
        taskManager.tasksChanged()
        compare(view.selectedTaskId, -1)
        compare(view.selectedTaskTitle, "")
    }

    // 删除有 5 秒撤销窗口，窗口内任务仍在库里（getTodayTasks 照样返回它）。
    // 专注页若不藏掉它，对它开始的计时会在窗口结束、任务真正删除后变成「未关联」。
    function test_pendingDeleteTaskIsHiddenFromFocusPickerUntilUndo() {
        taskManager.todayTasks = [
            { id: 61, title: "刚删的", completed: false, displayOrder: 1 },
            { id: 62, title: "下一条", completed: false, displayOrder: 2 }
        ]
        mainWindow.currentView = "focus"
        var view = focusPage()
        compare(view.todayTasks.length, 2)

        mainWindow.requestDeleteTask(61, "刚删的")
        compare(view.pendingDeleteTaskId, 61)
        compare(view.todayTasks.length, 1)
        compare(Number(view.todayTasks[0].id), 62)

        // 撤销后任务回到选择器。
        mainWindow.cancelPendingDelete()
        compare(view.todayTasks.length, 2)
    }

    function test_shortcutSkipsPendingDeleteTask() {
        taskManager.todayTasks = [
            { id: 61, title: "刚删的", completed: false, displayOrder: 1 },
            { id: 62, title: "下一条", completed: false, displayOrder: 2 }
        ]
        appSettings.lastMode = 0
        mainWindow.requestDeleteTask(61, "刚删的")

        compare(focusPage().startFromShortcut(), true)
        compare(focusTimer.startFocusTaskId, 62)
    }

    function test_pendingDeleteOfSelectedTaskHidesSelectionAndUndoRestoresIt() {
        taskManager.todayTasks = [{ id: 63, title: "选中的", completed: false, displayOrder: 1 }]
        var view = focusPage()
        view.selectedTaskId = 63
        view.selectedTaskTitle = "选中的"

        // 选择器会把选中项强行补进候选，所以待删时选中项本身也要收起来。
        mainWindow.requestDeleteTask(63, "选中的")
        compare(view.selectedTaskId, -1)
        compare(view.selectedTaskTitle, "")

        mainWindow.cancelPendingDelete()
        compare(view.selectedTaskId, 63)
        compare(view.selectedTaskTitle, "选中的")
    }

    function test_committedDeleteOfSelectedTaskIsNotRestored() {
        taskManager.todayTasks = [{ id: 64, title: "真删的", completed: false, displayOrder: 1 }]
        var view = focusPage()
        view.selectedTaskId = 64
        view.selectedTaskTitle = "真删的"

        mainWindow.requestDeleteTask(64, "真删的")
        // 桩的 deleteTask 不改列表，这里手动把任务移出库，模拟删除真正落库。
        taskManager.todayTasks = []
        verify(mainWindow.commitPendingDelete())
        compare(view.selectedTaskId, -1)
        compare(view.selectionHeldForPendingDelete, null)
    }

    function test_undoDoesNotOverrideSelectionChosenDuringUndoWindow() {
        taskManager.todayTasks = [
            { id: 65, title: "被删的", completed: false, displayOrder: 1 },
            { id: 66, title: "另选的", completed: false, displayOrder: 2 }
        ]
        var view = focusPage()
        view.selectedTaskId = 65
        view.selectedTaskTitle = "被删的"
        mainWindow.requestDeleteTask(65, "被删的")

        view.selectedTaskId = 66
        view.selectedTaskTitle = "另选的"
        mainWindow.cancelPendingDelete()
        compare(view.selectedTaskId, 66)
        compare(view.selectedTaskTitle, "另选的")
    }

    function test_restoreClearsOldDatabaseTaskIdentity() {
        var view = focusPage()
        view.selectedTaskId = 84
        view.selectedTaskTitle = "旧库任务"
        backupService.restoreStarted()
        compare(view.selectedTaskId, -1)
        taskManager.todayTasks = [{ id: 84, title: "新库同号任务", completed: false }]
        taskManager.tasksChanged()
        compare(view.selectedTaskId, -1)
    }

    // ---- 完成正在计时的任务时结束专注 ----
    // 用户反馈：计时中在今日任务页或仪表盘点「完成」，任务变成已完成，计时却还在走，
    // 得专门去专注页点「结束专注」。完成的正是在计时的任务时，这一下要把专注一并结束。

    function completionTask(id, title) {
        return { id: id, title: title, completed: false, displayOrder: id, estimatedMinutes: 0, notes: "" }
    }

    // 只把计时器替身摆成「正在给某任务计时」，不走开始流程：这里测的是完成那一下，开始流程另有用例。
    function runFocusOn(taskId, title, mode) {
        focusTimer.currentTaskId = taskId
        focusTimer.currentTaskTitle = title
        focusTimer.mode = mode
        focusTimer.phase = mode === 1 ? 1 : 0
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
    }

    // 今日页走真实的完成函数（任务卡复选框调的就是它）：写库成功后页面发撤销信号，主窗口接着处理。
    function completeOnTodayPage(taskId) {
        var todayView = findChild(mainWindow, "todayTaskViewPage")
        verify(todayView)
        taskManager.todayTasks = [completionTask(7, "英语"), completionTask(8, "高等数学")]
        todayView.refresh()
        todayView.setTaskCompletedWithAnimationDelay(taskId, true)
    }

    function toastText() {
        return findChild(mainWindow, "toastText").text
    }

    function test_completingTheRunningTaskEndsItsFocus() {
        runFocusOn(7, "英语", 0)

        completeOnTodayPage(7)

        compare(taskManager.lastSetCompletedId, 7)
        compare(taskManager.lastSetCompletedValue, true)
        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.hasActiveSession, false)
        compare(mainWindow.currentView, "today")
        compare(toastText(), "已完成「英语」，专注已结束")

        // 撤销只翻回任务的完成态，不会把已经结束的专注再开起来。
        var toast = findChild(mainWindow, "globalToast")
        compare(toast.actionText, "撤销")
        toast.triggerAction()
        compare(taskManager.lastSetCompletedId, 7)
        compare(taskManager.lastSetCompletedValue, false)
        compare(focusTimer.startFocusCalls, 0)
        compare(focusTimer.hasActiveSession, false)
    }

    function test_completingAnotherTaskLeavesTheTimerRunning() {
        runFocusOn(7, "英语", 0)

        completeOnTodayPage(8)

        compare(taskManager.lastSetCompletedId, 8)
        compare(focusTimer.stopFocusCalls, 0)
        compare(focusTimer.hasActiveSession, true)
        compare(focusTimer.currentTaskId, 7)
        compare(toastText(), "已完成「高等数学」")
    }

    function test_completionDoesNotInterruptAPomodoroBreak() {
        // 番茄休息阶段计时器仍带着刚才那个任务，但没有专注会话：休息不是专注，不该被完成打断。
        focusTimer.currentTaskId = 7
        focusTimer.currentTaskTitle = "英语"
        focusTimer.mode = 1
        focusTimer.phase = 2
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = true

        completeOnTodayPage(7)

        compare(focusTimer.stopFocusCalls, 0)
        compare(focusTimer.phase, 2)
        compare(toastText(), "已完成「英语」")
    }

    function test_completingThePausedPomodoroTaskEndsTheWholeCycle() {
        // 暂停中的番茄也是进行中的专注；结束走番茄入口，连续计数跟着归零。
        runFocusOn(7, "英语", 1)
        focusTimer.isRunning = false
        focusTimer.completedPomodoros = 2

        completeOnTodayPage(7)

        // 接线：走番茄入口结束（控制器收到一次），连续计数归零由控制器负责，见 C++ 测试。
        compare(focusSessionController.endCurrentCalls, 1)
        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.hasActiveSession, false)
        compare(toastText(), "已完成「英语」，专注已结束")
    }

    function test_shortFocusEndedByCompletionIsExplainedInTheUndoToast() {
        runFocusOn(7, "英语", 0)
        focusTimer.elapsedSeconds = 90
        focusTimer.stopDiscards = true

        completeOnTodayPage(7)

        // 提示条只有一个槽：「未计入」并进完成提示，撤销入口也还在。
        compare(focusSessionController.endCurrentCalls, 1)
        compare(toastText(), "已完成「英语」，专注不足 3 分钟，未计入记录")
        compare(findChild(mainWindow, "globalToast").actionText, "撤销")

        // 与完成无关的丢弃照旧单独提示，说明合并只作用于完成那一下。
        focusTimer.sessionDiscarded(60)
        compare(toastText(), "本次专注不足 3 分钟，未计入记录")
    }

    function test_failedStopKeepsTheTimerAndSaysSo() {
        runFocusOn(7, "英语", 0)
        focusTimer.stopSucceeds = false

        completeOnTodayPage(7)

        // 任务照样完成；计时没能结束就如实说，原因留在专注页的错误行里供用户重试。
        compare(taskManager.lastSetCompletedValue, true)
        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.hasActiveSession, true)
        compare(toastText(), "已完成「英语」，但结束专注失败，计时仍在继续")
        compare(focusPage().errorText, "控制器给的失败文案")
    }

    function test_discardedResultFromControllerIsExplainedInTheUndoToast() {
        // 新增接线用例：完成提示里的「不足 3 分钟」以控制器返回的 discarded 为准，
        // 不依赖计时器信号恰好被收到（stopDiscards 为假，没有发 sessionDiscarded）。
        runFocusOn(7, "英语", 0)
        focusSessionController.endOutcome = { result: "ended", kind: "free", discarded: true, error: "" }

        completeOnTodayPage(7)

        compare(toastText(), "已完成「英语」，专注不足 3 分钟，未计入记录")
    }

    function test_noneResultAddsNoFocusSentenceToTheCompletionToast() {
        // 新增接线用例：计时器报告有会话、控制器却说没有可结束的（none）时，完成提示不加专注说明、也不当成失败。
        runFocusOn(7, "英语", 0)
        focusSessionController.endOutcome = { result: "none", kind: "", discarded: false, error: "" }

        completeOnTodayPage(7)

        compare(toastText(), "已完成「英语」")
    }

    function test_overlongFreeFocusGoesToTheConfirmationInsteadOfStopping() {
        // 自由计时超过提醒时长（默认 8 小时）可能是忘了停，不能直接原样记进统计：
        // 与仪表盘「结束」一样转去专注页，由确认框决定记录、修正还是丢弃。
        runFocusOn(7, "英语", 0)
        focusTimer.elapsedSeconds = 9 * 60 * 60
        focusSessionController.needsConfirmation = true

        completeOnTodayPage(7)

        compare(focusSessionController.endCurrentCalls, 1)
        compare(focusTimer.stopFocusCalls, 0)
        compare(toastText(), "已完成「英语」")
        tryCompare(mainWindow, "currentView", "focus", 3000)
        tryCompare(findChild(focusPage(), "longFreeFocusConfirmDialog"), "opened", true, 3000)
    }

    function test_completionAsksTheControllerWithTheCompletedTaskId() {
        // 接线（规则 3）：完成任务时页面把任务编号交给控制器，是否结束由控制器说了算。
        runFocusOn(7, "英语", 0)
        completeOnTodayPage(8)
        compare(focusSessionController.completedCalls.length, 1)
        compare(focusSessionController.completedCalls[0], 8)
        compare(focusSessionController.endCurrentCalls, 0)
        compare(focusTimer.hasActiveSession, true)
    }

    function test_completionToastEndingsFollowTheControllerResult() {
        // 接线（规则 3）：三种结尾文案只由控制器的 focusResult / discarded 决定，页面不自己判断计时器。
        // 计时器替身此刻是空闲的，替身却说「已结束」，证明文案不是页面从计时器推出来的。
        focusSessionController.completedOverride = { focusResult: "ended", kind: "free", discarded: false, error: "" }
        completeOnTodayPage(7)
        compare(toastText(), "已完成「英语」，专注已结束")

        focusSessionController.completedOverride = { focusResult: "ended", kind: "free", discarded: true, error: "" }
        completeOnTodayPage(7)
        compare(toastText(), "已完成「英语」，专注不足 3 分钟，未计入记录")

        focusSessionController.completedOverride = { focusResult: "failed", kind: "free", discarded: false, error: "控制器给的失败文案" }
        completeOnTodayPage(7)
        compare(toastText(), "已完成「英语」，但结束专注失败，计时仍在继续")
        compare(focusPage().errorText, "控制器给的失败文案")

        focusSessionController.completedOverride = { focusResult: "none", kind: "", discarded: false, error: "" }
        completeOnTodayPage(7)
        compare(toastText(), "已完成「英语」")
    }

    function test_completionNeedsConfirmationSwitchesToFocusPageWithoutSuffix() {
        // 接线（规则 3）：控制器说需要确认时不加结尾、切到专注页弹超长确认框，不当作已结束。
        runFocusOn(7, "英语", 0)
        focusSessionController.needsConfirmation = true
        focusSessionController.completedOverride = { focusResult: "needsConfirmation", kind: "free", discarded: false, error: "" }

        completeOnTodayPage(7)

        compare(toastText(), "已完成「英语」")
        tryCompare(mainWindow, "currentView", "focus", 3000)
        tryCompare(findChild(focusPage(), "longFreeFocusConfirmDialog"), "opened", true, 3000)
        compare(focusTimer.hasActiveSession, true)
    }

    function test_everyTaskPageEndsTheRunningFocusInPlace_data() {
        return [
            { tag: "今日任务", page: "today", objectName: "todayTaskViewPage" },
            { tag: "仪表盘", page: "dashboard", objectName: "dashboardViewPage" },
            { tag: "本周计划", page: "week", objectName: "weekPlanViewPage" }
        ]
    }

    // 各页面何时发撤销信号由页面级用例（tst_today/dashboard_complete_with_note 等）测过；
    // 这里只验证三个页面都接到了同一个处理函数，并且结束后留在原页，不被带回今日页。
    function test_everyTaskPageEndsTheRunningFocusInPlace(data) {
        mainWindow.currentView = data.page
        mainWindow.pendingView = data.page
        var view = findChild(mainWindow, data.objectName)
        verify(view)
        runFocusOn(7, "英语", 0)

        view.taskCompletionUndoable(7, "英语")

        compare(focusSessionController.endCurrentCalls, 1)
        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.hasActiveSession, false)
        // 切页带淡出动画，currentView 要等动画放完才变；switchToView 同步改的是这两个，
        // 所以看它们才能当场发现「被带回今日页」。
        compare(mainWindow.isSwitching, false)
        compare(mainWindow.pendingView, data.page)
        compare(mainWindow.currentView, data.page)
        compare(toastText(), "已完成「英语」，专注已结束")
    }

    // 设备间同步（050 阶段 4）在主窗口上的三处接线。
    function test_syncNoticeShowsAsToast() {
        // 已经加入、建好了文件夹、另一台设备恢复了备份：这些事用提示条告诉你。
        syncController.notice("已加入同步：本机数据已换成同步文件夹里的，原来的数据已自动备份。")
        compare(toastText(), "已加入同步：本机数据已换成同步文件夹里的，原来的数据已自动备份。")
    }

    function test_syncLogOpensFromSettings() {
        var settings = findChild(mainWindow, "settingsDialog")
        var log = findChild(mainWindow, "syncLogDialog")
        verify(settings)
        verify(log)
        // 设置页的「同步日志」入口：设置先关掉，再由主窗口打开日志弹窗（与其它管理入口一致）。
        settings.syncLogRequested()
        tryCompare(log, "opened", true)
        log.close()
        tryCompare(log, "opened", false)
    }

    function test_restoreConfirmationShowsTheSyncWarning() {
        var dialog = findChild(mainWindow, "restoreConfirmDialog")
        verify(dialog)
        // 加入过同步时恢复就是全局回滚（关着同步也一样，只是等下次打开同步时发生）：
        // 打开确认框时向控制器要这句提醒，原样交给弹窗；控制器给空，就是恢复只影响这台设备。
        syncController.enabled = false
        syncController.restoreWarningText = "这台设备加入过设备间同步（现在关着）：恢复之后，下次打开同步时，另一台设备也会回到这份备份的状态。"
        mainWindow.restoreInspectionPath = "/tmp/测试备份.tomatobackup"
        backupService.backupInfoReady("/tmp/测试备份.tomatobackup", { valid: true })
        tryCompare(dialog, "opened", true)
        // 先取值、关掉模态弹窗再比较：比较失败时弹窗不会留在屏幕上，连带后面的用例一起失败。
        var shown = dialog.syncWarning
        dialog.close()
        tryCompare(dialog, "opened", false)
        compare(shown, syncController.restoreWarningText)

        syncController.restoreWarningText = ""
        mainWindow.restoreInspectionPath = "/tmp/测试备份.tomatobackup"
        backupService.backupInfoReady("/tmp/测试备份.tomatobackup", { valid: true })
        tryCompare(dialog, "opened", true)
        shown = dialog.syncWarning
        dialog.close()
        tryCompare(dialog, "opened", false)
        compare(shown, "")
    }
}
