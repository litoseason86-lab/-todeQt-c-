import QtQuick
import QtTest
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
}
