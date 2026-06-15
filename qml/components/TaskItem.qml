import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    Layout.fillWidth: true
    implicitHeight: Math.max(76, content.implicitHeight + 28)
    radius: Theme.radiusLg
    color: root.itemHovered ? Theme.surface : Theme.surfaceRaised
    border.color: root.itemHovered ? Theme.accent : Theme.border
    border.width: root.itemHovered ? 1.5 : 1
    // MultiEffect 的阴影参数不直接承载动画，先放到 root 属性上过渡，再绑定给效果。
    property color warmShadowColor: Theme.ink
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
    property bool visualTaskCompleted: false
    // 显式记录指针状态，避免不同平台的 MouseArea/HoverHandler 事件差异影响 hover 视觉。
    property bool pointerInside: false
    property bool componentReady: false
    property bool completionAnimationPlayed: false
    property real completionOffset: 0
    readonly property bool itemHovered: root.pointerInside
    // 视图可能传入标准化科目对象，也可能传入旧版字符串科目。
    readonly property string categoryName: typeof taskCategory === "object" ? (taskCategory && taskCategory.name ? taskCategory.name : "") : String(taskCategory || "")
    readonly property string categoryColor: typeof taskCategory === "object" ? (taskCategory && taskCategory.color ? taskCategory.color : "") : ""
    readonly property var completionParticleColors: [Theme.accent, Theme.border, Theme.borderSubtle]
    readonly property var completionParticleDirections: [[-1, -1], [-1, 0], [-1, 1], [1, -1], [1, 0], [1, 1]]

    signal completionChanged(int taskId, bool completed)
    signal startFocusClicked(int taskId, string title)
    signal deleteClicked(int taskId, string title)

    function setPointerInside(inside) {
        root.pointerInside = inside;
    }

    function playCompletionAnimation() {
        if (root.completionAnimationPlayed)
            return;
        if (particleContainer.particleCount > 0)
            return;

        root.completionAnimationPlayed = true;

        var indicatorPosition = checkIndicator.mapToItem(root, 0, 0);
        var particleSize = 5;
        var travelDistance = 38;
        var startX = indicatorPosition.x + checkIndicator.width / 2 - particleSize / 2;
        var startY = indicatorPosition.y + checkIndicator.height / 2 - particleSize / 2;

        for (var i = 0; i < root.completionParticleDirections.length; ++i) {
            var direction = root.completionParticleDirections[i];
            var targetX = startX + direction[0] * travelDistance;
            var targetY = startY + direction[1] * travelDistance;
            var particle = completionParticleComponent.createObject(particleContainer, {
                    "x": startX,
                    "y": startY,
                    "startX": startX,
                    "startY": startY,
                    "targetX": targetX,
                    "targetY": targetY,
                    "directionX": direction[0],
                    "directionY": direction[1],
                    "color": root.completionParticleColors[i % root.completionParticleColors.length]
                });

            if (particle === null)
                console.warn("创建任务完成粒子失败");
        }
    }

    onTaskCompletedChanged: {
        if (!root.componentReady) {
            // 初始数据可能直接带着已完成状态进来，此时不播放庆祝动画，只记录状态边界。
            root.visualTaskCompleted = root.taskCompleted;
            root.completionAnimationPlayed = root.taskCompleted;
            return;
        }

        root.visualTaskCompleted = root.taskCompleted;
        if (root.taskCompleted) {
            root.playCompletionAnimation();
        } else {
            // 取消完成后必须重置，下一次重新勾选才允许再次播放庆祝动画。
            root.completionAnimationPlayed = false;
        }
    }

    Component.onCompleted: {
        root.visualTaskCompleted = root.taskCompleted;
        root.componentReady = true;
        root.completionAnimationPlayed = root.taskCompleted;
    }

    states: [
        // 完成状态只做轻微位移和透明度变化，避免影响相邻任务布局。
        State {
            name: "normal"
            when: !root.visualTaskCompleted
            PropertyChanges {
                root.opacity: 1.0
                root.completionOffset: 0
            }
        },
        State {
            name: "completed"
            when: root.visualTaskCompleted
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

    Item {
        id: particleContainer

        objectName: "completionParticleContainer"
        anchors.fill: parent
        enabled: false
        z: 20
        readonly property int particleCount: children.length
    }

    Component {
        id: completionParticleComponent

        Rectangle {
            id: particle

            objectName: "completionParticle"
            width: 5
            height: 5
            radius: width / 2
            opacity: 1
            property real startX: 0
            property real startY: 0
            property real targetX: 0
            property real targetY: 0
            property int directionX: 0
            property int directionY: 0

            SequentialAnimation {
                running: true

                ParallelAnimation {
                    NumberAnimation {
                        target: particle
                        property: "x"
                        to: particle.targetX
                        duration: 800
                        easing.type: Easing.OutQuad
                    }

                    NumberAnimation {
                        target: particle
                        property: "y"
                        to: particle.targetY
                        duration: 800
                        easing.type: Easing.OutQuad
                    }

                    OpacityAnimator {
                        target: particle
                        from: 1
                        to: 0
                        duration: 800
                        easing.type: Easing.OutQuad
                    }
                }

                onStopped: particle.destroy()
            }
        }
    }

    RowLayout {
        id: content

        anchors.fill: parent
        anchors.leftMargin: Theme.space12
        anchors.rightMargin: Theme.space12
        anchors.topMargin: Theme.space12 + root.completionOffset
        anchors.bottomMargin: Theme.space12
        spacing: Theme.space12

        CheckBox {
            id: checkbox

            objectName: "taskCheckBox"
            Layout.preferredWidth: 28
            Layout.preferredHeight: 40
            padding: 0
            checked: root.visualTaskCompleted
            onClicked: {
                if (checked) {
                    // 真实点击路径会先进入这里，再由外层同步更新数据源；先切换视觉态并播放动画，
                    // 避免等待 model 回写时 delegate 已被刷新销毁。
                    root.visualTaskCompleted = true;
                    root.playCompletionAnimation();
                } else {
                    root.visualTaskCompleted = false;
                    root.completionAnimationPlayed = false;
                }
                root.completionChanged(root.taskId, checked);
            }

            indicator: Rectangle {
                id: checkIndicator

                objectName: "taskCheckIndicator"
                implicitWidth: 20
                implicitHeight: 20
                x: checkbox.leftPadding
                y: (checkbox.height - height) / 2
                radius: Theme.radiusSm
                color: checkbox.checked ? Theme.accent : "transparent"
                border.color: checkbox.hovered ? Theme.accent : Theme.border
                border.width: checkbox.hovered ? 2 : 1.5

                Text {
                    anchors.centerIn: parent
                    text: "✓"
                    visible: checkbox.checked
                    color: Theme.surface
                    font.pixelSize: Theme.fontLg
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
            spacing: Theme.space4

            Text {
                objectName: "taskTitleText"
                Layout.fillWidth: true
                text: root.taskTitle
                font.pixelSize: Theme.fontLg
                font.weight: Font.Medium
                lineHeight: 1.4
                color: root.visualTaskCompleted ? Theme.inkSoft : Theme.inkStrong
                font.strikeout: root.visualTaskCompleted
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
                spacing: Theme.space8

                Rectangle {
                    Layout.preferredWidth: root.categoryColor.length > 0 ? 12 : 0
                    Layout.preferredHeight: 12
                    radius: Theme.radiusSm
                    visible: root.categoryColor.length > 0
                    color: root.categoryColor
                }

                Text {
                    Layout.fillWidth: true
                    text: root.categoryName
                    font.pixelSize: Theme.fontSm
                    color: Theme.inkSoft
                    elide: Text.ElideRight
                }
            }
        }

        Button {
            id: focusButton

            objectName: "focusButton"
            text: root.visualTaskCompleted ? "已完成" : "开始专注"
            enabled: !root.visualTaskCompleted
            implicitWidth: 104
            implicitHeight: 40
            // down 是 Qt Controls 的视觉按下态；真实点击会同步 pressed，测试可稳定驱动 down。
            readonly property bool pressFeedbackActive: focusButton.enabled && (focusButton.down || focusButton.pressed)

            ToolTip.visible: hovered && !enabled
            ToolTip.text: "已完成任务不能开始专注"

            background: Rectangle {
                id: focusButtonBackground

                objectName: "focusButtonBackground"
                radius: Theme.radiusMd
                y: focusButton.pressFeedbackActive ? 1 : 0
                color: {
                    if (!focusButton.enabled)
                        return Theme.border;
                    if (focusButton.pressFeedbackActive)
                        return Theme.accentStrong;
                    if (focusButton.hovered)
                        return Theme.accentStrong;
                    return Theme.accent;
                }
                property color warmShadowColor: Theme.ink
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
                color: focusButton.enabled ? Theme.surface : Theme.inkMuted
                font.pixelSize: Theme.fontMd
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
                radius: Theme.radiusMd
                y: deleteButton.pressFeedbackActive ? 1 : 0
                color: {
                    if (deleteButton.pressFeedbackActive)
                        return Theme.accentSoft;
                    if (deleteButton.hovered)
                        return Theme.surfaceSunken;
                    return Theme.surface;
                }
                border.color: deleteButton.hovered || deleteButton.pressFeedbackActive ? "#b37562" : Theme.border
                border.width: 1
                property color warmShadowColor: Theme.ink
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
                font.pixelSize: Theme.fontMd
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
