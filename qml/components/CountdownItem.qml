import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property int goalId: -1
    property string goalName: ""
    property date targetDate: new Date()
    property int daysRemaining: 0
    property bool canMoveUp: false
    property bool canMoveDown: false

    signal clicked()
    signal deleteRequested(int goalId)
    signal moveUpRequested()
    signal moveDownRequested()

    height: 62
    radius: Theme.radiusLg
    // 悬停反馈靠“边框变色”表达：底色 idle/hover 都用玻璃卡片材质，
    // 悬停时由 border 从玻璃描边变为 Theme.accent 来提示，所以底色不随悬停变化不是笔误。
    color: Theme.glassCard
    border.color: hitArea.containsMouse ? Theme.accent : Theme.glassBorder
    border.width: 1
    // 悬停事件分发期间不重建效果层，避免 Qt Quick 的 hover 命中树留下失效项指针。
    layer.enabled: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: Theme.shadow
        shadowOpacity: 0.08
        shadowBlur: 0.14
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }

    // 上移/下移/删除共用的安静描边样式：默认玻璃底，悬停才转强调色，
    // 避免每行三颗按钮把列表变成按钮墙。
    component RowActionButton: Button {
        id: actionButton

        implicitWidth: 34
        implicitHeight: 34

        background: Rectangle {
            radius: Theme.radiusMd
            color: actionButton.pressed || actionButton.hovered ? Theme.glassHover : Theme.glassCard
            border.color: actionButton.enabled && (actionButton.hovered || actionButton.pressed)
                          ? Theme.accent : Theme.border
            border.width: 1
            opacity: actionButton.enabled ? 1.0 : 0.45

            Behavior on color {
                ColorAnimation {
                    duration: 120
                    easing.type: Easing.OutQuad
                }
            }

            Behavior on border.color {
                ColorAnimation {
                    duration: 120
                    easing.type: Easing.OutQuad
                }
            }
        }

        contentItem: Text {
            text: actionButton.text
            color: actionButton.enabled ? Theme.inkSoft : Theme.inkMuted
            font.pixelSize: Theme.fontMd
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    MouseArea {
        id: hitArea

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onClicked: root.clicked()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space16
        anchors.rightMargin: Theme.space12
        spacing: Theme.space12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            Text {
                text: root.goalName
                font.pixelSize: Theme.fontLg
                font.weight: Font.Medium
                color: Theme.ink
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Text {
                text: Qt.formatDate(root.targetDate, "yyyy年MM月dd日")
                font.pixelSize: Theme.fontXs
                color: Theme.inkSoft
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        Text {
            visible: root.daysRemaining < 0
            Layout.alignment: Qt.AlignBaseline
            text: "已过期"
            font.pixelSize: Theme.fontXs
            color: Theme.inkSoft
        }

        Text {
            Layout.alignment: Qt.AlignBaseline
            text: Math.abs(Number(root.daysRemaining || 0))
            font.pixelSize: Theme.fontXxl
            font.family: Theme.fontFamilyData
            font.weight: Font.Bold
            color: Theme.accentInk
        }

        Text {
            Layout.alignment: Qt.AlignBaseline
            text: "天"
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
        }

        RowActionButton {
            text: "↑"
            enabled: root.canMoveUp
            Accessible.name: "上移"
            onClicked: root.moveUpRequested()
        }

        RowActionButton {
            text: "↓"
            enabled: root.canMoveDown
            Accessible.name: "下移"
            onClicked: root.moveDownRequested()
        }

        RowActionButton {
            text: "删除"
            implicitWidth: 52
            onClicked: root.deleteRequested(root.goalId)
        }
    }
}
