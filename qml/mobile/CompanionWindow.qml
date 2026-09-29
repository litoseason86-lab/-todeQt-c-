pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

// 手机随身伴侣页：只做手机上最常用的三件事——看今天的任务、随手记一条、
// 开一个番茄。课表、周计划、统计这些重页面留在 Mac 与 iPad 的完整界面里。
// 业务全部走现有服务接口（taskManager / focusTimer / appSettings），本页不新增业务规则。
Item {
    id: root
    objectName: "companionWindow"

    property var taskManagerRef: null
    property var focusTimerRef: null
    property var appSettingsRef: null
    property var logicalDayServiceRef: null

    // 提示条由窗口统一显示（它还要避开底部横条）。
    signal toastRequested(string message)

    property var tasks: []
    property string loadError: ""
    // 页头日期按逻辑日显示（凌晨在「一天的起点」之前仍算前一天），跨天刷新时一起更新。
    property string todayText: ""
    // 刚完成的阶段：1 专注刚到点（等待开始休息），2 休息刚结束。开始新计时或手动关闭时清零。
    property int justCompletedPhase: 0
    // 上一段专注的任务：休息阶段没有任务 id，「开始下一个番茄」要靠它接着同一个任务。
    property int lastTaskId: -1
    property string lastTaskTitle: ""

    readonly property int timerPhase: root.focusTimerRef ? Number(root.focusTimerRef.phase) : 0
    readonly property bool timerRunning: !!root.focusTimerRef && Boolean(root.focusTimerRef.isRunning)
    readonly property bool timerActive: !!root.focusTimerRef
                                        && (Boolean(root.focusTimerRef.hasActiveSession) || root.timerPhase !== 0)
    readonly property int currentTaskId: root.focusTimerRef ? Number(root.focusTimerRef.currentTaskId) : -1
    readonly property int workMinutes: {
        var value = root.appSettingsRef ? Number(root.appSettingsRef.workMinutes) : 25
        return value >= 5 && value <= 180 ? value : 25
    }

    function todayIso() {
        var hour = root.appSettingsRef ? Number(root.appSettingsRef.dayStartHour) : 0
        return LogicalDay.todayIso(hour, new Date())
    }

    function refresh() {
        if (!root.taskManagerRef) {
            root.tasks = []
            return
        }
        root.loadError = ""
        var hour = root.appSettingsRef ? Number(root.appSettingsRef.dayStartHour) : 0
        var today = LogicalDay.todayDate(hour, new Date())
        var weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        root.todayText = Qt.formatDate(today, "M月d日") + " " + weekdays[today.getDay()]
        root.tasks = root.taskManagerRef.getTodayTasks()
    }

    function formatClock(totalSeconds) {
        var seconds = Math.max(0, Math.floor(Number(totalSeconds) || 0))
        var minutes = Math.floor(seconds / 60)
        var rest = seconds % 60
        return (minutes < 10 ? "0" : "") + minutes + ":" + (rest < 10 ? "0" : "") + rest
    }

    // 下一段休息的分钟数：与完整界面同一口径，每满「长休息间隔」个番茄休息得更久。
    function nextBreakMinutes() {
        var settings = root.appSettingsRef
        if (!settings)
            return 5
        var completed = root.focusTimerRef ? Number(root.focusTimerRef.completedPomodoros) : 0
        var interval = Number(settings.longBreakInterval)
        if (settings.longBreakEnabled && interval > 0 && completed > 0 && completed % interval === 0)
            return Number(settings.longBreakMinutes)
        return Number(settings.breakMinutes)
    }

    function addTask(title) {
        var trimmed = String(title || "").trim()
        if (trimmed.length === 0 || !root.taskManagerRef)
            return false
        if (!root.taskManagerRef.addTask(trimmed, root.todayIso())) {
            root.toastRequested(qsTr("没有记上，请重试"))
            return false
        }
        return true
    }

    function setCompleted(task, completed) {
        var taskId = Number(task.id)
        if (!root.taskManagerRef || !root.taskManagerRef.setTaskCompleted(taskId, completed)) {
            root.toastRequested(completed ? qsTr("没能标记完成，请重试") : qsTr("没能取消完成，请重试"))
            root.refresh()
            return
        }
        if (!completed)
            return
        // 完成的正是正在计时的任务：顺带结束这段专注，否则之后的时间也会记到它头上。
        if (root.focusTimerRef && root.focusTimerRef.hasActiveSession && root.currentTaskId === taskId) {
            if (root.focusTimerRef.stopFocus()) {
                root.toastRequested(qsTr("已完成，专注已结束"))
            } else {
                root.toastRequested(qsTr("已完成，但结束专注失败，计时仍在继续"))
            }
        }
    }

    function startPomodoro(taskId, title) {
        if (!root.focusTimerRef || root.timerActive)
            return
        autoAdvanceTimer.stop()
        root.justCompletedPhase = 0
        if (!root.focusTimerRef.startPomodoroWork(taskId, title, root.workMinutes * 60))
            root.toastRequested(qsTr("番茄没有开始，请重试"))
    }

    function startBreak() {
        if (!root.focusTimerRef || root.timerActive)
            return
        autoAdvanceTimer.stop()
        root.justCompletedPhase = 0
        if (!root.focusTimerRef.startBreakForTask(root.nextBreakMinutes() * 60,
                                                  root.lastTaskId, root.lastTaskTitle))
            root.toastRequested(qsTr("休息没有开始，请重试"))
    }

    function adjustWorkMinutes(delta) {
        if (!root.appSettingsRef)
            return
        root.appSettingsRef.workMinutes = Math.max(5, Math.min(180, root.workMinutes + delta))
    }

    Component.onCompleted: root.refresh()

    Connections {
        target: root.taskManagerRef
        ignoreUnknownSignals: true

        function onTasksChanged() {
            root.refresh()
        }

        function onOperationFailed(message) {
            root.loadError = String(message || "")
        }
    }

    Connections {
        target: root.logicalDayServiceRef
        ignoreUnknownSignals: true

        // 跨过一天的起点时，「今天」换了一天，列表必须重新取。
        function onChanged() {
            root.refresh()
        }
    }

    Connections {
        target: root.focusTimerRef
        ignoreUnknownSignals: true

        function onCurrentTaskChanged() {
            // 记下这一段专注的任务，休息结束后「开始下一个番茄」接着它。
            if (root.focusTimerRef.phase === 1 && root.focusTimerRef.currentTaskId > 0) {
                root.lastTaskId = root.focusTimerRef.currentTaskId
                root.lastTaskTitle = String(root.focusTimerRef.currentTaskTitle || "")
            }
        }

        // 人在场时到点：按设置自动衔接下一阶段。
        function onPhaseCompleted(phase) {
            root.justCompletedPhase = phase
            var settings = root.appSettingsRef
            var wantsAuto = settings && ((phase === 1 && settings.autoStartBreak)
                                         || (phase === 2 && settings.autoStartNextPomodoro && root.lastTaskId > 0))
            if (wantsAuto) {
                autoAdvanceTimer.pendingPhase = phase
                autoAdvanceTimer.restart()
            }
        }

        // 离开期间到点、回来才结算：只显示完成态，不自动开始下一阶段（人不在场，节奏由用户重新决定）。
        function onPhaseSettledOffline(phase) {
            autoAdvanceTimer.stop()
            root.justCompletedPhase = phase
        }
    }

    // 自动衔接留一小段缓冲，让用户看清完成态；减少动效时立即切换。
    Timer {
        id: autoAdvanceTimer

        property int pendingPhase: 0

        interval: Theme.reduceMotion ? 0 : 900
        onTriggered: {
            var phase = autoAdvanceTimer.pendingPhase
            autoAdvanceTimer.pendingPhase = 0
            // 延迟期间用户可能已经手动开始了别的计时；只在仍停在这个完成态时衔接。
            if (root.justCompletedPhase !== phase || root.timerActive)
                return
            if (phase === 1)
                root.startBreak()
            else if (phase === 2)
                root.startPomodoro(root.lastTaskId, root.lastTaskTitle)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.space16

        // 页头：今天的日期。手机上不放装饰，把空间留给计时与列表。
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                text: qsTr("今天")
                color: Theme.inkStrong
                font.pixelSize: Theme.fontXxl
                font.weight: Font.DemiBold
            }

            Text {
                objectName: "companionDateText"
                text: root.todayText
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }
        }

        CompanionTimerCard {
            objectName: "companionTimerCard"
            Layout.fillWidth: true
            companion: root
        }

        // 快速记录：回车或点「记下」都能提交，成功后清空输入框继续记下一条。
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            TextField {
                id: quickAddField
                objectName: "companionQuickAddField"

                Layout.fillWidth: true
                Layout.preferredHeight: Theme.controlHeightLg
                placeholderText: qsTr("记一条今天的任务")
                color: Theme.inputInk
                placeholderTextColor: Theme.inputPlaceholderInk
                selectionColor: Theme.inputSelection
                selectedTextColor: Theme.inputSelectedInk
                font.pixelSize: Theme.fontLg
                maximumLength: root.taskManagerRef ? Number(root.taskManagerRef.maxTitleLength) : 200
                Accessible.name: qsTr("新任务标题")
                background: Rectangle {
                    radius: Theme.radiusLg
                    color: Theme.surfaceRaised
                    border.width: quickAddField.activeFocus ? 2 : 1
                    border.color: quickAddField.activeFocus ? Theme.focusRing : Theme.border
                }

                onAccepted: {
                    if (root.addTask(quickAddField.text))
                        quickAddField.clear()
                }
            }

            CompanionButton {
                objectName: "companionQuickAddButton"
                primary: true
                text: qsTr("记下")
                implicitHeight: Theme.controlHeightLg
                enabled: quickAddField.text.trim().length > 0

                onClicked: {
                    if (root.addTask(quickAddField.text))
                        quickAddField.clear()
                }
            }
        }

        // 今日任务：未完成在前（服务端已按完成状态排序）。
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.radiusLg
            color: Theme.surfaceRaised
            border.width: 1
            border.color: Theme.borderSubtle
            clip: true

            ListView {
                id: taskList
                objectName: "companionTaskList"

                anchors.fill: parent
                anchors.margins: Theme.space4
                model: root.tasks
                spacing: 0
                boundsBehavior: Flickable.StopAtBounds

                delegate: CompanionTaskRow {
                    required property var modelData

                    width: ListView.view.width
                    task: modelData
                    companion: root
                }
            }

            // 加载失败与「今天确实没有任务」是两回事，分开说明。
            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - Theme.space32
                spacing: Theme.space12
                visible: root.tasks.length === 0

                Text {
                    Layout.fillWidth: true
                    text: root.loadError.length > 0
                          ? qsTr("任务没有加载出来：%1").arg(root.loadError)
                          : qsTr("今天还没有任务，在上面记一条吧")
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    color: root.loadError.length > 0 ? Theme.danger : Theme.inkSoft
                    font.pixelSize: Theme.fontLg
                }

                CompanionButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: root.loadError.length > 0
                    text: qsTr("重试")
                    implicitHeight: Theme.controlHeightLg
                    onClicked: root.refresh()
                }
            }
        }
    }
}
