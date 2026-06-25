import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Item {
    id: root

    signal focusEnded()

    property var timer: typeof focusTimer !== "undefined" ? focusTimer : null
    property string errorText: ""
    property bool pomodoroModeSelected: false
    property int selectedWorkMinutes: 25
    property int selectedBreakMinutes: 5
    property int pomoTaskId: -1
    property string pomoTaskTitle: ""
    property int justCompletedPhase: 0

    state: root.computeState()

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

    function selectWorkMinutes(minutes) {
        if (minutes === 25 || minutes === 45 || minutes === 60) {
            root.selectedWorkMinutes = minutes
        }
    }

    function selectBreakMinutes(minutes) {
        if (minutes === 5 || minutes === 10) {
            root.selectedBreakMinutes = minutes
        }
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

    Rectangle {
        anchors.fill: parent
        color: Theme.surfaceSunken

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 64, 500)
            spacing: Theme.space24

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
                text: root.primaryTimeText()
                font.pixelSize: Theme.fontDisplay
                font.bold: true
                color: root.state === "workDone" || root.state === "breakDone" ? Theme.success : Theme.accent
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                Layout.fillWidth: true
                visible: root.state === "free" || root.state === "pomoWork" || root.state === "pomoBreak"
                text: root.runningText()
                font.pixelSize: Theme.fontLg
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
            }

            ColumnLayout {
                Layout.fillWidth: true
                visible: root.state === "pomoIdle"
                spacing: Theme.space16

                ButtonGroup {
                    id: workPresetGroup
                    exclusive: true
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.space8

                    Text {
                        text: "专注"
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }

                    Button {
                        id: workPreset25
                        objectName: "workPreset25"
                        text: "25 分"
                        checkable: true
                        checked: root.selectedWorkMinutes === 25
                        ButtonGroup.group: workPresetGroup
                        onClicked: root.selectWorkMinutes(25)
                    }

                    Button {
                        id: workPreset45
                        objectName: "workPreset45"
                        text: "45 分"
                        checkable: true
                        checked: root.selectedWorkMinutes === 45
                        ButtonGroup.group: workPresetGroup
                        onClicked: root.selectWorkMinutes(45)
                    }

                    Button {
                        id: workPreset60
                        objectName: "workPreset60"
                        text: "60 分"
                        checkable: true
                        checked: root.selectedWorkMinutes === 60
                        ButtonGroup.group: workPresetGroup
                        onClicked: root.selectWorkMinutes(60)
                    }
                }

                ButtonGroup {
                    id: breakPresetGroup
                    exclusive: true
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.space8

                    Text {
                        text: "休息"
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }

                    Button {
                        id: breakPreset5
                        objectName: "breakPreset5"
                        text: "5 分"
                        checkable: true
                        checked: root.selectedBreakMinutes === 5
                        ButtonGroup.group: breakPresetGroup
                        onClicked: root.selectBreakMinutes(5)
                    }

                    Button {
                        id: breakPreset10
                        objectName: "breakPreset10"
                        text: "10 分"
                        checkable: true
                        checked: root.selectedBreakMinutes === 10
                        ButtonGroup.group: breakPresetGroup
                        onClicked: root.selectBreakMinutes(10)
                    }
                }
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
                    implicitWidth: 112
                    implicitHeight: 40
                    onClicked: root.startPomodoro()

                    background: Rectangle {
                        color: Theme.accent
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: pomodoroStartButton.text
                        color: Theme.surface
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
        if (root.state === "pomoWork") {
            return "专注中"
        }
        if (root.state === "pomoBreak") {
            return "休息中"
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
        if (root.state === "free") {
            return root.timerBool("isRunning") ? "专注进行中" : "专注已暂停"
        }
        if (root.state === "pomoWork") {
            return root.timerBool("isRunning") ? "专注中" : "专注已暂停"
        }
        if (root.state === "pomoBreak") {
            return root.timerBool("isRunning") ? "休息中" : "休息已暂停"
        }
        return ""
    }
}
