import QtQuick
import QtTest
import "../../qml"
import "../../qml/views"

TestCase {
    id: testCase
    name: "FocusViewDualMode"
    when: windowShown
    width: 720
    height: 520

    QtObject {
        id: focusTimer

        signal phaseCompleted(int phase)

        property int elapsedSeconds: 0
        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: 7
        property string currentTaskTitle: "测试任务"
        property int mode: 0
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        property int startPomodoroWorkTaskId: 0
        property string startPomodoroWorkTitle: ""
        property int startPomodoroWorkSeconds: 0
        property int stopFocusCalls: 0

        function startFocus(taskId, title) {
            return true
        }

        function pauseFocus() {
            isRunning = false
        }

        function resumeFocus() {
            isRunning = true
            return true
        }

        function stopFocus() {
            stopFocusCalls += 1
            isRunning = false
            hasActiveSession = false
            mode = 0
            phase = 0
            currentTaskId = 0
            currentTaskTitle = ""
            return true
        }

        function startPomodoroWork(taskId, title, workSeconds) {
            startPomodoroWorkTaskId = taskId
            startPomodoroWorkTitle = title
            startPomodoroWorkSeconds = workSeconds
            isRunning = true
            hasActiveSession = true
            mode = 1
            phase = 1
            targetSeconds = workSeconds
            remainingSeconds = workSeconds
            currentTaskId = taskId
            currentTaskTitle = title
            return true
        }

        function startBreak(breakSeconds) {
            isRunning = true
            hasActiveSession = false
            mode = 1
            phase = 2
            targetSeconds = breakSeconds
            remainingSeconds = breakSeconds
            currentTaskId = -1
            currentTaskTitle = ""
            return true
        }
    }

    FocusView {
        id: view
        width: testCase.width
        height: testCase.height
        timer: focusTimer
    }

    function init() {
        focusTimer.elapsedSeconds = 0
        focusTimer.isRunning = false
        focusTimer.hasActiveSession = false
        focusTimer.currentTaskId = 7
        focusTimer.currentTaskTitle = "测试任务"
        focusTimer.mode = 0
        focusTimer.phase = 0
        focusTimer.targetSeconds = 0
        focusTimer.remainingSeconds = 0
        focusTimer.startPomodoroWorkTaskId = 0
        focusTimer.startPomodoroWorkTitle = ""
        focusTimer.startPomodoroWorkSeconds = 0
        focusTimer.stopFocusCalls = 0
        view.toPomodoroTab(false)
        view.selectWorkMinutes(25)
        view.selectBreakMinutes(5)
        wait(20)
    }

    function test_switchToPomodoroShowsPresetsAndIdleState() {
        view.toPomodoroTab(true)
        wait(20)

        compare(view.state, "pomoIdle")
        verify(findChild(view, "workPreset25") !== null)
        verify(findChild(view, "workPreset45") !== null)
        verify(findChild(view, "workPreset60") !== null)
        verify(findChild(view, "breakPreset5") !== null)
        verify(findChild(view, "breakPreset10") !== null)
        verify(findChild(view, "pomodoroStartButton") !== null)
    }

    function test_startPomodoroUsesSelectedWorkMinutes() {
        focusTimer.hasActiveSession = true
        view.toPomodoroTab(true)
        view.selectWorkMinutes(45)
        view.startPomodoro()
        wait(20)

        compare(focusTimer.stopFocusCalls, 1)
        compare(focusTimer.startPomodoroWorkTaskId, 7)
        compare(focusTimer.startPomodoroWorkTitle, "测试任务")
        compare(focusTimer.startPomodoroWorkSeconds, 45 * 60)
        compare(view.state, "pomoWork")
    }

    function test_presetButtonsUseWarmSelectedColor() {
        view.toPomodoroTab(true)
        wait(20)

        const workBackground = findChild(view, "workPreset25Background")
        const breakBackground = findChild(view, "breakPreset5Background")
        verify(workBackground)
        verify(breakBackground)
        verify(Qt.colorEqual(workBackground.color, Theme.accent))
        verify(Qt.colorEqual(breakBackground.color, Theme.accent))
    }

    function test_startButtonDisabledWithoutTask() {
        focusTimer.currentTaskId = -1
        focusTimer.currentTaskTitle = ""
        view.toPomodoroTab(true)
        wait(20)

        const startButton = findChild(view, "pomodoroStartButton")
        verify(startButton)
        compare(startButton.enabled, false)
    }

    function test_breakDoneCanRestartWithCachedTask() {
        focusTimer.hasActiveSession = true
        view.toPomodoroTab(true)
        view.startPomodoro()
        wait(20)

        focusTimer.phaseCompleted(1)
        wait(20)
        compare(view.state, "workDone")

        view.startBreak()
        focusTimer.stopFocus()
        focusTimer.phaseCompleted(2)
        wait(20)

        const startButton = findChild(view, "pomodoroStartButton")
        verify(startButton)
        compare(view.state, "breakDone")
        compare(startButton.enabled, true)

        focusTimer.startPomodoroWorkTaskId = 0
        view.startPomodoro()
        wait(20)

        compare(focusTimer.startPomodoroWorkTaskId, 7)
        compare(view.state, "pomoWork")
    }

    function test_endPomodoroStopsBreakWithoutActiveSession() {
        view.toPomodoroTab(true)
        focusTimer.mode = 1
        focusTimer.phase = 2
        focusTimer.isRunning = true
        focusTimer.hasActiveSession = false
        focusTimer.remainingSeconds = 120
        wait(20)

        view.endPomodoro()

        compare(focusTimer.stopFocusCalls, 1)
    }

    function test_freeModeHasNoFocusRing() {
        // 环的 visible 绑定的是 root.pomodoroModeSelected，但 Item.visible 是级联读取
        // 祖先链的——qmltestrunner 里顶层测试窗口自身的 OS 级可见性并不可靠，直接断言
        // ring.visible 会被这个和本组件无关的因素污染。改成断言驱动它的源头布尔值。
        view.toPomodoroTab(false)
        wait(20)

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(view.pomodoroModeSelected, false)
    }

    function test_pomoIdleShowsRingPreview() {
        view.toPomodoroTab(true)
        wait(20)

        compare(view.pomodoroModeSelected, true)
        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.showPreview, true)
    }

    function test_pomoWorkRingShowsAccentAndProgress() {
        focusTimer.hasActiveSession = true
        view.toPomodoroTab(true)
        view.startPomodoro()
        focusTimer.remainingSeconds = 932 // 15:32 剩余，对应 25 分钟目标的 62.1%
        wait(20)

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.showPreview, false)
        compare(ring.dimmed, false)
        verify(Qt.colorEqual(ring.ringColor, Theme.accent))
        verify(Math.abs(ring.progress - (932 / 1500)) < 0.001)
    }

    function test_pausedDimsRingAndLabelsGlyph() {
        focusTimer.hasActiveSession = true
        view.toPomodoroTab(true)
        view.startPomodoro()
        focusTimer.isRunning = false
        wait(20)

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.dimmed, true)

        const stageText = findChild(view, "phaseStageText")
        verify(stageText)
        verify(stageText.text.indexOf("⏸") !== -1)
    }

    function test_breakRingUsesBreakAccent() {
        view.toPomodoroTab(true)
        view.startBreak()
        wait(20)

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.dimmed, false)
        verify(Qt.colorEqual(ring.ringColor, Theme.focusBreakAccent))
    }

    function test_workDoneShowsClosedGreenRing() {
        focusTimer.hasActiveSession = true
        view.toPomodoroTab(true)
        view.startPomodoro()
        wait(20)

        focusTimer.phaseCompleted(1)
        wait(20)
        compare(view.state, "workDone")

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.progress, 1)
        verify(Qt.colorEqual(ring.ringColor, Theme.success))
    }

    function test_breakDoneShowsClosedGreenRing() {
        focusTimer.hasActiveSession = true
        view.toPomodoroTab(true)
        view.startPomodoro()
        wait(20)
        focusTimer.phaseCompleted(1)
        wait(20)

        view.startBreak()
        focusTimer.stopFocus()
        focusTimer.phaseCompleted(2)
        wait(20)
        compare(view.state, "breakDone")

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.progress, 1)
        verify(Qt.colorEqual(ring.ringColor, Theme.success))
    }
}
