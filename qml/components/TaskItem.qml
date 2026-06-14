import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts

Rectangle {
    id: root

    Layout.fillWidth: true
    implicitHeight: Math.max(76, content.implicitHeight + 28)
    radius: 8
    color: root.itemHovered ? "#fffef9" : "#faf6ee"
    border.color: root.itemHovered ? "#d4a574" : "#e8dfc8"
    border.width: root.itemHovered ? 1.5 : 1
    // MultiEffect 的阴影参数不直接承载动画，先放到 root 属性上过渡，再绑定给效果。
    property color warmShadowColor: "#5d4e37"
    property real warmShadowOpacity: root.itemHovered ? 0.12 : 0.08
    property real warmShadowBlur: root.itemHovered ? 0.25 : 0.18
    property real warmShadowVerticalOffset: root.itemHovered ? 6 : 2
    layer.enabled: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: root.warmShadowColor
        shadowOpacity: root.warmShadowOpacity
        shadowBlur: root.warmShadowBlur
        shadowHorizontalOffset: 0
        shadowVerticalOffset: root.warmShadowVerticalOffset
    }

    property int taskId: 0
    property string taskTitle: ""
    property var taskCategory: ""
    property bool taskCompleted: false
    // 显式记录指针状态，避免不同平台的 MouseArea/HoverHandler 事件差异影响 hover 视觉。
    property bool pointerInside: false
    property real completionOffset: 0
    readonly property bool itemHovered: root.pointerInside
    // 视图可能传入标准化科目对象，也可能传入旧版字符串科目。
    readonly property string categoryName: typeof taskCategory === "object" ? (taskCategory && taskCategory.name ? taskCategory.name : "") : String(taskCategory || "")
    readonly property string categoryColor: typeof taskCategory === "object" ? (taskCategory && taskCategory.color ? taskCategory.color : "") : ""

    signal completionChanged(int taskId, bool completed)
    signal startFocusClicked(int taskId, string title)
    signal deleteClicked(int taskId, string title)

    function setPointerInside(inside) {
        root.pointerInside = inside;
    }

    states: [
        // 完成状态只做轻微位移和透明度变化，避免影响相邻任务布局。
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
                root.opacity: 0.70
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
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Behavior on border.color {
        ColorAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Behavior on border.width {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Behavior on warmShadowOpacity {
        NumberAnimation {
            duration: 200
            easing.type: Easing.OutQuad
        }
    }

    Behavior on warmShadowBlur {
        NumberAnimation {
            duration: 200
            easing.type: Easing.OutQuad
        }
    }

    Behavior on warmShadowVerticalOffset {
        NumberAnimation {
            duration: 200
            easing.type: Easing.OutQuad
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

        // 这里只处理视觉悬停；按钮和复选框各自处理点击。
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: root.setPointerInside(true)
        onExited: root.setPointerInside(false)
    }

    HoverHandler {
        id: hoverHandler

        // HoverHandler 补足触控板或平台事件路径，MouseArea 仍负责原有视觉悬停边界。
        onHoveredChanged: root.setPointerInside(hovered)
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

            objectName: "taskCheckBox"
            Layout.preferredWidth: 28
            Layout.preferredHeight: 40
            padding: 0
            checked: root.taskCompleted
            onToggled: root.completionChanged(root.taskId, checked)

            indicator: Rectangle {
                objectName: "taskCheckIndicator"
                implicitWidth: 20
                implicitHeight: 20
                x: checkbox.leftPadding
                y: (checkbox.height - height) / 2
                radius: 4
                color: checkbox.checked ? "#d4a574" : "transparent"
                border.color: checkbox.hovered ? "#d4a574" : "#e8dfc8"
                border.width: checkbox.hovered ? 2 : 1.5

                Text {
                    anchors.centerIn: parent
                    text: "✓"
                    visible: checkbox.checked
                    color: "#fffef9"
                    font.pixelSize: 14
                    font.weight: Font.Bold
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.width {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: Item {
                implicitWidth: 0
                implicitHeight: 0
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                objectName: "taskTitleText"
                Layout.fillWidth: true
                text: root.taskTitle
                font.pixelSize: 15
                font.weight: Font.Medium
                lineHeight: 1.4
                color: root.taskCompleted ? "#8b7355" : "#3d3327"
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

            objectName: "focusButton"
            text: root.taskCompleted ? "已完成" : "开始专注"
            enabled: !root.taskCompleted
            implicitWidth: 104
            implicitHeight: 40
            // down 是 Qt Controls 的视觉按下态；真实点击会同步 pressed，测试可稳定驱动 down。
            readonly property bool pressFeedbackActive: focusButton.enabled && (focusButton.down || focusButton.pressed)

            ToolTip.visible: hovered && !enabled
            ToolTip.text: "已完成任务不能开始专注"

            background: Rectangle {
                id: focusButtonBackground

                objectName: "focusButtonBackground"
                radius: 6
                y: focusButton.pressFeedbackActive ? 1 : 0
                color: {
                    if (!focusButton.enabled)
                        return "#e8dfc8";
                    if (focusButton.pressFeedbackActive)
                        return "#b9854f";
                    if (focusButton.hovered)
                        return "#c8955f";
                    return "#d4a574";
                }
                property color warmShadowColor: "#5d4e37"
                property real warmShadowOpacity: focusButton.pressFeedbackActive ? 0.04 : 0.08
                property real warmShadowBlur: focusButton.pressFeedbackActive ? 0.10 : 0.14
                property real warmShadowVerticalOffset: focusButton.pressFeedbackActive ? 1 : 2
                layer.enabled: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: focusButtonBackground.warmShadowColor
                    shadowOpacity: focusButtonBackground.warmShadowOpacity
                    shadowBlur: focusButtonBackground.warmShadowBlur
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: focusButtonBackground.warmShadowVerticalOffset
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 160
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on y {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowOpacity {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowBlur {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowVerticalOffset {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: Text {
                objectName: "focusButtonLabel"
                text: focusButton.text
                color: focusButton.enabled ? "#fffef9" : "#a0896b"
                font.pixelSize: 13
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                scale: focusButton.pressFeedbackActive ? 0.98 : 1.0
                transformOrigin: Item.Center

                Behavior on scale {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }
            }

            onClicked: root.startFocusClicked(root.taskId, root.taskTitle)
        }

        Button {
            id: deleteButton

            objectName: "taskDeleteButton"
            text: "删除"
            implicitWidth: 56
            implicitHeight: 40
            readonly property bool pressFeedbackActive: deleteButton.down || deleteButton.pressed

            background: Rectangle {
                id: taskDeleteButtonBackground

                objectName: "taskDeleteButtonBackground"
                radius: 6
                y: deleteButton.pressFeedbackActive ? 1 : 0
                color: {
                    if (deleteButton.pressFeedbackActive)
                        return "#f0e6d2";
                    if (deleteButton.hovered)
                        return "#f5ede3";
                    return "#fffef9";
                }
                border.color: deleteButton.hovered || deleteButton.pressFeedbackActive ? "#b37562" : "#e8dfc8"
                border.width: 1
                property color warmShadowColor: "#5d4e37"
                property real warmShadowOpacity: deleteButton.pressFeedbackActive ? 0.04 : 0.08
                property real warmShadowBlur: deleteButton.pressFeedbackActive ? 0.10 : 0.14
                property real warmShadowVerticalOffset: deleteButton.pressFeedbackActive ? 1 : 2
                layer.enabled: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: taskDeleteButtonBackground.warmShadowColor
                    shadowOpacity: taskDeleteButtonBackground.warmShadowOpacity
                    shadowBlur: taskDeleteButtonBackground.warmShadowBlur
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: taskDeleteButtonBackground.warmShadowVerticalOffset
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 160
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: 160
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on y {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowOpacity {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowBlur {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowVerticalOffset {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: Text {
                objectName: "taskDeleteButtonLabel"
                text: deleteButton.text
                color: "#b37562"
                font.pixelSize: 13
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                scale: deleteButton.pressFeedbackActive ? 0.98 : 1.0
                transformOrigin: Item.Center

                Behavior on scale {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }
            }

            onClicked: root.deleteClicked(root.taskId, root.taskTitle)
        }
    }
}
