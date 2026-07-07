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
    property bool panelExpanded: false

    signal focusEnded()

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

    function clearPomodoroTask() {
        root.pomoTaskId = -1
        root.pomoTaskTitle = ""
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
            var shouldUseTimerTask = timerHasSession || root.pomoTaskId <= 0
            // 只有正在切换真实计时会话，或本地没有“从任务页直达”的显式选择时，
            // 才从 timer 覆盖缓存；否则会把用户刚点的任务替换成 timer 里的旧值。
            if (shouldUseTimerTask && root.timer.currentTaskId > 0) {
                root.pomoTaskId = root.timer.currentTaskId
            }
            if (shouldUseTimerTask && root.timer.currentTaskTitle && root.timer.currentTaskTitle.length > 0) {
                root.pomoTaskTitle = root.timer.currentTaskTitle
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
            if (!hasRunningTimer && root.pomoTaskId > 0) {
                // 自由模式没有“待机开始”按钮：从任务页直达番茄待机后再切自由，
                // 必须立刻用缓存任务启动自由专注，否则用户会落到一个无法开始的空页面。
                if (!root.timer.startFocus(root.pomoTaskId, root.pomodoroTitle())) {
                    root.errorText = "自由专注启动失败，请重试"
                    return
                }
                root.clearPomodoroTask()
                if (root.settings) {
                    root.settings.lastMode = 0
                }
            }
        }

        root.pomodoroModeSelected = enabled
        root.errorText = ""
        root.justCompletedPhase = 0
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
            root.clearPomodoroTask()
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
        root.clearPomodoroTask()
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

    // 暖纸步进器替代 SpinBox 与“自定义”chip。value 只读外部状态，
    // 加减通过 adjusted 信号回给 select*Minutes，避免出现第二套时长来源。
    component DurationStepper: RowLayout {
        id: stepper

        property int value: 0
        property int from: 1
        property int to: 99
        property string namePrefix: ""

        signal adjusted(int newValue)

        spacing: 0

        Button {
            id: minusButton
            objectName: stepper.namePrefix + "Minus"
            enabled: stepper.value > stepper.from
            implicitWidth: 32
            implicitHeight: 36
            onClicked: stepper.adjusted(stepper.value - 1)

            background: Rectangle {
                color: minusButton.enabled ? Theme.surface : Theme.surfaceSunken
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: "−"
                textFormat: Text.PlainText
                color: minusButton.enabled ? Theme.inkSoft : Theme.inkMuted
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        Rectangle {
            implicitWidth: 52
            implicitHeight: 36
            color: Theme.surfaceSunken
            border.color: Theme.border
            border.width: 1

            Text {
                objectName: stepper.namePrefix + "Value"
                anchors.centerIn: parent
                text: stepper.value
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
            }
        }

        Button {
            id: plusButton
            objectName: stepper.namePrefix + "Plus"
            enabled: stepper.value < stepper.to
            implicitWidth: 32
            implicitHeight: 36
            onClicked: stepper.adjusted(stepper.value + 1)

            background: Rectangle {
                color: plusButton.enabled ? Theme.surface : Theme.surfaceSunken
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: "+"
                textFormat: Text.PlainText
                color: plusButton.enabled ? Theme.inkSoft : Theme.inkMuted
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
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
                // 预览＝极淡完整轨道：预告“进度环将画在这里”，
                // 比虚线更安静，也不会在高分屏上碎成颗粒。
                ctx.beginPath()
                ctx.setLineDash([])
                ctx.lineWidth = ring.strokeWidth
                ctx.strokeStyle = Theme.borderSubtle
                ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
                ctx.stroke()

                // 顶部约 15° 的强调弧：暗示正式计时会从正上方开始消退。
                ctx.beginPath()
                ctx.globalAlpha = 0.45
                ctx.strokeStyle = Theme.accent
                ctx.arc(centerX, centerY, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI / 12, false)
                ctx.stroke()
                ctx.globalAlpha = 1
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
                    text: root.state === "free" ? "当前任务" : root.pomodoroStageText()
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

                Layout.fillWidth: true
                Layout.preferredHeight: 44
                visible: completionBanner.shouldShow
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
                    id: completionBlink

                    from: 0.35
                    to: 1
                    duration: 520
                    loops: Animation.Infinite
                    running: completionBanner.shouldShow && !(root.settings && root.settings.reduceMotion)

                    onRunningChanged: {
                        // 减少动效会停掉循环闪烁；停在低透明帧会削弱完成反馈，所以恢复到静止可见值。
                        if (!running) {
                            completionBanner.opacity = completionBanner.shouldShow ? 1 : 0
                        }
                    }
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
                font.bold: true
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
                        text: root.primaryTimeText()
                        textFormat: Text.PlainText
                        font.pixelSize: root.state === "pomoIdle"
                                        ? (root.panelExpanded ? 42 : 56)
                                        : Theme.fontDisplay
                        font.family: Theme.fontFamilyClock
                        font.bold: true
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
                            root.clearPomodoroTask()
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

            Text {
                objectName: "noTaskHint"
                Layout.fillWidth: true
                // 置灰的开始按钮必须解释原因，否则直达番茄页的用户会卡在无反馈状态。
                text: root.state === "pomoIdle" && !root.canStartPomodoro()
                      ? "到今日任务里点「开始专注」即可带任务进入"
                      : ""
                visible: text.length > 0
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXs
                color: Theme.inkMuted
                horizontalAlignment: Text.AlignHCenter
            }
        }

        Button {
            id: soundToggleButton
            objectName: "soundToggleButton"

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Theme.space16
            implicitWidth: 40
            implicitHeight: 32

            onClicked: {
                if (root.settings) {
                    root.settings.soundEnabled = !root.settings.soundEnabled
                }
            }

            background: Rectangle {
                color: soundToggleButton.hovered ? Theme.surface : "transparent"
                border.color: soundToggleButton.hovered ? Theme.border : "transparent"
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: root.settings && root.settings.soundEnabled ? "🔔" : "🔕"
                font.pixelSize: Theme.fontLg
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
