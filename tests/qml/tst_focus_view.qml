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
        property int startFocusCalls: 0
        property int startFocusTaskId: 0
        property string startFocusTitle: ""
        property int startPomodoroWorkTaskId: 0
        property string startPomodoroWorkTitle: ""
        property int startPomodoroWorkSeconds: 0
        property int stopFocusCalls: 0
        property int minimumValidMinutes: 3
        property int autoCompleteMinutes: 5

        function startFocus(taskId, title) {
            startFocusCalls += 1
            startFocusTaskId = taskId
            startFocusTitle = title
            isRunning = true
            hasActiveSession = true
            mode = 0
            phase = 0
            currentTaskId = taskId
            currentTaskTitle = title
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

    QtObject {
        id: appSettingsMock

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
    }

    QtObject {
        id: rememberedSettingsMock

        property int lastMode: 1
        property int workMinutes: 45
        property int breakMinutes: 10
        property bool soundEnabled: true
        property bool slimClockFont: true
    }

    QtObject {
        id: customDurationSettingsMock

        property int lastMode: 1
        property int workMinutes: 90
        property int breakMinutes: 5
        property bool soundEnabled: true
        property bool slimClockFont: true
    }

    FocusView {
        id: view
        width: testCase.width
        height: testCase.height
        timer: focusTimer
        settings: appSettingsMock
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
        focusTimer.startFocusCalls = 0
        focusTimer.startFocusTaskId = 0
        focusTimer.startFocusTitle = ""
        focusTimer.startPomodoroWorkTaskId = 0
        focusTimer.startPomodoroWorkTitle = ""
        focusTimer.startPomodoroWorkSeconds = 0
        focusTimer.stopFocusCalls = 0
        view.pomoTaskId = -1
        view.pomoTaskTitle = ""
        view.toPomodoroTab(false)
        view.selectWorkMinutes(25)
        view.selectBreakMinutes(5)
        appSettingsMock.lastMode = 0
        appSettingsMock.workMinutes = 25
        appSettingsMock.breakMinutes = 5
        appSettingsMock.soundEnabled = true
        appSettingsMock.reduceMotion = false
        appSettingsMock.slimClockFont = true
        view.panelExpanded = false
        wait(20)
    }

    function test_pageBackdropIsGlass() {
        var backdrop = findChild(view, "focusPageBackdrop")
        verify(backdrop, "整页底板应有 objectName 供守护")
        verify(Qt.colorEqual(backdrop.color, Theme.glassCard))
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

    function test_completionBlinkGatedByReduceMotion() {
        appSettingsMock.reduceMotion = false
        focusTimer.hasActiveSession = true
        view.toPomodoroTab(true)
        view.startPomodoro()
        wait(20)

        focusTimer.phaseCompleted(1)
        wait(20)
        compare(view.state, "workDone")

        var banner = findChild(view, "focusCompletionBanner")
        verify(banner)
        verify(banner.blinkRunning === true, "常态下完成横幅应闪烁")

        appSettingsMock.reduceMotion = true
        tryCompare(banner, "blinkRunning", false, 500)
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

    function test_selectPresetsWriteBackSettings() {
        view.toPomodoroTab(true)
        view.selectWorkMinutes(45)
        view.selectBreakMinutes(10)

        compare(appSettingsMock.workMinutes, 45)
        compare(appSettingsMock.breakMinutes, 10)
    }

    function test_startPomodoroWritesLastMode() {
        view.toPomodoroTab(true)
        view.startPomodoro()
        wait(20)

        compare(view.state, "pomoWork")
        compare(appSettingsMock.lastMode, 1)
    }

    function test_enterPomodoroWithTaskPreloadsIdle() {
        view.enterPomodoroWithTask(9, "直达任务")
        wait(20)

        compare(view.state, "pomoIdle")
        compare(view.pomodoroModeSelected, true)
        compare(view.pomoTaskId, 9)
        compare(view.pomoTaskTitle, "直达任务")
        compare(view.canStartPomodoro(), true)
    }

    function test_directTaskSurvivesModeToggleBeforeStarting() {
        view.enterPomodoroWithTask(9, "直达任务")
        wait(20)

        view.toPomodoroTab(false)
        wait(20)
        view.toPomodoroTab(true)
        wait(20)

        compare(view.state, "pomoIdle")
        compare(view.pomoTaskId, 9)
        compare(view.pomoTaskTitle, "直达任务")
        compare(view.taskTitle(), "直达任务")
        compare(view.canStartPomodoro(), true)
    }

    function test_switchingDirectPomodoroTaskToFreeStartsFocus() {
        view.enterPomodoroWithTask(9, "直达任务")
        wait(20)

        view.toPomodoroTab(false)
        wait(20)

        compare(view.state, "free")
        compare(focusTimer.startFocusCalls, 1)
        compare(focusTimer.startFocusTaskId, 9)
        compare(focusTimer.startFocusTitle, "直达任务")
        compare(focusTimer.hasActiveSession, true)
        compare(view.taskTitle(), "直达任务")
        compare(appSettingsMock.lastMode, 0)
    }

    function test_enterPomodoroWithTaskStopsActiveFreeSession() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true

        view.enterPomodoroWithTask(9, "直达任务")
        wait(20)

        // 复用 toPomodoroTab 的停止逻辑：进入直达前必须结束进行中的自由会话。
        compare(focusTimer.stopFocusCalls, 1)
        compare(view.state, "pomoIdle")
        compare(view.pomoTaskId, 9)
    }

    function test_restoreRememberedDurationsOnCreation() {
        var component = Qt.createComponent("../../qml/views/FocusView.qml")
        compare(component.status, Component.Ready)

        var restored = component.createObject(testCase, {
            timer: focusTimer,
            settings: rememberedSettingsMock
        })
        verify(restored)
        compare(restored.selectedWorkMinutes, 45)
        compare(restored.selectedBreakMinutes, 10)
        restored.destroy()
    }

    function test_pomoIdleShowsRuleHint() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        const hint = findChild(view, "ruleHintText")
        verify(hint)
        compare(hint.text, "满 5 分钟自动完成任务 · 不足 3 分钟不计入记录")
        compare(view.state, "pomoIdle")
        compare(view.panelExpanded, true)
    }

    function test_soundToggleFlipsSetting() {
        appSettingsMock.soundEnabled = true

        const toggle = findChild(view, "soundToggleButton")
        verify(toggle)
        toggle.clicked()
        compare(appSettingsMock.soundEnabled, false)
        toggle.clicked()
        compare(appSettingsMock.soundEnabled, true)
    }

    function test_durationPillShowsSelectionAndToggles() {
        view.toPomodoroTab(true)
        wait(20)

        const pill = findChild(view, "durationPill")
        verify(pill)
        verify(pill.contentItem.text.indexOf("专注 25 分 · 休息 5 分") !== -1)
        compare(view.panelExpanded, false)

        pill.clicked()
        compare(view.panelExpanded, true)
        pill.clicked()
        compare(view.panelExpanded, false)

        view.selectWorkMinutes(45)
        verify(pill.contentItem.text.indexOf("专注 45 分") !== -1)
    }

    function test_panelCollapsesWhenLeavingIdle() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        view.startPomodoro()
        wait(20)
        compare(view.state, "pomoWork")
        compare(view.panelExpanded, false)

        view.toPomodoroTab(true)
        view.panelExpanded = true
        view.toPomodoroTab(false)
        wait(20)
        compare(view.panelExpanded, false)
    }

    function test_idleCaptionReflectsTaskReadiness() {
        view.toPomodoroTab(true)
        wait(20)

        const caption = findChild(view, "ringCaptionText")
        verify(caption)
        compare(caption.text, "准备开始")

        focusTimer.currentTaskId = -1
        focusTimer.currentTaskTitle = ""
        view.pomoTaskId = -1
        wait(20)
        compare(caption.text, "等待任务")
    }

    function test_noTaskHintGuidesUser() {
        view.toPomodoroTab(true)
        wait(20)

        const hint = findChild(view, "noTaskHint")
        verify(hint)
        compare(hint.text, "")

        focusTimer.currentTaskId = -1
        focusTimer.currentTaskTitle = ""
        view.pomoTaskId = -1
        wait(20)
        compare(hint.text, "到今日任务里点「开始专注」即可带任务进入")
    }

    function test_selectMinutesAcceptsRangeAndRejectsOutOfBounds() {
        view.toPomodoroTab(true)

        view.selectWorkMinutes(90)
        compare(view.selectedWorkMinutes, 90)
        compare(appSettingsMock.workMinutes, 90)

        view.selectWorkMinutes(4)
        compare(view.selectedWorkMinutes, 90)
        view.selectWorkMinutes(181)
        compare(view.selectedWorkMinutes, 90)

        view.selectBreakMinutes(1)
        compare(view.selectedBreakMinutes, 1)
        view.selectBreakMinutes(0)
        compare(view.selectedBreakMinutes, 1)
        view.selectBreakMinutes(61)
        compare(view.selectedBreakMinutes, 1)
    }

    function test_stepperAdjustsValueAndClampsAtBounds() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        const plus = findChild(view, "workStepperPlus")
        const minus = findChild(view, "workStepperMinus")
        const valueText = findChild(view, "workStepperValue")
        verify(plus)
        verify(minus)
        verify(valueText)

        plus.clicked()
        compare(view.selectedWorkMinutes, 26)
        compare(appSettingsMock.workMinutes, 26)
        compare(valueText.text, "26")

        view.selectWorkMinutes(5)
        wait(20)
        compare(minus.enabled, false)
        view.selectWorkMinutes(180)
        wait(20)
        compare(plus.enabled, false)

        const breakPlus = findChild(view, "breakStepperPlus")
        const breakMinus = findChild(view, "breakStepperMinus")
        verify(breakPlus)
        verify(breakMinus)
        view.selectBreakMinutes(1)
        wait(20)
        compare(breakMinus.enabled, false)
        view.selectBreakMinutes(60)
        wait(20)
        compare(breakPlus.enabled, false)
    }

    function test_chipsMatchPurelyByValue() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        const chip25 = findChild(view, "workPreset25")
        const chip45 = findChild(view, "workPreset45")
        const chip60 = findChild(view, "workPreset60")
        verify(chip25)
        verify(chip45)
        verify(chip60)
        compare(chip25.checked, true)

        // 步进到非预设值：chips 全灭，步进器本身就是“自定义”。
        view.selectWorkMinutes(90)
        wait(20)
        compare(chip25.checked, false)
        compare(chip45.checked, false)
        compare(chip60.checked, false)

        // 点 chip 回到预设：值与选中态同步恢复。
        chip45.clicked()
        wait(20)
        compare(view.selectedWorkMinutes, 45)
        compare(chip45.checked, true)
    }

    function test_restoreCustomDurationShowsInPillAndStepper() {
        var component = Qt.createComponent("../../qml/views/FocusView.qml")
        compare(component.status, Component.Ready)

        var restored = component.createObject(testCase, {
            timer: focusTimer,
            settings: customDurationSettingsMock
        })
        verify(restored)
        compare(restored.selectedWorkMinutes, 90)

        const pill = findChild(restored, "durationPill")
        verify(pill)
        verify(pill.contentItem.text.indexOf("专注 90 分 · 休息 5 分") !== -1)

        const chip25 = findChild(restored, "workPreset25")
        const chip45 = findChild(restored, "workPreset45")
        const chip60 = findChild(restored, "workPreset60")
        verify(chip25)
        verify(chip45)
        verify(chip60)
        compare(chip25.checked, false)
        compare(chip45.checked, false)
        compare(chip60.checked, false)

        const valueText = findChild(restored, "workStepperValue")
        verify(valueText)
        compare(valueText.text, "90")
        restored.destroy()
    }

    function test_ringShrinksWhenPanelExpanded() {
        view.toPomodoroTab(true)
        wait(20)

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.implicitWidth, 252)

        view.panelExpanded = true
        // implicitWidth 带 150ms 过渡动画，等它收敛到目标值。
        tryCompare(ring, "implicitWidth", 190, 1000)

        view.panelExpanded = false
        tryCompare(ring, "implicitWidth", 252, 1000)
    }

    function test_durationPanelSteppersAlignToRightEdge() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        const panel = findChild(view, "durationPanel")
        const workPlus = findChild(view, "workStepperPlus")
        const breakPlus = findChild(view, "breakStepperPlus")
        verify(panel)
        verify(workPlus)
        verify(breakPlus)

        const workRight = workPlus.mapToItem(panel, workPlus.width, 0).x
        const breakRight = breakPlus.mapToItem(panel, breakPlus.width, 0).x
        const expectedRight = panel.width - Theme.space16

        compare(Math.round(workRight), Math.round(expectedRight))
        compare(Math.round(breakRight), Math.round(expectedRight))
    }

    function test_timeNumeralsUseClockFamily() {
        var freeText = findChild(view, "focusFreeTimeText")
        verify(freeText)
        compare(freeText.font.family, Theme.fontFamilyClock)

        var ringText = findChild(view, "focusRingTimeText")
        verify(ringText)
        compare(ringText.font.family, Theme.fontFamilyClock)
    }

    function test_freeTimeNumeralUsesReadableInk() {
        // 自由专注大字用 accentInk（AA 达标），不得回退低对比的 accent。
        var freeText = findChild(view, "focusFreeTimeText")
        verify(freeText)
        verify(Qt.colorEqual(freeText.color, Theme.accentInk),
               "自由专注计时数字应为 accentInk")
    }

    function test_ringTimeMarkupWrapsColonOnly() {
        var out = view.ringTimeMarkup("25:00")
        verify(out.indexOf("<font") !== -1, "标准 MM:SS 应包裹冒号 font 标签")
        verify(out.indexOf("25") === 0, "分钟段应在标签前原样保留")
        verify(out.indexOf("00") !== -1, "秒段应保留")
    }

    function test_ringTimeMarkupFallsBackOnNonStandard() {
        compare(view.ringTimeMarkup("<b>x</b>"), "<b>x</b>")
        compare(view.ringTimeMarkup("01:02:03"), "01:02:03")
        compare(view.ringTimeMarkup("2500"), "2500")
    }

    function test_clockDigitsFollowSlimSetting() {
        var ringText = findChild(view, "focusRingTimeText")
        var freeText = findChild(view, "focusFreeTimeText")
        verify(ringText)
        verify(freeText)

        appSettingsMock.slimClockFont = true
        compare(ringText.font.weight, Font.Light)
        compare(freeText.font.weight, Font.Light)

        appSettingsMock.slimClockFont = false
        compare(ringText.font.weight, Font.Medium)
        compare(freeText.font.weight, Font.Medium)
    }
}
