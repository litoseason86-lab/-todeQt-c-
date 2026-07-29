pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 网格瓦片与列表卡使用同一个 goal map，只缩短副文案，避免窄卡被预测文字撑坏。
AbstractButton {
    id: root

    property var goal: ({})
    readonly property int goalId: Number(root.goal.id || -1)
    readonly property int doneCount: Math.max(0, Number(root.goal.doneCount || 0))
    readonly property int targetCount: Math.max(0, Number(root.goal.targetPomodoros || 0))
    readonly property int percent: Math.max(0, Math.min(100, Number(root.goal.percent || 0)))
    readonly property bool achieved: Boolean(root.goal.achieved)
    readonly property string secondaryText: root.achieved
                                            ? qsTr("已达成")
                                            : qsTr("%1 / %2 番茄").arg(root.doneCount).arg(root.targetCount)

    implicitWidth: 160
    implicitHeight: 158
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    // 与列表卡同理：AbstractButton 默认零内边距，contentItem 会铺到描边，
    // 长标题会一路 elide 到边框上。瓦片比列表卡窄，取小一档避免挤压中间的进度环。
    leftPadding: Theme.space12
    rightPadding: Theme.space12
    Accessible.name: String(root.goal.title || qsTr("未命名目标")) + "，" + root.secondaryText

    // 与列表卡走同一套玻璃分层，避免两种版式在同一页里厚度感不一致。
    background: GlassPanel {
        objectName: "goalTileBackground"

        color: {
            if (!Theme.glassBlurAllowed)
                return root.down || root.hovered ? Theme.glassSolidHover : Theme.glassSolidCard
            return root.down || root.hovered ? Theme.glassHover : Theme.glassCard
        }
        border.color: root.activeFocus ? Theme.focusRing
                                       : (root.hovered ? Theme.accent : Theme.glassBorderContrast)
        border.width: root.activeFocus ? 2 : 1
        bottomRimEnabled: true
        // 与列表卡同理：delegate 不用落影，避免逐格 FBO 与效果失败时整块消失。
        panelShadowEnabled: false
        solidFallback: !Theme.glassBlurAllowed

        Behavior on color {
            ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
        }
    }

    contentItem: ColumnLayout {
        spacing: Theme.space8

        GoalProgressRing {
            percent: root.percent
            achieved: root.achieved
            ringSize: 72
            strokeWidth: 6
            labelPixelSize: Theme.fontLg
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 76
            Layout.preferredHeight: 76
        }

        Text {
            Layout.fillWidth: true
            text: String(root.goal.title || qsTr("未命名目标"))
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontMd
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true
            text: root.secondaryText
            textFormat: Text.PlainText
            color: root.achieved ? Theme.accentInk : Theme.inkSoft
            font.pixelSize: Theme.fontSm
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }
}
