import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root

    Layout.fillWidth: true
    implicitHeight: Math.max(72, content.implicitHeight + 24)
    radius: 6
    color: hoverArea.containsMouse ? "#fffef9" : "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1

    property int taskId: 0
    property string taskTitle: ""
    property var taskCategory: ""
    property bool taskCompleted: false
    property real completionOffset: 0
    readonly property string categoryName: typeof taskCategory === "object"
                                           ? (taskCategory && taskCategory.name ? taskCategory.name : "")
                                           : String(taskCategory || "")
    readonly property string categoryColor: typeof taskCategory === "object"
                                            ? (taskCategory && taskCategory.color ? taskCategory.color : "")
                                            : ""

    signal completionChanged(int taskId, bool completed)
    signal startFocusClicked(int taskId, string title)

    states: [
        State {
            name: "normal"
            when: !root.taskCompleted
            PropertyChanges {
                root.opacity: 1.0
                root.completionOffset: 0
            }
        },
        State {
            name: "completed"
            when: root.taskCompleted
            PropertyChanges {
                root.opacity: 0.62
                root.completionOffset: 5
            }
        }
    ]

    transitions: [
        Transition {
            from: "normal"
            to: "completed"

            ParallelAnimation {
                OpacityAnimator {
                    target: root
                    duration: 200
                    easing.type: Easing.OutQuad
                }

                NumberAnimation {
                    target: root
                    property: "completionOffset"
                    duration: 200
                    easing.type: Easing.OutQuad
                }
            }
        },
        Transition {
            from: "completed"
            to: "normal"

            ParallelAnimation {
                OpacityAnimator {
                    target: root
                    duration: 150
                    easing.type: Easing.InQuad
                }

                NumberAnimation {
                    target: root
                    property: "completionOffset"
                    duration: 150
                    easing.type: Easing.InQuad
                }
            }
        }
    ]

    Behavior on color {
        ColorAnimation {
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }

    Behavior on opacity {
        OpacityAnimator {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    MouseArea {
        id: hoverArea

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    RowLayout {
        id: content

        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.topMargin: 12 + root.completionOffset
        anchors.bottomMargin: 12
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

                Behavior on color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: root.categoryName.length > 0
                spacing: 6

                Rectangle {
                    Layout.preferredWidth: root.categoryColor.length > 0 ? 12 : 0
                    Layout.preferredHeight: 12
                    radius: 3
                    visible: root.categoryColor.length > 0
                    color: root.categoryColor
                }

                Text {
                    Layout.fillWidth: true
                    text: root.categoryName
                    font.pixelSize: 12
                    color: "#8b7355"
                    elide: Text.ElideRight
                }
            }
        }

        Button {
            id: focusButton

            text: root.taskCompleted ? "已完成" : "开始专注"
            enabled: !root.taskCompleted
            implicitWidth: 104
            implicitHeight: 44

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
