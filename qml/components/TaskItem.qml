import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root

    Layout.fillWidth: true
    implicitHeight: Math.max(68, content.implicitHeight + 24)
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1

    property int taskId: 0
    property string taskTitle: ""
    property string taskCategory: ""
    property bool taskCompleted: false

    signal completionChanged(int taskId, bool completed)
    signal startFocusClicked(int taskId, string title)

    RowLayout {
        id: content

        anchors.fill: parent
        anchors.margins: 12
        spacing: 12

        CheckBox {
            id: checkbox

            checked: root.taskCompleted
            onToggled: root.completionChanged(root.taskId, checked)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: root.taskTitle
                font.pixelSize: 15
                color: root.taskCompleted ? "#a0896b" : "#5d4e37"
                font.strikeout: root.taskCompleted
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                text: root.taskCategory
                font.pixelSize: 12
                color: "#8b7355"
                visible: root.taskCategory.length > 0
                elide: Text.ElideRight
            }
        }

        Button {
            id: focusButton

            text: root.taskCompleted ? "已完成" : "开始专注"
            enabled: !root.taskCompleted
            implicitWidth: 94
            implicitHeight: 34

            ToolTip.visible: hovered && !enabled
            ToolTip.text: "已完成任务不能开始专注"

            background: Rectangle {
                radius: 4
                color: focusButton.enabled ? "#d4a574" : "#e8dfc8"
            }

            contentItem: Text {
                text: focusButton.text
                color: focusButton.enabled ? "#fffef9" : "#a0896b"
                font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            onClicked: root.startFocusClicked(root.taskId, root.taskTitle)
        }
    }
}
