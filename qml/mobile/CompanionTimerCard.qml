pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 伴侣页的计时卡。五种状态各有一组主操作，按钮放在同一行、高度 44pt，单手拇指够得着：
//   待机      调整番茄时长（开始入口在每条任务上）
//   专注/休息 暂停或继续、结束
//   专注刚完成 开始休息、先不休息
//   休息刚结束 下一个番茄、好的
Rectangle {
    id: root

    // 伴侣页本身：计时状态、刚完成的阶段和各项操作都由它提供，本卡片只负责呈现。
    required property var companion

    readonly property var timer: root.companion.focusTimerRef
    readonly property int phase: root.companion.timerPhase
    readonly property bool running: root.companion.timerRunning
    readonly property string cardState: {
        if (!root.timer)
            return "unavailable"
        if (root.companion.timerActive)
            return root.phase === 2 ? "break" : "work"
        if (root.companion.justCompletedPhase === 1)
            return "workDone"
        if (root.companion.justCompletedPhase === 2)
            return "breakDone"
        return "idle"
    }
    readonly property bool counting: root.cardState === "work" || root.cardState === "break"
    readonly property int remainingSeconds: root.timer ? Number(root.timer.remainingSeconds) : 0

    function titleText() {
        switch (root.cardState) {
        case "work":
            return root.running ? qsTr("专注中") : qsTr("专注已暂停")
        case "break":
            return root.running ? qsTr("休息中") : qsTr("休息已暂停")
        case "workDone":
            return qsTr("这个番茄完成了")
        case "breakDone":
            return qsTr("休息结束")
        case "unavailable":
            return qsTr("计时不可用")
        default:
            return qsTr("番茄时长")
        }
    }

    function detailText() {
        switch (root.cardState) {
        case "work":
            return String(root.timer.currentTaskTitle || "")
        case "break":
            return qsTr("休息 %1 分钟").arg(Math.round(Number(root.timer.targetSeconds) / 60))
        case "workDone":
            return qsTr("接下来休息 %1 分钟").arg(root.companion.nextBreakMinutes())
        case "breakDone":
            return root.companion.lastTaskId > 0
                    ? qsTr("继续「%1」").arg(root.companion.lastTaskTitle)
                    : qsTr("在任务上点「开始」进入下一个番茄")
        case "unavailable":
            return ""
        default:
            return qsTr("在下面的任务上点「开始」")
        }
    }

    implicitHeight: content.implicitHeight + Theme.space16 * 2
    radius: Theme.radiusLg
    color: Theme.surfaceRaised
    // 计时中用强调色描边标出「这张卡正在走」，颜色之外标题文字也说明了状态。
    border.width: root.counting ? 2 : 1
    border.color: root.counting ? Theme.accent : Theme.borderSubtle

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Theme.space16
        spacing: Theme.space8

        Text {
            objectName: "companionTimerTitle"
            Layout.fillWidth: true
            text: root.titleText()
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontLg
            font.weight: Font.DemiBold
        }

        // 倒计时读数：计时数字统一用 Space Grotesk，与完整界面一致。
        Text {
            objectName: "companionTimerClock"
            Layout.alignment: Qt.AlignHCenter
            visible: root.counting
            text: root.companion.formatClock(root.remainingSeconds)
            textFormat: Text.PlainText
            color: root.running ? Theme.inkStrong : Theme.inkMuted
            font.family: Theme.fontFamilyClock
            font.pixelSize: 56
            Accessible.name: qsTr("剩余 %1 分 %2 秒").arg(Math.floor(root.remainingSeconds / 60))
                                                     .arg(root.remainingSeconds % 60)
        }

        Text {
            objectName: "companionTimerDetail"
            Layout.fillWidth: true
            visible: text.length > 0
            text: root.detailText()
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            horizontalAlignment: root.counting ? Text.AlignHCenter : Text.AlignLeft
        }

        // 待机：调整番茄时长，写回设置，完整界面与下一次启动都沿用。
        RowLayout {
            Layout.fillWidth: true
            visible: root.cardState === "idle"
            spacing: Theme.space8

            CompanionButton {
                objectName: "companionMinutesMinus"
                text: qsTr("少 5 分钟")
                implicitHeight: Theme.controlHeightLg
                enabled: root.companion.workMinutes > 5
                onClicked: root.companion.adjustWorkMinutes(-5)
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("%1 分钟").arg(root.companion.workMinutes)
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                color: Theme.inkStrong
                font.family: Theme.fontFamilyData
                font.pixelSize: Theme.fontXl
            }

            CompanionButton {
                objectName: "companionMinutesPlus"
                text: qsTr("多 5 分钟")
                implicitHeight: Theme.controlHeightLg
                enabled: root.companion.workMinutes < 180
                onClicked: root.companion.adjustWorkMinutes(5)
            }
        }

        // 计时中：暂停或继续是主操作，结束放在右侧。
        RowLayout {
            Layout.fillWidth: true
            visible: root.counting
            spacing: Theme.space8

            CompanionButton {
                objectName: "companionPauseResumeButton"
                Layout.fillWidth: true
                primary: true
                implicitHeight: Theme.controlHeightLg
                text: root.running ? qsTr("暂停") : qsTr("继续")
                glyph: root.running ? "pause" : "play"
                onClicked: {
                    if (root.running)
                        root.timer.pauseFocus()
                    else
                        root.timer.resumeFocus()
                }
            }

            CompanionButton {
                objectName: "companionStopButton"
                Layout.fillWidth: true
                implicitHeight: Theme.controlHeightLg
                text: root.cardState === "break" ? qsTr("结束休息") : qsTr("结束专注")
                onClicked: root.timer.stopFocus()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.cardState === "workDone"
            spacing: Theme.space8

            CompanionButton {
                objectName: "companionStartBreakButton"
                Layout.fillWidth: true
                primary: true
                implicitHeight: Theme.controlHeightLg
                text: qsTr("开始休息")
                glyph: "moon"
                onClicked: root.companion.startBreak()
            }

            CompanionButton {
                Layout.fillWidth: true
                implicitHeight: Theme.controlHeightLg
                text: qsTr("先不休息")
                onClicked: root.companion.justCompletedPhase = 0
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.cardState === "breakDone"
            spacing: Theme.space8

            CompanionButton {
                objectName: "companionNextPomodoroButton"
                Layout.fillWidth: true
                primary: true
                implicitHeight: Theme.controlHeightLg
                visible: root.companion.lastTaskId > 0
                text: qsTr("下一个番茄")
                glyph: "play"
                onClicked: root.companion.startPomodoro(root.companion.lastTaskId,
                                                        root.companion.lastTaskTitle)
            }

            CompanionButton {
                Layout.fillWidth: true
                implicitHeight: Theme.controlHeightLg
                text: qsTr("好的")
                onClicked: root.companion.justCompletedPhase = 0
            }
        }
    }
}
