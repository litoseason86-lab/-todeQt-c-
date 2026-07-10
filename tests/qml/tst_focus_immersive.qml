import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"

TestCase {
    id: testCase
    name: "FocusImmersiveOverlay"
    when: windowShown
    width: 900
    height: 640

    QtObject {
        id: focusViewStub

        property string state: "pomoWork"
        property string errorText: ""
        property string timeText: "12:34"
        property real progressValue: 0.5
        property color ringColorValue: Theme.accent
        property bool dimmedValue: false
        property string captionText: "剩余 · 共 25 分"
        property string stageText: "专注中"
        property string runningLine: "专注进行中"
        property string titleText: "写周报"
        property bool canStart: true
        property int togglePauseCalls: 0
        property int endPomodoroCalls: 0
        property int startBreakCalls: 0
        property int startPomodoroCalls: 0
        property int endFreeFocusCalls: 0

        function primaryTimeText() { return timeText }
        function pomodoroStageText() { return stageText }
        function runningText() { return runningLine }
        function taskTitle() { return titleText }
        function ringProgressFraction() { return progressValue }
        function ringColorForState() { return ringColorValue }
        function ringDimmed() { return dimmedValue }
        function ringCaptionText() { return captionText }
        function primaryTimeColor() { return dimmedValue ? Theme.inkMuted : Theme.accentInk }
        function ringTimeMarkup(plain) { return plain }
        function canStartPomodoro() { return canStart }
        function togglePause() { togglePauseCalls += 1 }
        function endPomodoro() { endPomodoroCalls += 1 }
        function startBreak() { startBreakCalls += 1 }
        function startPomodoro() { startPomodoroCalls += 1 }
        function endFreeFocus() { endFreeFocusCalls += 1 }
    }

    QtObject {
        id: timerStub

        property bool isRunning: true
        property bool hasActiveSession: true
        property int phase: 1
    }

    QtObject {
        id: settingsStub

        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
    }

    FocusImmersiveOverlay {
        id: overlay
        width: testCase.width
        height: testCase.height
        focusViewRef: focusViewStub
        timerRef: timerStub
        settingsRef: settingsStub
        active: true
    }

    SignalSpy {
        id: exitSpy
        target: overlay
        signalName: "exitRequested"
    }

    function init() {
        focusViewStub.state = "pomoWork"
        focusViewStub.errorText = ""
        focusViewStub.timeText = "12:34"
        focusViewStub.progressValue = 0.5
        focusViewStub.ringColorValue = Theme.accent
        focusViewStub.dimmedValue = false
        focusViewStub.stageText = "专注中"
        focusViewStub.titleText = "写周报"
        focusViewStub.canStart = true
        focusViewStub.togglePauseCalls = 0
        focusViewStub.endPomodoroCalls = 0
        focusViewStub.startBreakCalls = 0
        focusViewStub.startPomodoroCalls = 0
        focusViewStub.endFreeFocusCalls = 0
        timerStub.isRunning = true
        timerStub.hasActiveSession = true
        timerStub.phase = 1
        settingsStub.reduceMotion = false
        settingsStub.slimClockFont = true
        settingsStub.soundEnabled = true
        overlay.controlsRevealed = false
        overlay.active = true
        exitSpy.clear()
        wait(20)
    }

    function test_backdropUsesGlassToken() {
        const backdrop = findChild(overlay, "immersiveBackdrop")
        verify(backdrop)
        verify(Qt.colorEqual(backdrop.color, Theme.glassCard))
    }

    function test_pomoWorkProjectsRingAndTexts() {
        const ring = findChild(overlay, "immersiveRing")
        verify(ring)
        compare(ring.showPreview, false)
        compare(ring.dimmed, false)
        verify(Math.abs(ring.progress - 0.5) < 0.001)
        verify(Qt.colorEqual(ring.ringColor, Theme.accent))

        const time = findChild(overlay, "immersiveRingTimeText")
        verify(time)
        compare(time.text, "12:34")
        compare(time.font.family, Theme.fontFamilyClock)

        const title = findChild(overlay, "immersiveTaskText")
        verify(title)
        compare(title.text, "写周报")

        const stage = findChild(overlay, "immersiveStageText")
        verify(stage)
        compare(stage.text, "专注中")

        compare(overlay.projectedState, "pomoWork")
        compare(overlay.completionState, false)
        compare(overlay.projectable, true)
    }

    function test_freeProjectsBigClock() {
        focusViewStub.state = "free"
        focusViewStub.timeText = "01:02:03"
        wait(20)

        const freeTime = findChild(overlay, "immersiveFreeTimeText")
        verify(freeTime)
        compare(freeTime.text, "01:02:03")

        const stage = findChild(overlay, "immersiveStageText")
        verify(stage)
        compare(stage.text, "专注进行中")

        compare(overlay.projectable, true)
    }

    function test_completionShowsBanner() {
        focusViewStub.state = "workDone"
        focusViewStub.stageText = "专注完成"
        focusViewStub.progressValue = 1
        focusViewStub.ringColorValue = Theme.success
        wait(20)

        compare(overlay.completionState, true)

        const banner = findChild(overlay, "immersiveBannerText")
        verify(banner)
        compare(banner.text, "专注完成")

        const ring = findChild(overlay, "immersiveRing")
        verify(ring)
        compare(ring.progress, 1)
        verify(Qt.colorEqual(ring.ringColor, Theme.success))
    }

    function test_errorTextProjected() {
        focusViewStub.errorText = "番茄结束失败，请重试"
        wait(20)

        const error = findChild(overlay, "immersiveErrorText")
        verify(error)
        compare(error.text, "番茄结束失败，请重试")
        verify(Qt.colorEqual(error.color, Theme.danger))
    }

    function test_sessionPausedAcrossStates() {
        timerStub.isRunning = false
        compare(overlay.sessionPaused, true)

        focusViewStub.state = "free"
        compare(overlay.sessionPaused, true)

        timerStub.hasActiveSession = false
        compare(overlay.sessionPaused, false)

        focusViewStub.state = "workDone"
        compare(overlay.sessionPaused, false)
    }

    function test_projectableRejectsIdleAndEmptyFree() {
        focusViewStub.state = "pomoIdle"
        compare(overlay.projectable, false)

        focusViewStub.state = "free"
        timerStub.hasActiveSession = false
        compare(overlay.projectable, false)

        focusViewStub.state = "breakDone"
        compare(overlay.projectable, true)
    }

    function test_clockFollowsSlimSetting() {
        const time = findChild(overlay, "immersiveRingTimeText")
        verify(time)
        compare(time.font.weight, Font.Light)

        settingsStub.slimClockFont = false
        compare(time.font.weight, Font.Medium)
    }

    function test_revealControlsStartsHideCountdown() {
        compare(overlay.controlsRevealed, false)
        overlay.revealControls()
        compare(overlay.controlsRevealed, true)
        compare(overlay.hideTimerRunning, true)

        overlay.hideControls()
        compare(overlay.controlsRevealed, false)
        compare(overlay.controlsShown, false)
    }

    function test_controlsPinnedWhenPausedOrDone() {
        compare(overlay.controlsPinned, false)

        timerStub.isRunning = false
        compare(overlay.controlsPinned, true)
        compare(overlay.controlsShown, true)

        timerStub.isRunning = true
        focusViewStub.state = "breakDone"
        compare(overlay.controlsPinned, true)

        focusViewStub.state = "pomoWork"
        compare(overlay.controlsPinned, false)
    }

    function test_cursorHidesWithControls() {
        const hover = findChild(overlay, "immersiveHoverArea")
        verify(hover)
        compare(hover.cursorShape, Qt.BlankCursor)

        overlay.revealControls()
        compare(hover.cursorShape, Qt.ArrowCursor)
    }

    function test_fadeAnimatedFollowsReduceMotion() {
        compare(overlay.fadeAnimated, true)
        settingsStub.reduceMotion = true
        compare(overlay.fadeAnimated, false)
    }

    function test_buttonMappingPerState() {
        compare(overlay.primaryButtonText, "暂停")
        compare(overlay.primaryButtonEnabled, true)
        compare(overlay.secondaryButtonText, "结束")

        timerStub.isRunning = false
        compare(overlay.primaryButtonText, "继续")

        timerStub.isRunning = true
        focusViewStub.state = "pomoBreak"
        compare(overlay.secondaryButtonText, "跳过休息")

        focusViewStub.state = "free"
        compare(overlay.secondaryButtonText, "结束专注")
        compare(overlay.primaryButtonEnabled, true)
        timerStub.hasActiveSession = false
        compare(overlay.primaryButtonEnabled, false)

        timerStub.hasActiveSession = true
        focusViewStub.state = "workDone"
        compare(overlay.primaryButtonText, "开始休息")
        compare(overlay.primaryButtonEnabled, true)

        focusViewStub.state = "breakDone"
        compare(overlay.primaryButtonText, "开始专注")
        compare(overlay.primaryButtonEnabled, true)
        focusViewStub.canStart = false
        compare(overlay.primaryButtonEnabled, false)
    }

    function test_actionsForwardToFocusView() {
        overlay.triggerPrimary()
        compare(focusViewStub.togglePauseCalls, 1)

        overlay.triggerSecondary()
        compare(focusViewStub.endPomodoroCalls, 1)

        focusViewStub.state = "workDone"
        overlay.triggerPrimary()
        compare(focusViewStub.startBreakCalls, 1)

        focusViewStub.state = "breakDone"
        overlay.triggerPrimary()
        compare(focusViewStub.startPomodoroCalls, 1)

        focusViewStub.state = "free"
        overlay.triggerSecondary()
        compare(focusViewStub.endFreeFocusCalls, 1)
    }

    function test_exitPathsEmitSignal() {
        overlay.requestExit()
        compare(exitSpy.count, 1)

        const exitButton = findChild(overlay, "immersiveExitButton")
        verify(exitButton)
        exitButton.clicked()
        compare(exitSpy.count, 2)
    }

    function test_soundButtonFlipsSetting() {
        const sound = findChild(overlay, "immersiveSoundButton")
        verify(sound)
        sound.clicked()
        compare(settingsStub.soundEnabled, false)
        sound.clicked()
        compare(settingsStub.soundEnabled, true)
    }

    function test_unprojectableStateAutoExits() {
        focusViewStub.state = "pomoIdle"
        wait(20)
        compare(exitSpy.count, 1)
    }

    function test_activationIntoUnprojectableStateAutoExits() {
        overlay.active = false
        focusViewStub.state = "pomoIdle"
        wait(20)
        exitSpy.clear()

        overlay.active = true
        wait(20)
        compare(exitSpy.count, 1)
    }
}
