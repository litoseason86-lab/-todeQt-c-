import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Item {
    id: root

    property var timer: null
    property var settings: null
    property string errorText: ""
    property bool pomodoroModeSelected: false
    property int selectedWorkMinutes: 25
    property int selectedBreakMinutes: 5
    property int pomoTaskId: -1
    property string pomoTaskTitle: ""
    property int justCompletedPhase: 0
    property bool workCustomSelected: false
    property bool breakCustomSelected: false

    signal focusEnded()

    state: root.computeState()

    Component.onCompleted: {
        if (root.settings) {
            root.selectWorkMinutes(Number(root.settings.workMinutes))
            root.selectBreakMinutes(Number(root.settings.breakMinutes))
        }
        // 恢复值不在预设里时，落到“自定义”chip；这样重启后不会把 90 分误显示成无选中状态。
        root.workCustomSelected = root.selectedWorkMinutes !== 25
                && root.selectedWorkMinutes !== 45
                && root.selectedWorkMinutes !== 60
        root.breakCustomSelected = root.selectedBreakMinutes !== 5
                && root.selectedBreakMinutes !== 10
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
        if (root.pomodoroModeSelected) {
            if (root.pomoTaskTitle && root.pomoTaskTitle.length > 0) {
                return root.pomoTaskTitle
            }
            if (root.timerTitle().length > 0) {
                return root.timerTitle()
            }
            return "尚未选择任务"
        }

        return root.timerTitle().length > 0
                ? root.timerTitle()
                : "尚未开始专注"
    }

    function pomodoroTitle() {
        if (root.pomoTaskTitle && root.pomoTaskTitle.length > 0) {
            return root.pomoTaskTitle
        }
        if (root.timerTitle().length > 0) {
            return root.timerTitle()
        }
        return "番茄专注"
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
            // 进入番茄前先把当前任务信息缓存到本地；自由会话一旦 stopFocus，C++ 会清空任务字段。
            if (root.timer.currentTaskId > 0) {
                root.pomoTaskId = root.timer.currentTaskId
            }
            if (root.timer.currentTaskTitle && root.timer.currentTaskTitle.length > 0) {
                root.pomoTaskTitle = root.timer.currentTaskTitle
            }
            if (root.timer.hasActiveSession || root.timer.phase !== 0) {
                if (!root.timer.stopFocus()) {
                    root.errorText = "切换番茄失败，请重试"
                    return
                }
            }
        } else if (root.timer.hasActiveSession || root.timer.phase !== 0) {
            if (!root.timer.stopFocus()) {
                root.errorText = "结束当前阶段失败，请重试"
                return
            }
        }

        root.pomodoroModeSelected = enabled
        root.errorText = ""
        root.justCompletedPhase = 0

        if (!enabled) {
            root.pomoTaskId = -1
            root.pomoTaskTitle = ""
        }
    }

    function enterPomodoroWithTask(taskId, title) {
        // 任务列表一键直达番茄待机：复用 toPomodoroTab 的停止/清理逻辑，
        // 再用显式传入的任务覆盖它从 timer 缓存的值，因为直达时 timer 里可能还没有任务。
        root.toPomodoroTab(true)
        var safeTitle = String(title || "")
        if (taskId > 0) {
            root.pomoTaskId = taskId
        }
        if (safeTitle.length > 0) {
            root.pomoTaskTitle = safeTitle
        }
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
        return root.pomoTaskId > 0 || root.timerNumber("currentTaskId", -1) > 0
    }

    function startPomodoro() {
        root.justCompletedPhase = 0
        var taskId = root.pomoTaskId > 0 ? root.pomoTaskId : (root.timer ? root.timer.currentTaskId : -1)
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

    function startBreak() {
        root.justCompletedPhase = 0
        if (root.timer && root.timer.startBreak(root.selectedBreakMinutes * 60)) {
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
        root.focusEnded()
    }

    Connections {
        target: root.timer
        ignoreUnknownSignals: true

        function onPhaseCompleted(phase) {
            root.justCompletedPhase = phase
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

    component PresetButton: Button {
        id: presetButton

        property string backgroundObjectName: ""

        checkable: true
        implicitWidth: 104
        implicitHeight: 42

        background: Rectangle {
            objectName: presetButton.backgroundObjectName
            color: presetButton.checked ? Theme.accent : (presetButton.hovered ? Theme.surface : Theme.surfaceRaised)
            border.color: presetButton.checked ? Theme.accentStrong : Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }

        contentItem: Text {
            text: presetButton.text
            textFormat: Text.PlainText
            color: presetButton.checked ? Theme.surface : Theme.ink
            font.pixelSize: Theme.fontMd
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // 环形进度盘：番茄模式下的可视化核心。只负责画“轨道 + 剩余弧”，
    // 进度/颜色/暂停/预览态全部由外部属性驱动，自身不读取 root 状态——
    // 保持可复用、可测试（测试直接断言这几个绑定属性，不做像素级检查）。
    component FocusRing: Canvas {
        id: ring

        property real progress: 1.0       // 剩余时间占比：1=刚开始/已合拢，0=时间耗尽
        property color ringColor: Theme.accent
        property bool showPreview: false  // 待机态：只画一圈虚线预览，不画进度弧
        property bool dimmed: false       // 暂停态：整体降低不透明度，转由灰色轨道提示
        readonly property real strokeWidth: 16

        opacity: dimmed ? 0.38 : 1
        antialiasing: true

        Behavior on opacity {
            NumberAnimation { duration: 150 }
        }

        onProgressChanged: requestPaint()
        onRingColorChanged: requestPaint()
        onShowPreviewChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            var centerX = width / 2
            var centerY = height / 2
            var radius = Math.max(0, Math.min(width, height) / 2 - ring.strokeWidth / 2 - 2)
            ctx.lineCap = "round"

            if (ring.showPreview) {
                ctx.beginPath()
                ctx.setLineDash([2, 9])
                ctx.lineWidth = ring.strokeWidth * 0.75
                ctx.strokeStyle = Theme.border
                ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
                ctx.stroke()
                return
            }

            // 底色轨道：完整一圈，衬出前景弧的长度对比。
            ctx.beginPath()
            ctx.setLineDash([])
            ctx.lineWidth = ring.strokeWidth
            ctx.strokeStyle = Theme.borderSubtle
            ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
            ctx.stroke()

            // 进度弧从正上方（-90°）顺时针画出“剩余”部分——消退式核心视觉，
            // progress 越小画出的弧越短，直到耗尽时完全消失。
            var clamped = Math.max(0, Math.min(1, ring.progress))
            if (clamped <= 0) {
                return
            }
            var start = -Math.PI / 2
            var end = start + clamped * Math.PI * 2
            ctx.beginPath()
            ctx.lineWidth = ring.strokeWidth
            ctx.strokeStyle = ring.ringColor
            ctx.arc(centerX, centerY, radius, start, end, false)
            ctx.stroke()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.surfaceSunken

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
                    text: root.state === "free" ? "当前任务" : root.pomodoroStageText()
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Rectangle {
                id: completionBanner
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                visible: root.state === "workDone" || root.state === "breakDone"
                opacity: visible ? 1 : 0
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

                OpacityAnimator on opacity {
                    from: 0.35
                    to: 1
                    duration: 520
                    loops: Animation.Infinite
                    running: completionBanner.visible
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.state === "free"
                text: root.primaryTimeText()
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontDisplay
                font.bold: true
                color: Theme.accent
                horizontalAlignment: Text.AlignHCenter
            }

            FocusRing {
                id: focusRing
                objectName: "focusRing"
                Layout.alignment: Qt.AlignHCenter
                visible: root.pomodoroModeSelected
                implicitWidth: 252
                implicitHeight: 252
                showPreview: root.state === "pomoIdle"
                dimmed: root.ringDimmed()
                progress: root.ringProgressFraction()
                ringColor: root.ringColorForState()

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Theme.space4

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.primaryTimeText()
                        textFormat: Text.PlainText
                        font.pixelSize: root.state === "pomoIdle" ? 56 : Theme.fontDisplay
                        font.bold: true
                        color: root.primaryTimeColor()
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
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

            GridLayout {
                Layout.alignment: Qt.AlignHCenter
                visible: root.state === "pomoIdle"
                columns: 5
                columnSpacing: Theme.space8
                rowSpacing: Theme.space12

                ButtonGroup {
                    id: workPresetGroup
                    exclusive: true
                }

                Text {
                    text: "专注"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter

                    Layout.preferredWidth: 44
                }

                PresetButton {
                    id: workPreset25
                    objectName: "workPreset25"
                    text: "25 分"
                    backgroundObjectName: "workPreset25Background"
                    checked: !root.workCustomSelected && root.selectedWorkMinutes === 25

                    ButtonGroup.group: workPresetGroup

                    onClicked: {
                        root.workCustomSelected = false
                        root.selectWorkMinutes(25)
                    }
                }

                PresetButton {
                    id: workPreset45
                    objectName: "workPreset45"
                    text: "45 分"
                    backgroundObjectName: "workPreset45Background"
                    checked: !root.workCustomSelected && root.selectedWorkMinutes === 45

                    ButtonGroup.group: workPresetGroup

                    onClicked: {
                        root.workCustomSelected = false
                        root.selectWorkMinutes(45)
                    }
                }

                PresetButton {
                    id: workPreset60
                    objectName: "workPreset60"
                    text: "60 分"
                    backgroundObjectName: "workPreset60Background"
                    checked: !root.workCustomSelected && root.selectedWorkMinutes === 60

                    ButtonGroup.group: workPresetGroup

                    onClicked: {
                        root.workCustomSelected = false
                        root.selectWorkMinutes(60)
                    }
                }

                PresetButton {
                    id: workPresetCustom
                    objectName: "workPresetCustom"
                    text: root.workCustomSelected ? root.selectedWorkMinutes + " 分" : "自定义"
                    backgroundObjectName: "workPresetCustomBackground"
                    checked: root.workCustomSelected

                    ButtonGroup.group: workPresetGroup

                    onClicked: root.workCustomSelected = true
                }

                ButtonGroup {
                    id: breakPresetGroup
                    exclusive: true
                }

                Text {
                    text: "休息"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter

                    Layout.preferredWidth: 44
                }

                PresetButton {
                    id: breakPreset5
                    objectName: "breakPreset5"
                    text: "5 分"
                    backgroundObjectName: "breakPreset5Background"
                    checked: !root.breakCustomSelected && root.selectedBreakMinutes === 5

                    ButtonGroup.group: breakPresetGroup

                    onClicked: {
                        root.breakCustomSelected = false
                        root.selectBreakMinutes(5)
                    }
                }

                PresetButton {
                    id: breakPreset10
                    objectName: "breakPreset10"
                    text: "10 分"
                    backgroundObjectName: "breakPreset10Background"
                    checked: !root.breakCustomSelected && root.selectedBreakMinutes === 10

                    ButtonGroup.group: breakPresetGroup

                    onClicked: {
                        root.breakCustomSelected = false
                        root.selectBreakMinutes(10)
                    }
                }

                PresetButton {
                    id: breakPresetCustom
                    objectName: "breakPresetCustom"
                    text: root.breakCustomSelected ? root.selectedBreakMinutes + " 分" : "自定义"
                    backgroundObjectName: "breakPresetCustomBackground"
                    checked: root.breakCustomSelected

                    ButtonGroup.group: breakPresetGroup

                    onClicked: root.breakCustomSelected = true
                }

                Item {
                    Layout.preferredWidth: 104
                    Layout.preferredHeight: 42
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                visible: root.state === "pomoIdle" && (root.workCustomSelected || root.breakCustomSelected)
                spacing: Theme.space16

                RowLayout {
                    visible: root.workCustomSelected
                    spacing: Theme.space4

                    Text {
                        text: "专注(分)"
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }

                    SpinBox {
                        id: workCustomSpinBox
                        objectName: "workCustomSpinBox"
                        from: 5
                        to: 180
                        editable: true
                        value: root.selectedWorkMinutes
                        onValueModified: root.selectWorkMinutes(value)
                    }
                }

                RowLayout {
                    visible: root.breakCustomSelected
                    spacing: Theme.space4

                    Text {
                        text: "休息(分)"
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }

                    SpinBox {
                        id: breakCustomSpinBox
                        objectName: "breakCustomSpinBox"
                        from: 1
                        to: 60
                        editable: true
                        value: root.selectedBreakMinutes
                        onValueModified: root.selectBreakMinutes(value)
                    }
                }
            }

            Text {
                objectName: "ruleHintText"
                Layout.fillWidth: true
                visible: root.state === "pomoIdle"
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
                    id: pauseButton
                    visible: root.state === "free" || root.state === "pomoWork" || root.state === "pomoBreak"
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
                    visible: root.state === "free"
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

                    onClicked: {
                        if (root.timer && root.timer.stopFocus()) {
                            root.errorText = ""
                            root.focusEnded()
                        } else {
                            root.errorText = "专注保存失败，请重试"
                        }
                    }
                }

                Button {
                    id: pomodoroStartButton
                    objectName: "pomodoroStartButton"
                    visible: root.state === "pomoIdle" || root.state === "breakDone"
                    text: root.state === "breakDone" ? "开始专注" : "开始专注"
                    enabled: root.canStartPomodoro()
                    implicitWidth: 112
                    implicitHeight: 40
                    onClicked: root.startPomodoro()

                    background: Rectangle {
                        color: pomodoroStartButton.enabled ? Theme.accent : Theme.border
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: pomodoroStartButton.text
                        color: pomodoroStartButton.enabled ? Theme.surface : Theme.inkMuted
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: startBreakButton
                    visible: root.state === "workDone"
                    text: "开始休息"
                    implicitWidth: 112
                    implicitHeight: 40
                    onClicked: root.startBreak()

                    background: Rectangle {
                        color: Theme.accent
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: startBreakButton.text
                        color: Theme.surface
                        font.pixelSize: Theme.fontLg
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
        return Theme.accent
    }

    function ringCaptionText() {
        var targetMinutes = Math.round(root.timerNumber("targetSeconds", 0) / 60)
        if (root.state === "pomoIdle") {
            return "专注 " + root.selectedWorkMinutes + " 分 · 休息 " + root.selectedBreakMinutes + " 分"
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
