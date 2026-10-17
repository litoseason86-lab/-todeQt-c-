import QtQuick
import QtTest
import "../../qml"
import "../../qml/views"
import "../../qml/mobile"
import "TestWaits.js" as TestWaits

// 移动端的界面规则：
//   · 平台不支持自由计时时，任何「开始」入口都落到番茄；支持时照常走自由计时（iPad 现在的配置）；
//   · 主动休息有自己的开关：iPad 开着自由计时，主动休息入口仍隐藏；
//   · 离线结算（phaseSettledOffline）只结算这一段，打开「自动开始休息」也不会自动衔接；
//   · 伴侣页完成正在计时的任务时顺带结束专注。
// 每条「不会自动衔接」都配一条「正常到点会自动衔接」的对照，证明测试确实能测出差别。
TestCase {
    id: testCase
    name: "MobileTiming"
    when: windowShown
    width: 400
    height: 800

    QtObject {
        id: timerStub

        signal operationFailed(string message)
        property string t33Failure: ""
        function rejectT33() {
            if (t33Failure.length === 0) return false
            operationFailed(t33Failure); return true
        }
        signal phaseCompleted(int phase)
        signal phaseSettledOffline(int phase)
        signal currentTaskChanged()

        property bool freeTimingAllowed: false
        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int mode: 1
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
        property int minimumValidMinutes: 3
        property int completedPomodoros: 0
        property int startFocusCalls: 0
        property int startPomodoroCalls: 0
        property int startBreakCalls: 0
        property int stopFocusCalls: 0

        function startFocus(taskId, title) {
            startFocusCalls += 1
            return false
        }
        function startPomodoroWork(taskId, title, seconds) {
            if (rejectT33()) return false
            startPomodoroCalls += 1
            currentTaskId = taskId
            currentTaskTitle = title
            mode = 1
            phase = 1
            targetSeconds = seconds
            remainingSeconds = seconds
            hasActiveSession = true
            isRunning = true
            currentTaskChanged()
            return true
        }
        function startBreak(seconds) {
            return startBreakForTask(seconds, -1, "")
        }
        function startBreakForTask(seconds, taskId, title) {
            if (rejectT33()) return false
            startBreakCalls += 1
            mode = 1
            phase = 2
            hasActiveSession = false
            isRunning = true
            return true
        }
        function stopFocus() {
            if (rejectT33()) return false
            stopFocusCalls += 1
            hasActiveSession = false
            isRunning = false
            phase = 0
            currentTaskId = -1
            currentTaskTitle = ""
            return true
        }
        function pauseFocus() { isRunning = false; return true }
        function resumeFocus() { isRunning = true; return true }
        function resetPomodoroCount() { completedPomodoros = 0 }

        // 模拟一个专注段结束（正常到点或离线结算之后，计时器回到空闲）。
        function finishWork() {
            hasActiveSession = false
            isRunning = false
            phase = 0
            completedPomodoros += 1
        }
    }

    QtObject {
        id: settingsStub

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
        property bool reduceMotion: true
        property bool slimClockFont: true
        property bool autoStartBreak: true
        property bool autoStartNextPomodoro: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property int freeTimerWarningHours: 8
        property int dayStartHour: 4
    }

    QtObject {
        id: taskStub

        signal tasksChanged()
        signal operationFailed(string message)

        property int maxTitleLength: 200
        property var rows: [ { id: 7, title: "验收番茄", completed: false } ]
        property int setCompletedCalls: 0

        function getTodayTasks() { return rows }
        function getTask(id) { return rows[0] }
        function addTask(title, date) { return true }
        function setTaskCompleted(id, completed) {
            setCompletedCalls += 1
            return true
        }
    }

    // 专注控制器替身：只给本文件流程用到的分支，口径同 C++（判定表在 FocusSessionControllerTests）。
    // 自动衔接的判定在控制器里，专注页不接控制器就不会衔接，所以这里必须接上。
    QtObject {
        id: controllerStub

        function planTaskEntry(taskId, title) {
            var busy = timerStub.hasActiveSession || timerStub.phase !== 0
            return { kind: busy ? "confirmSwitch" : "apply", usePomodoro: settingsStub.lastMode === 1,
                     autoStart: true, title: String(title || "").trim() }
        }
        function nextBreakMinutes(selected) { return selected }
        function autoAdvanceAfter(phase) {
            return (phase === 1 && settingsStub.autoStartBreak) || (phase === 2 && settingsStub.autoStartNextPomodoro === true)
        }
        function freeTimerWarningHours() { return 8 }
        function needsLongFreeStopConfirmation() { return false }
    }

    Component {
        id: focusViewComponent

        FocusView {
            width: testCase.width
            height: testCase.height
            timer: timerStub
            settings: settingsStub
            taskManagerRef: taskStub
            focusSessionControllerRef: controllerStub
        }
    }

    Component {
        id: companionComponent

        CompanionWindow {
            width: testCase.width
            height: testCase.height
            focusTimerRef: timerStub
            appSettingsRef: settingsStub
            taskManagerRef: taskStub
        }
    }

    // 今日任务页只要这几个桩就能加载，这里只用它核对主动休息入口看的是哪个开关。
    QtObject {
        id: todayTaskManagerStub
        signal tasksChanged
        function getTodayTasks() { return [] }
        function getOverdueUncompletedTasks() { return [] }
    }

    QtObject {
        id: todayStatisticsStub
        function getTodayStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 }
        }
    }

    QtObject {
        id: todayTimerStub
        signal focusCompleted(int duration)
        property int mode: 0
        property int phase: 0
        property bool hasActiveSession: false
        property bool isRunning: false
        property int elapsedSeconds: 0
        property string sessionLogicalDate: ""
        property bool freeTimingAllowed: true
        property bool manualRestAllowed: false
    }

    QtObject {
        id: todayRoutineStub
        signal routinesChanged
        function materializeToday() {}
    }

    QtObject {
        id: todayLogicalDayStub
        signal changed
    }

    QtObject {
        id: todaySettingsStub
        signal dailyFocusGoalChanged
        property int dayStartHour: 4
        property bool reduceMotion: true
        property string rolloverIgnoredDate: ""
        function dailyFocusGoalMinutesForDate(isoDate) { return 0 }
    }

    Component {
        id: todayViewComponent

        TodayTaskView {
            width: 860
            height: 600
            taskManagerRef: todayTaskManagerStub
            statisticsServiceRef: todayStatisticsStub
            routineManagerRef: todayRoutineStub
            focusTimerRef: todayTimerStub
            logicalDayServiceRef: todayLogicalDayStub
            settingsRef: todaySettingsStub
        }
    }

    function init() {
        timerStub.t33Failure = ""
        testCase.activeCompanion = null
        testCase.t33Messages = []
        // 默认按「平台不支持自由计时」布置；需要开放的用例自己打开，下一条用例开始前复位。
        timerStub.freeTimingAllowed = false
        todayTimerStub.freeTimingAllowed = true
        todayTimerStub.manualRestAllowed = false
        timerStub.isRunning = false
        timerStub.hasActiveSession = false
        timerStub.currentTaskId = -1
        timerStub.currentTaskTitle = ""
        timerStub.mode = 1
        timerStub.phase = 0
        timerStub.completedPomodoros = 0
        timerStub.startFocusCalls = 0
        timerStub.startPomodoroCalls = 0
        timerStub.startBreakCalls = 0
        timerStub.stopFocusCalls = 0
        settingsStub.lastMode = 0
        settingsStub.autoStartBreak = true
        taskStub.setCompletedCalls = 0
    }

    function test_focusViewStartsPomodoroWhenFreeTimingUnavailable() {
        var view = createTemporaryObject(focusViewComponent, testCase)
        verify(view !== null)
        compare(view.freeModeAvailable, false)
        compare(view.pomodoroModeSelected, true)

        // 任务页按记住的「自由」模式、快速开始：平台不支持自由计时，只能走番茄。
        view.openTask(7, "验收番茄", false, true)
        compare(timerStub.startFocusCalls, 0)
        compare(timerStub.startPomodoroCalls, 1)
        compare(view.pomodoroModeSelected, true)

        // 模式页签也切不到自由。
        timerStub.stopFocus()
        view.toPomodoroTab(false)
        compare(view.pomodoroModeSelected, true)
    }

    // 对照：平台开放自由计时（iPad 现在的配置）时，记住的「自由」模式照常走自由计时，
    // 证明上一条用例测出的是开关的作用，而不是专注页总会落到番茄。
    function test_focusViewStartsFreeFocusWhenFreeTimingAllowed() {
        timerStub.freeTimingAllowed = true
        var view = createTemporaryObject(focusViewComponent, testCase)
        verify(view !== null)
        compare(view.freeModeAvailable, true)
        compare(view.pomodoroModeSelected, false)

        view.openTask(7, "验收自由计时", false, true)
        compare(timerStub.startFocusCalls, 1)
        compare(timerStub.startPomodoroCalls, 0)
    }

    // iPad 的配置：自由计时开着、主动休息关着。主动休息入口必须看它自己的开关，
    // 不能因为自由计时开放了就跟着出现（两者曾共用一个开关）。
    function test_todayManualRestFollowsItsOwnSwitch() {
        var view = createTemporaryObject(todayViewComponent, testCase)
        verify(view !== null)
        compare(view.manualRestAvailable, false)

        // 对照：只打开主动休息的开关，入口随之可用。
        todayTimerStub.manualRestAllowed = true
        compare(view.manualRestAvailable, true)
    }

    function test_focusViewDoesNotAutoAdvanceAfterOfflineSettlement() {
        var view = createTemporaryObject(focusViewComponent, testCase)
        verify(view !== null)
        view.openTask(7, "验收番茄", true, true)
        compare(timerStub.startPomodoroCalls, 1)

        timerStub.finishWork()
        timerStub.phaseSettledOffline(1)
        // 自动衔接在减少动效时是 0 延迟的 Timer；等足几轮事件循环确认它没有被触发。
        TestWaits.observe(testCase, 100, "确认减少动效下 0 延迟的自动衔接 Timer 在几轮事件循环里都没有开始休息；没发生的事没有信号可等")
        compare(timerStub.startBreakCalls, 0)
    }

    function test_focusViewStillAutoAdvancesOnNormalCompletion() {
        // 对照组：同样的设置下，人在场时到点会自动开始休息。
        var view = createTemporaryObject(focusViewComponent, testCase)
        verify(view !== null)
        view.openTask(7, "验收番茄", true, true)

        timerStub.finishWork()
        timerStub.phaseCompleted(1)
        tryCompare(timerStub, "startBreakCalls", 1)
    }

    function test_companionDoesNotAutoAdvanceAfterOfflineSettlement() {
        var companion = createTemporaryObject(companionComponent, testCase)
        verify(companion !== null)
        companion.startPomodoro(7, "验收番茄")
        compare(timerStub.startPomodoroCalls, 1)

        timerStub.finishWork()
        timerStub.phaseSettledOffline(1)
        TestWaits.observe(testCase, 100, "确认伴侣页离线结算后几轮事件循环里都没有自动开始休息；没发生的事没有信号可等")
        compare(timerStub.startBreakCalls, 0)
        // 停在「完成」态，由用户决定要不要开始休息。
        compare(companion.justCompletedPhase, 1)
    }

    function test_companionAutoAdvancesOnNormalCompletion() {
        var companion = createTemporaryObject(companionComponent, testCase)
        verify(companion !== null)
        companion.startPomodoro(7, "验收番茄")

        timerStub.finishWork()
        timerStub.phaseCompleted(1)
        tryCompare(timerStub, "startBreakCalls", 1)
    }

    function test_companionCompletingFocusedTaskStopsFocus() {
        var companion = createTemporaryObject(companionComponent, testCase)
        verify(companion !== null)
        companion.startPomodoro(7, "验收番茄")

        companion.setCompleted({ id: 7, title: "验收番茄", completed: false }, true)
        compare(taskStub.setCompletedCalls, 1)
        compare(timerStub.stopFocusCalls, 1)
    }

    function test_companionCompletingOtherTaskKeepsFocus() {
        var companion = createTemporaryObject(companionComponent, testCase)
        verify(companion !== null)
        companion.startPomodoro(7, "验收番茄")

        companion.setCompleted({ id: 8, title: "别的任务", completed: false }, true)
        compare(timerStub.stopFocusCalls, 0)
    }

    property var activeCompanion: null
    property var t33Messages: []
    Connections {
        target: timerStub
        function onOperationFailed(message) {
            // 与 CompanionMain 相同的外壳门禁：本次同步调用已认领时，不再弹第二条。
            if (testCase.activeCompanion && !testCase.activeCompanion.timerFailureCall)
                testCase.t33Messages.push(message)
        }
    }
    // 产品保证：伴侣页的启动与完成时停表失败只提示一次具体原因，失败不改变活动计时。
    function test_t33CompanionFailureHasOneReason_data() {
        return ["pomodoro", "break", "complete"].map(function(action) { return {tag: action, action: action} })
    }
    // 产品保证：伴侣页不再用通用文案覆盖服务原因，调用中的失败也不由外壳重复显示。
    function test_t33CompanionFailureHasOneReason(data) {
        var companion = createTemporaryObject(companionComponent, testCase)
        verify(companion)
        testCase.activeCompanion = companion
        companion.toastRequested.connect(function(message) { testCase.t33Messages.push(message) })
        if (data.action === "complete") {
            companion.startPomodoro(7, "保留任务")
            verify(timerStub.hasActiveSession)
        }
        timerStub.t33Failure = "计时操作失败：T33 storage blocked"
        if (data.action === "pomodoro") companion.startPomodoro(7, "保留任务")
        else if (data.action === "break") companion.startBreak()
        else companion.setCompleted({id: 7}, true)
        compare(testCase.t33Messages.length, 1)
        verify(testCase.t33Messages[0].indexOf(timerStub.t33Failure) >= 0)
        compare(timerStub.hasActiveSession, data.action === "complete")
    }


    // 产品保证：伴侣页没有待删入口，不把其它窗口单条删除失败重复显示成任务加载错误。
    function test_companionIgnoresPendingDeletionFailure() {
        var companion = createTemporaryObject(companionComponent,testCase)
        verify(companion); companion.loadError = "原结果"
        taskStub.operationFailed("删除任务失败：T33-2 pending blocked")
        compare(companion.loadError,"原结果")
        taskStub.operationFailed("删除失败：T33-2 batch blocked")
        compare(companion.loadError,"删除失败：T33-2 batch blocked")
    }

}
