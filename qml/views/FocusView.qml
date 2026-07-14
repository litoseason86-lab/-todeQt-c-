import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."
import "../components"

Item {
    id: root

    property var timer: null
    property var settings: null
    property string errorText: ""
    property bool pomodoroModeSelected: false
    property int selectedWorkMinutes: 25
    property int selectedBreakMinutes: 5
    // 任务页传入的待启动任务由专注页暂存；真正点击开始后，活动任务以 timer 为准。
    property int selectedTaskId: -1
    property string selectedTaskTitle: ""
    property int justCompletedPhase: 0
    property bool panelExpanded: false

    signal focusEnded()
    signal immersiveRequested()

    // 沉浸入口只在计时进行中（含暂停）开放：待机/完成/未开始要么需要配置面板，
    // 要么即将离开专注页，极简全屏没有意义。
    readonly property bool immersiveAvailable: state === "pomoWork" || state === "pomoBreak"
            || (state === "free" && timerBool("hasActiveSession"))

    state: root.computeState()

    onStateChanged: {
        // 离开待机态就收起配置面板：回到待机永远从干净的收起态开始，
        // 也顺带覆盖“成功启动专注后收起”这个边界。
        if (state !== "pomoIdle") {
            panelExpanded = false
        }
    }

    Component.onCompleted: {
        // 恢复上次记住的时长；无效值会被 select 函数的范围校验挡掉，回落默认。
        if (root.settings) {
            root.selectWorkMinutes(Number(root.settings.workMinutes))
            root.selectBreakMinutes(Number(root.settings.breakMinutes))
        }
    }

    function safeSeconds(value) {
        // 计时显示只接受非负秒数，避免服务异常值污染 UI。
        return Math.max(0, Number(value || 0))
    }

    function formatTime(seconds) {
        var safe = root.safeSeconds(seconds)
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    function formatMinuteTime(seconds) {
        var safe = root.safeSeconds(seconds)
        var minutes = Math.floor(safe / 60)
        var secs = safe % 60
        return (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    function timerNumber(name, fallbackValue) {
        return root.timer ? Number(root.timer[name] || fallbackValue) : fallbackValue
    }

    function timerBool(name) {
        return root.timer ? Boolean(root.timer[name]) : false
    }

    function timerTitle() {
        return root.timer && root.timer.currentTaskTitle ? root.timer.currentTaskTitle : ""
    }

    function taskTitle() {
        if (root.timerBool("hasActiveSession") && root.timerTitle().length > 0) {
            return root.timerTitle()
        }
        if (root.selectedTaskTitle.length > 0) {
            return root.selectedTaskTitle
        }
        return root.pomodoroModeSelected ? "尚未选择任务" : "尚未开始专注"
    }

    function pomodoroTitle() {
        if (root.selectedTaskTitle.length > 0) {
            return root.selectedTaskTitle
        }
        if (root.timerTitle().length > 0) {
            return root.timerTitle()
        }
        return "番茄专注"
    }

    function clearSelectedTask() {
        root.selectedTaskId = -1
        root.selectedTaskTitle = ""
    }

    function syncToActiveTimer() {
        if (!root.timer || (!root.timer.hasActiveSession && root.timer.phase === 0)) {
            return
        }

        // 计时开始后，服务才是唯一事实源；本地模式和待机缓存只能服务于尚未开始的状态。
        var timerUsesPomodoro = root.timer.mode === 1 || root.timer.phase !== 0
        root.pomodoroModeSelected = timerUsesPomodoro
        if (!timerUsesPomodoro) {
            root.selectedTaskId = root.timer.currentTaskId
            root.selectedTaskTitle = root.timer.currentTaskTitle || ""
            return
        }

        // 休息阶段没有任务 id，保留刚完成工作阶段的缓存，供下一轮继续使用。
        if (root.timer.currentTaskId > 0) {
            root.selectedTaskId = root.timer.currentTaskId
        }
        if (root.timer.currentTaskTitle && root.timer.currentTaskTitle.length > 0) {
            root.selectedTaskTitle = root.timer.currentTaskTitle
        }
    }

    function computeState() {
        if (!root.timer) {
            return "free"
        }

        if (!root.pomodoroModeSelected) {
            return "free"
        }
        if (root.justCompletedPhase === 1) {
            return "workDone"
        }
        if (root.justCompletedPhase === 2) {
            return "breakDone"
        }
        if (root.timerNumber("mode", 0) === 1 && root.timerNumber("phase", 0) === 1) {
            return "pomoWork"
        }
        if (root.timerNumber("mode", 0) === 1 && root.timerNumber("phase", 0) === 2) {
            return "pomoBreak"
        }
        return "pomoIdle"
    }

    function toPomodoroTab(enabled) {
        if (!root.timer) {
            root.pomodoroModeSelected = enabled
            root.justCompletedPhase = 0
            return
        }

        if (enabled) {
            var timerHasSession = root.timer.hasActiveSession || root.timer.phase !== 0
            var shouldUseTimerTask = timerHasSession || root.selectedTaskId <= 0
            // 只有正在切换真实计时会话，或本地没有“从任务页直达”的显式选择时，
            // 才从 timer 覆盖缓存；否则会把用户刚点的任务替换成 timer 里的旧值。
            if (shouldUseTimerTask && root.timer.currentTaskId > 0) {
                root.selectedTaskId = root.timer.currentTaskId
            }
            if (shouldUseTimerTask && root.timer.currentTaskTitle && root.timer.currentTaskTitle.length > 0) {
                root.selectedTaskTitle = root.timer.currentTaskTitle
            }
            if (timerHasSession) {
                if (!root.timer.stopFocus()) {
                    root.errorText = "切换番茄失败，请重试"
                    return
                }
            }
        } else {
            var hasRunningTimer = root.timer.hasActiveSession || root.timer.phase !== 0
            if (hasRunningTimer && !root.timer.stopFocus()) {
                root.errorText = "结束当前阶段失败，请重试"
                return
            }
        }

        root.pomodoroModeSelected = enabled
        root.errorText = ""
        root.justCompletedPhase = 0
    }

    function enterPomodoroWithTask(taskId, title) {
        var safeTitle = String(title || "").trim()
        if (!root.timer || taskId <= 0 || safeTitle.length === 0) {
            root.errorText = "番茄任务无效，请重试"
            return false
        }

        // 外部任务选择是新的明确意图，必须一次性替换模式和任务缓存。
        // 不复用 toPomodoroTab：它面向页内切换，会优先保留旧缓存，正是任务错位的来源。
        if ((root.timer.hasActiveSession || root.timer.phase !== 0) && !root.timer.stopFocus()) {
            root.errorText = "切换番茄失败，请重试"
            return false
        }

        root.pomodoroModeSelected = true
        root.selectedTaskId = taskId
        root.selectedTaskTitle = safeTitle
        root.errorText = ""
        root.justCompletedPhase = 0
        return true
    }

    function enterFreeWithTask(taskId, title) {
        var safeTitle = String(title || "").trim()
        if (!root.timer || taskId <= 0 || safeTitle.length === 0) {
            root.errorText = "自由专注任务无效，请重试"
            return false
        }
        if (root.timer.hasActiveSession || root.timer.phase !== 0) {
            root.errorText = "已有专注进行中"
            return false
        }
        root.pomodoroModeSelected = false
        root.selectedTaskId = taskId
        root.selectedTaskTitle = safeTitle
        root.errorText = ""
        root.justCompletedPhase = 0
        return true
    }

    function enterWithTask(taskId, title, usePomodoro) {
        // 所有任务页统一走这一入口，只选择任务和模式；计时器只能由本页开始按钮启动。
        return usePomodoro
                ? root.enterPomodoroWithTask(taskId, title)
                : root.enterFreeWithTask(taskId, title)
    }

    function selectWorkMinutes(minutes) {
        var value = Math.round(Number(minutes))
        // 范围而非白名单：自定义时长和预设都走同一入口，持久化逻辑才能保持一致。
        if (value >= 5 && value <= 180) {
            root.selectedWorkMinutes = value
            if (root.settings) {
                root.settings.workMinutes = value
            }
        }
    }

    function selectBreakMinutes(minutes) {
        var value = Math.round(Number(minutes))
        if (value >= 1 && value <= 60) {
            root.selectedBreakMinutes = value
            if (root.settings) {
                root.settings.breakMinutes = value
            }
        }
    }

    function canStartPomodoro() {
        if (!root.timer) {
            return false
        }
        return (root.selectedTaskId > 0 && root.selectedTaskTitle.length > 0)
                || (root.timerNumber("currentTaskId", -1) > 0 && root.timerTitle().length > 0)
    }

    function canStartFreeFocus() {
        return root.timer !== null
                && !root.timerBool("hasActiveSession")
                && root.timerNumber("phase", 0) === 0
                && root.selectedTaskId > 0
                && root.selectedTaskTitle.length > 0
    }

    function startFreeFocus() {
        if (!root.canStartFreeFocus()) {
            root.errorText = "请先选择要专注的任务"
            return false
        }
        if (!root.timer.startFocus(root.selectedTaskId, root.selectedTaskTitle)) {
            root.errorText = "自由专注启动失败，请重试"
            return false
        }

        root.errorText = ""
        root.justCompletedPhase = 0
        if (root.settings) {
            root.settings.lastMode = 0
        }
        return true
    }

    function startPomodoro() {
        root.justCompletedPhase = 0
        var taskId = root.selectedTaskId > 0 ? root.selectedTaskId : (root.timer ? root.timer.currentTaskId : -1)
        var taskTitle = root.pomodoroTitle()
        if (!root.timer) {
            root.errorText = "番茄专注启动失败"
            return
        }
        if (taskId > 0 && root.timer.startPomodoroWork(taskId, taskTitle, root.selectedWorkMinutes * 60)) {
            root.errorText = ""
            // 只在真正启动番茄后记忆模式；单纯切到番茄页不改变用户偏好。
            if (root.settings) {
                root.settings.lastMode = 1
            }
        } else {
            root.errorText = "番茄专注启动失败"
        }
    }

    function nextBreakMinutes() {
        // 长休息：每完成 N 个番茄，这一次休息更久。连续数由 FocusTimer 维护（只计自然到点的番茄），
        // 手动和自动开始休息共用同一判定，行为一致。
        if (root.settings && root.settings.longBreakEnabled && root.timer
                && root.settings.longBreakInterval > 0
                && root.timer.completedPomodoros > 0
                && (root.timer.completedPomodoros % root.settings.longBreakInterval) === 0) {
            return root.settings.longBreakMinutes
        }
        return root.selectedBreakMinutes
    }

    function startBreak() {
        root.justCompletedPhase = 0
        if (root.timer && root.timer.startBreak(root.nextBreakMinutes() * 60)) {
            root.errorText = ""
        } else {
            root.errorText = "休息启动失败"
        }
    }

    function togglePause() {
        if (!root.timer) {
            root.errorText = "专注恢复失败"
            return
        }
        if (root.timer.isRunning) {
            root.timer.pauseFocus()
            return
        }
        if (!root.timer.resumeFocus()) {
            root.errorText = "专注恢复失败"
        } else {
            root.errorText = ""
        }
    }

    function endPomodoro() {
        if (!root.timer) {
            root.clearSelectedTask()
            root.focusEnded()
            return
        }
        var shouldStopTimer = root.timer.phase !== 0 || root.timer.hasActiveSession

        // 休息段不会创建数据库会话，hasActiveSession 为 false 仍必须允许结束计时器。
        if (shouldStopTimer && !root.timer.stopFocus()) {
            root.errorText = "番茄结束失败，请重试"
            return
        }

        root.errorText = ""
        root.justCompletedPhase = 0
        // 完全结束番茄循环：连续计数归零，下一轮长休息节奏从头开始。
        root.timer.resetPomodoroCount()
        root.clearSelectedTask()
        root.focusEnded()
    }

    function endFreeFocus() {
        // 自由模式结束逻辑单点：页面按钮与沉浸层共用，避免两处复制。
        if (root.timer && root.timer.stopFocus()) {
            root.errorText = ""
            root.clearSelectedTask()
            root.focusEnded()
        } else {
            root.errorText = "专注保存失败，请重试"
        }
    }

    Connections {
        target: root.timer
        ignoreUnknownSignals: true

        function onCurrentTaskChanged() {
            root.syncToActiveTimer()
        }

        function onModeChanged() {
            root.syncToActiveTimer()
        }

        function onPhaseChanged() {
            root.syncToActiveTimer()
        }

        function onPhaseCompleted(phase) {
            root.justCompletedPhase = phase
            // 自动衔接（可选，默认关）：延一小段再切，让用户看清完成态、听到提示音后再进入下一阶段。
            var wantsAuto = root.settings
                    && ((phase === 1 && root.settings.autoStartBreak)
                        || (phase === 2 && root.settings.autoStartNextPomodoro))
            if (wantsAuto) {
                autoAdvanceTimer.pendingPhase = phase
                autoAdvanceTimer.restart()
            }
        }
    }

    // 自动衔接的延迟切换：减少动效时立即切，否则留 0.9s 缓冲。
    Timer {
        id: autoAdvanceTimer

        property int pendingPhase: 0

        interval: (root.settings && root.settings.reduceMotion) ? 0 : 900
        repeat: false
        onTriggered: {
            if (autoAdvanceTimer.pendingPhase === 1) {
                root.startBreak()
            } else if (autoAdvanceTimer.pendingPhase === 2) {
                root.startPomodoro()
            }
        }
    }

    states: [
        State { name: "free" },
        State { name: "pomoIdle" },
        State { name: "pomoWork" },
        State { name: "workDone" },
        State { name: "pomoBreak" },
        State { name: "breakDone" }
    ]

    Rectangle {
        objectName: "focusPageBackdrop"

        anchors.fill: parent
        // 整页一块玻璃底板透出壁纸；不做“中央列包卡”的结构手术：
        // 专注页状态机复杂，玻璃化只换材质、不动布局。
        color: Theme.glassCard

        ColumnLayout {
            width: Math.min(parent.width - 96, 560)
            spacing: root.state === "pomoIdle" ? Theme.space16 : Theme.space24

            anchors {
                horizontalCenter: parent.horizontalCenter
                verticalCenter: parent.verticalCenter
                verticalCenterOffset: root.state === "pomoIdle" ? -28 : 0
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.space8

                ButtonGroup {
                    id: modeGroup
                    exclusive: true
                }

                Button {
                    id: freeModeButton
                    text: "自由专注"
                    checkable: true
                    checked: !root.pomodoroModeSelected
                    ButtonGroup.group: modeGroup
                    implicitWidth: 112
                    implicitHeight: 36
                    onClicked: root.toPomodoroTab(false)

                    background: Rectangle {
                        color: freeModeButton.checked ? Theme.accent : Theme.surfaceRaised
                        border.color: freeModeButton.checked ? Theme.accentStrong : Theme.border
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: freeModeButton.text
                        color: freeModeButton.checked ? Theme.surface : Theme.ink
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: pomodoroModeButton
                    text: "番茄"
                    checkable: true
                    checked: root.pomodoroModeSelected
                    ButtonGroup.group: modeGroup
                    implicitWidth: 112
                    implicitHeight: 36
                    onClicked: root.toPomodoroTab(true)

                    background: Rectangle {
                        color: pomodoroModeButton.checked ? Theme.accent : Theme.surfaceRaised
                        border.color: pomodoroModeButton.checked ? Theme.accentStrong : Theme.border
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: pomodoroModeButton.text
                        color: pomodoroModeButton.checked ? Theme.surface : Theme.ink
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                Text {
                    Layout.fillWidth: true
                    text: root.taskTitle()
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                    color: Theme.ink
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                Text {
                    objectName: "phaseStageText"
                    Layout.fillWidth: true
                    text: root.state === "free"
                          ? (root.timerBool("hasActiveSession") ? qsTr("当前任务") : qsTr("自由专注待机"))
                          : root.pomodoroStageText()
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Rectangle {
                id: completionBanner
                objectName: "focusCompletionBanner"
                // 不直接用 Item.visible 驱动动画：offscreen 测试和非当前 StackLayout 页面会让 effective visible 为 false。
                // 这里保留业务源条件，动画门控只看状态和减少动效开关。
                readonly property bool shouldShow: root.state === "workDone" || root.state === "breakDone"
                readonly property bool blinkRunning: completionBlink.running
                property real blinkOpacity: 1

                Layout.fillWidth: true
                Layout.preferredHeight: 44
                visible: completionBanner.shouldShow
                opacity: completionBanner.shouldShow
                         ? (completionBlink.running ? completionBanner.blinkOpacity : 1)
                         : 0
                color: Theme.accentSoft
                border.color: Theme.accent
                radius: Theme.radiusMd

                Text {
                    anchors.centerIn: parent
                    text: root.state === "workDone" ? "专注完成" : "休息结束"
                    font.pixelSize: Theme.fontLg
                    font.bold: true
                    color: Theme.inkStrong
                }

                NumberAnimation on blinkOpacity {
                    id: completionBlink

                    from: 0.35
                    to: 1
                    duration: 520
                    loops: Animation.Infinite
                    running: completionBanner.shouldShow && !(root.settings && root.settings.reduceMotion)

                }
            }

            Text {
                objectName: "focusFreeTimeText"
                Layout.fillWidth: true
                visible: root.state === "free"
                text: root.primaryTimeText()
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontDisplay
                font.family: Theme.fontFamilyClock
                font.weight: (root.settings && root.settings.slimClockFont) ? Font.Light : Font.Medium
                color: Theme.accentInk
                horizontalAlignment: Text.AlignHCenter
            }

            FocusRing {
                id: focusRing
                objectName: "focusRing"
                Layout.alignment: Qt.AlignHCenter
                visible: root.pomodoroModeSelected
                implicitWidth: root.state === "pomoIdle" && root.panelExpanded ? 190 : 252
                implicitHeight: implicitWidth
                showPreview: root.state === "pomoIdle"
                dimmed: root.ringDimmed()
                progress: root.ringProgressFraction()
                ringColor: root.ringColorForState()

                Behavior on implicitWidth {
                    NumberAnimation {
                        duration: 150
                        easing.type: Easing.OutQuad
                    }
                }

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Theme.space4

                    Text {
                        objectName: "focusRingTimeText"
                        Layout.alignment: Qt.AlignHCenter
                        text: root.ringTimeMarkup(root.primaryTimeText())
                        textFormat: Text.StyledText
                        font.pixelSize: root.state === "pomoIdle"
                                        ? (root.panelExpanded ? 42 : 56)
                                        : Theme.fontDisplay
                        font.family: Theme.fontFamilyClock
                        font.weight: (root.settings && root.settings.slimClockFont) ? Font.Light : Font.Medium
                        color: root.primaryTimeColor()
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        objectName: "ringCaptionText"
                        Layout.alignment: Qt.AlignHCenter
                        text: root.ringCaptionText()
                        font.pixelSize: Theme.fontMd
                        color: Theme.inkSoft
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.state === "free"
                text: root.runningText()
                font.pixelSize: Theme.fontLg
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
            }

            Button {
                id: durationPill
                objectName: "durationPill"
                Layout.alignment: Qt.AlignHCenter
                visible: root.state === "pomoIdle"
                implicitHeight: 36
                implicitWidth: pillLabel.implicitWidth + Theme.space24 * 2
                onClicked: root.panelExpanded = !root.panelExpanded

                background: Rectangle {
                    color: root.panelExpanded ? Theme.accentSoft : Theme.surfaceRaised
                    border.color: root.panelExpanded || durationPill.hovered ? Theme.accentStrong : Theme.border
                    border.width: 1
                    radius: height / 2
                }

                contentItem: Text {
                    id: pillLabel
                    text: "专注 " + root.selectedWorkMinutes + " 分 · 休息 " + root.selectedBreakMinutes + " 分  "
                          + (root.panelExpanded ? "▴" : "▾")
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Rectangle {
                id: durationPanel
                objectName: "durationPanel"
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(parent.width, 440)
                implicitHeight: panelColumn.implicitHeight + Theme.space16 * 2
                visible: root.state === "pomoIdle" && root.panelExpanded
                color: Theme.surfaceRaised
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusLg

                ColumnLayout {
                    id: panelColumn
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.space16
                    spacing: Theme.space8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space8

                        Text {
                            text: "专注"
                            textFormat: Text.PlainText
                            color: Theme.inkSoft
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: 32
                        }

                        PresetButton {
                            objectName: "workPreset25"
                            text: "25"
                            backgroundObjectName: "workPreset25Background"
                            checkable: false
                            checked: root.selectedWorkMinutes === 25
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectWorkMinutes(25)
                        }

                        PresetButton {
                            objectName: "workPreset45"
                            text: "45"
                            backgroundObjectName: "workPreset45Background"
                            checkable: false
                            checked: root.selectedWorkMinutes === 45
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectWorkMinutes(45)
                        }

                        PresetButton {
                            objectName: "workPreset60"
                            text: "60"
                            backgroundObjectName: "workPreset60Background"
                            checkable: false
                            checked: root.selectedWorkMinutes === 60
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectWorkMinutes(60)
                        }

                        Item {
                            // 专注行比休息行多一个 chip，不能用固定宽度硬凑；
                            // 弹性 spacer 把步进器稳定推到面板右内边距。
                            Layout.fillWidth: true
                        }

                        DurationStepper {
                            namePrefix: "workStepper"
                            value: root.selectedWorkMinutes
                            from: 5
                            to: 180
                            onAdjusted: function (newValue) {
                                root.selectWorkMinutes(newValue)
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space8

                        Text {
                            text: "休息"
                            textFormat: Text.PlainText
                            color: Theme.inkSoft
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: 32
                        }

                        PresetButton {
                            objectName: "breakPreset5"
                            text: "5"
                            backgroundObjectName: "breakPreset5Background"
                            checkable: false
                            checked: root.selectedBreakMinutes === 5
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectBreakMinutes(5)
                        }

                        PresetButton {
                            objectName: "breakPreset10"
                            text: "10"
                            backgroundObjectName: "breakPreset10Background"
                            checkable: false
                            checked: root.selectedBreakMinutes === 10
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectBreakMinutes(10)
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        DurationStepper {
                            namePrefix: "breakStepper"
                            value: root.selectedBreakMinutes
                            from: 1
                            to: 60
                            onAdjusted: function (newValue) {
                                root.selectBreakMinutes(newValue)
                            }
                        }
                    }
                }
            }

            Text {
                objectName: "ruleHintText"
                Layout.fillWidth: true
                visible: root.state === "pomoIdle" && root.panelExpanded
                text: "满 " + root.timerNumber("autoCompleteMinutes", 5) + " 分钟自动完成任务 · 不足 "
                      + root.timerNumber("minimumValidMinutes", 3) + " 分钟不计入记录"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.inkMuted
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                Layout.fillWidth: true
                visible: root.errorText.length > 0
                text: root.errorText
                font.pixelSize: Theme.fontMd
                color: Theme.danger
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.space16

                Button {
                    id: freeStartButton
                    objectName: "freeStartButton"

                    visible: root.state === "free" && !root.timerBool("hasActiveSession")
                    text: qsTr("开始专注")
                    enabled: root.canStartFreeFocus()
                    implicitWidth: 104
                    implicitHeight: 34
                    onClicked: root.startFreeFocus()

                    background: GlassPanel {
                        color: {
                            if (!freeStartButton.enabled)
                                return Theme.border
                            if (freeStartButton.pressed || freeStartButton.down)
                                return Theme.glassAccent
                            if (freeStartButton.hovered)
                                return Theme.glassHover
                            return Theme.glassCard
                        }
                        panelShadowEnabled: false
                    }

                    contentItem: Text {
                        text: freeStartButton.text
                        textFormat: Text.PlainText
                        color: freeStartButton.enabled ? Theme.accentInk : Theme.inkMuted
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: pauseButton
                    visible: (root.state === "free" && root.timerBool("hasActiveSession"))
                             || root.state === "pomoWork" || root.state === "pomoBreak"
                    text: root.timerBool("isRunning") ? "暂停" : "继续"
                    enabled: root.state === "free" ? root.timerBool("hasActiveSession") : root.timerNumber("phase", 0) !== 0
                    implicitWidth: 104
                    implicitHeight: 40

                    background: Rectangle {
                        color: pauseButton.enabled ? Theme.inkSoft : Theme.border
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: pauseButton.text
                        color: pauseButton.enabled ? Theme.surface : Theme.inkMuted
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: root.togglePause()
                }

                Button {
                    id: freeStopButton
                    visible: root.state === "free" && root.timerBool("hasActiveSession")
                    text: "结束专注"
                    enabled: root.timerBool("hasActiveSession")
                    implicitWidth: 104
                    implicitHeight: 40

                    background: Rectangle {
                        color: freeStopButton.enabled ? Theme.accent : Theme.border
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: freeStopButton.text
                        color: freeStopButton.enabled ? Theme.surface : Theme.inkMuted
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: root.endFreeFocus()
                }

                Button {
                    id: pomodoroStartButton
                    objectName: "pomodoroStartButton"
                    visible: root.state === "pomoIdle" || root.state === "breakDone"
                    text: root.state === "breakDone" ? "开始专注" : "开始专注"
                    enabled: root.canStartPomodoro()
                    // 与仪表盘/任务卡「开始专注」统一：104×34 + 玻璃基底。
                    implicitWidth: 104
                    implicitHeight: 34
                    onClicked: root.startPomodoro()

                    // 玻璃主按钮：半透明 glass 色阶 + 受光棱边，不用实心焦糖。
                    background: GlassPanel {
                        color: {
                            if (!pomodoroStartButton.enabled)
                                return Theme.border
                            if (pomodoroStartButton.pressed || pomodoroStartButton.down)
                                return Theme.glassAccent
                            if (pomodoroStartButton.hovered)
                                return Theme.glassHover
                            return Theme.glassCard
                        }
                        panelShadowEnabled: false

                        Behavior on color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }

                    contentItem: Text {
                        text: pomodoroStartButton.text
                        textFormat: Text.PlainText
                        color: pomodoroStartButton.enabled ? Theme.accentInk : Theme.inkMuted
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: startBreakButton
                    visible: root.state === "workDone"
                    text: "开始休息"
                    // 同主按钮规格，避免「开始休息」仍是实心焦糖块。
                    implicitWidth: 104
                    implicitHeight: 34
                    onClicked: root.startBreak()

                    background: GlassPanel {
                        color: startBreakButton.pressed || startBreakButton.down
                               ? Theme.glassAccent
                               : (startBreakButton.hovered ? Theme.glassHover : Theme.glassCard)
                        panelShadowEnabled: false

                        Behavior on color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }

                    contentItem: Text {
                        text: startBreakButton.text
                        textFormat: Text.PlainText
                        color: Theme.accentInk
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: pomodoroStopButton
                    visible: root.state === "pomoWork" || root.state === "pomoBreak" || root.state === "workDone" || root.state === "breakDone"
                    text: root.state === "pomoBreak" ? "跳过休息" : "结束"
                    implicitWidth: 104
                    implicitHeight: 40
                    onClicked: root.endPomodoro()

                    background: Rectangle {
                        color: Theme.inkSoft
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: pomodoroStopButton.text
                        color: Theme.surface
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Text {
                objectName: "noTaskHint"
                Layout.fillWidth: true
                // 两种模式都从任务页带入待启动任务；没有任务时必须说明开始按钮为何不可用。
                text: ((root.state === "free" && !root.timerBool("hasActiveSession")
                        && !root.canStartFreeFocus())
                       || (root.state === "pomoIdle" && !root.canStartPomodoro()))
                      ? qsTr("到今日任务里点「开始专注」即可带任务进入") : ""
                visible: text.length > 0
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXs
                color: Theme.inkMuted
                horizontalAlignment: Text.AlignHCenter
            }
        }

        Button {
            id: immersiveButton
            objectName: "immersiveButton"

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: Theme.space16
            anchors.rightMargin: Theme.space16
            implicitWidth: 40
            implicitHeight: 32
            visible: root.immersiveAvailable

            onClicked: root.immersiveRequested()

            background: Rectangle {
                color: immersiveButton.hovered ? Theme.surface : "transparent"
                border.color: immersiveButton.hovered ? Theme.border : "transparent"
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: "⛶"
                font.pixelSize: Theme.fontLg
                color: Theme.ink
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    function pomodoroStageText() {
        // 暂停态直接把 ⏸ 拼进文案里：环本身也会降透明度转灰，
        // 两条线索一起给，不用点开按钮读文字也能看出“停了”。
        if (root.state === "pomoWork") {
            return root.timerBool("isRunning") ? "专注中" : "⏸ 专注已暂停"
        }
        if (root.state === "pomoBreak") {
            return root.timerBool("isRunning") ? "休息中" : "⏸ 休息已暂停"
        }
        if (root.state === "workDone") {
            return "专注完成"
        }
        if (root.state === "breakDone") {
            return "休息结束"
        }
        return "番茄待机"
    }

    function primaryTimeText() {
        if (root.state === "free") {
            return root.formatTime(root.timerNumber("elapsedSeconds", 0))
        }
        if (root.state === "pomoIdle") {
            return root.selectedWorkMinutes + ":00"
        }
        if (root.state === "workDone" || root.state === "breakDone") {
            return "00:00"
        }
        return root.formatMinuteTime(root.timerNumber("remainingSeconds", 0))
    }

    function runningText() {
        // 番茄模式的运行/暂停提示已经并入 pomodoroStageText()，
        // 这里只服务自由模式（自由模式没有环，仍需要这行文字）。
        if (root.state === "free") {
            if (!root.timerBool("hasActiveSession")) {
                return root.selectedTaskId > 0 ? "准备开始" : "尚未选择任务"
            }
            return root.timerBool("isRunning") ? "专注进行中" : "专注已暂停"
        }
        return ""
    }

    function ringDimmed() {
        // 暂停只会发生在番茄的专注/休息进行阶段；完成态和待机态谈不上“暂停”。
        return (root.state === "pomoWork" || root.state === "pomoBreak") && !root.timerBool("isRunning")
    }

    function ringProgressFraction() {
        if (root.state === "pomoWork" || root.state === "pomoBreak") {
            var target = root.timerNumber("targetSeconds", 0)
            if (target <= 0) {
                return 0
            }
            return Math.max(0, Math.min(1, root.timerNumber("remainingSeconds", 0) / target))
        }
        // 完成态刻意合拢成满环，是效仿 Apple Watch 三环合拢的庆祝式收尾，
        // 不是字面“消退到 0”——这是唯一打破消退语义的例外。
        return 1
    }

    function ringColorForState() {
        if (root.state === "workDone" || root.state === "breakDone") {
            return Theme.success
        }
        if (root.state === "pomoBreak") {
            return Theme.focusBreakAccent
        }
        return Theme.accent
    }

    function primaryTimeColor() {
        if (root.state === "workDone" || root.state === "breakDone") {
            return Theme.success
        }
        if (root.ringDimmed()) {
            return Theme.inkMuted
        }
        if (root.state === "pomoBreak") {
            return Theme.focusBreakAccent
        }
        // 环内计时读数（番茄工作/自由专注运行态）：用可读文字色，别用低对比的 accent。
        return Theme.accentInk
    }

    function ringTimeMarkup(plain) {
        // 环内冒号只做颜色弱化，不请求额外字重；并且只接受标准数字冒号格式。
        // 未来若时间文本变成说明文案或含标签，直接回落纯文本，避免 StyledText 误解析。
        var text = String(plain)
        if (!/^[0-9:]+$/.test(text)) {
            return text
        }
        var parts = text.split(":")
        if (parts.length !== 2) {
            return text
        }
        return parts[0] + '<font color="' + Theme.focusColonMuted + '">:</font>' + parts[1]
    }

    function ringCaptionText() {
        var targetMinutes = Math.round(root.timerNumber("targetSeconds", 0) / 60)
        if (root.state === "pomoIdle") {
            return root.canStartPomodoro() ? "准备开始" : "等待任务"
        }
        if (root.state === "pomoWork") {
            return (root.ringDimmed() ? "已暂停 · 共 " : "剩余 · 共 ") + targetMinutes + " 分"
        }
        if (root.state === "pomoBreak") {
            return (root.ringDimmed() ? "已暂停 · 共 " : "休息 · 共 ") + targetMinutes + " 分"
        }
        if (root.state === "workDone") {
            return "这一颗番茄已完成"
        }
        if (root.state === "breakDone") {
            return "休息结束，可以继续专注了"
        }
        return ""
    }
}
