pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 伴侣页的一条任务：左侧完成勾选（44pt 命中区），中间标题，右侧「开始」番茄。
// 计时进行中不给「开始」：同一时间只能有一段计时，点了也只会失败。
Item {
    id: root

    required property var task
    // 伴侣页本身：提供计时状态与完成、开始等操作。
    required property var companion

    readonly property int taskId: Number(root.task.id)
    readonly property string title: String(root.task.title || "")
    readonly property bool completed: Boolean(root.task.completed)
    readonly property bool focusing: root.companion.timerActive
                                     && root.companion.timerPhase === 1
                                     && root.companion.currentTaskId === root.taskId

    implicitHeight: Math.max(56, row.implicitHeight + Theme.space12)

    RowLayout {
        id: row

        anchors.fill: parent
        anchors.leftMargin: Theme.space4
        anchors.rightMargin: Theme.space12
        spacing: Theme.space8

        AbstractButton {
            id: checkButton
            objectName: "companionTaskCheck"

            Layout.preferredWidth: Theme.controlHeightLg
            Layout.preferredHeight: Theme.controlHeightLg
            focusPolicy: Qt.StrongFocus
            Accessible.role: Accessible.CheckBox
            Accessible.name: root.completed ? qsTr("取消完成：%1").arg(root.title)
                                            : qsTr("完成：%1").arg(root.title)

            onClicked: root.companion.setCompleted(root.task, !root.completed)

            contentItem: Item {
                Rectangle {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    radius: 12
                    // 完成态靠「填充 + 对勾 + 标题删除线」三重线索，不只靠颜色。
                    color: root.completed ? Theme.accentFill : Theme.surfaceRaised
                    border.width: checkButton.visualFocus ? 3 : 2
                    border.color: checkButton.visualFocus ? Theme.focusRing
                                                          : (root.completed ? Theme.accentFill : Theme.inkMuted)

                    Text {
                        anchors.centerIn: parent
                        visible: root.completed
                        text: "✓"
                        color: Theme.accentFillInk
                        font.pixelSize: Theme.fontLg
                        font.weight: Font.Bold
                    }
                }
            }

            background: Item {}
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                objectName: "companionTaskTitle"
                Layout.fillWidth: true
                text: root.title
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: root.completed ? Theme.inkMuted : Theme.ink
                font.pixelSize: Theme.fontLg
                font.strikeout: root.completed
            }

            Text {
                visible: root.focusing
                text: qsTr("专注中")
                color: Theme.accentInk
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
            }
        }

        CompanionButton {
            objectName: "companionTaskStart"
            visible: !root.completed && !root.companion.timerActive
            implicitHeight: Theme.controlHeightLg
            text: qsTr("开始")
            glyph: "play"
            Accessible.name: qsTr("开始番茄：%1").arg(root.title)
            onClicked: root.companion.startPomodoro(root.taskId, root.title)
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.controlHeightLg + Theme.space8
        height: 1
        color: Theme.borderSubtle
    }
}
