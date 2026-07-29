pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 列表卡只消费 GoalService 已聚合好的 map，不在组件内部查服务。
// 这样列表、网格和后续详情页共享同一份进度事实，避免刷新时出现不同口径。
AbstractButton {
    id: root

    property var goal: ({})
    readonly property int goalId: Number(root.goal.id || -1)
    readonly property int doneCount: Math.max(0, Number(root.goal.doneCount || 0))
    readonly property int targetCount: Math.max(0, Number(root.goal.targetPomodoros || 0))
    readonly property int percent: Math.max(0, Math.min(100, Number(root.goal.percent || 0)))
    readonly property bool achieved: Boolean(root.goal.achieved)
    readonly property int forecastDays: Number(root.goal.forecastDays === undefined ? -1
                                                                            : root.goal.forecastDays)
    readonly property string secondaryText: {
        if (root.achieved) {
            var achievedAt = root.goal.achievedAt
            var dateText = achievedAt ? Qt.formatDate(achievedAt, "M月d日") : ""
            return dateText.length > 0 ? qsTr("已达成 · %1").arg(dateText) : qsTr("已达成")
        }
        var progress = qsTr("%1 / %2 番茄").arg(root.doneCount).arg(root.targetCount)
        return root.forecastDays > 0
                ? progress + qsTr(" · 照此速度还需 %1 天").arg(root.forecastDays)
                : progress
    }

    implicitWidth: 560
    implicitHeight: 76
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    // AbstractButton 默认不留内边距，contentItem 会一直铺到卡边框，
    // 右侧状态徽章因此几乎贴着描边。左右各留一档，让内容在玻璃里有呼吸位。
    leftPadding: Theme.space16
    rightPadding: Theme.space16
    Accessible.name: String(root.goal.title || qsTr("未命名目标")) + "，" + root.secondaryText

    // 玻璃分层复用 GlassPanel：着色 + 顶部受光棱边 + 底部暗棱。
    // 之前是裸 Rectangle，只有一层均匀半透明，壁纸亮部会把卡边界吃掉——
    // 让卡片在任意壁纸上都站得住的是棱边，不是落影。
    //
    // 刻意关掉落影：落影走 layer.enabled + MultiEffect，列表每一行都会多占一个 FBO
    // 和一遍阴影 pass；而且一旦该效果初始化失败，整块面板会连同底色一起消失
    // （内容卡是本页主体，不能承担这个风险）。厚度感由上下棱边 + 描边表达。
    background: GlassPanel {
        objectName: "goalCardBackground"

        color: {
            if (!Theme.glassBlurAllowed)
                return root.down || root.hovered ? Theme.glassSolidHover : Theme.glassSolidCard
            return root.down || root.hovered ? Theme.glassHover : Theme.glassCard
        }
        border.color: root.activeFocus ? Theme.focusRing
                                       : (root.hovered ? Theme.accent : Theme.glassBorderContrast)
        border.width: root.activeFocus ? 2 : 1
        bottomRimEnabled: true
        panelShadowEnabled: false
        solidFallback: !Theme.glassBlurAllowed

        Behavior on color {
            ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
        }
    }

    contentItem: RowLayout {
        spacing: Theme.space12

        GoalProgressRing {
            percent: root.percent
            achieved: root.achieved
            ringSize: 44
            strokeWidth: 4
            labelPixelSize: Theme.fontXs
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                Layout.fillWidth: true
                text: String(root.goal.title || qsTr("未命名目标"))
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: root.secondaryText
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
            }
        }

        // 状态徽章嵌在卡玻璃上：关掉落影避免阴影叠层发灰，
        // 关掉棱边高光避免小色块上出现过密的亮线。
        GlassPanel {
            Layout.preferredWidth: statusText.implicitWidth + Theme.space16
            Layout.preferredHeight: 28
            radius: height / 2
            color: root.achieved ? Theme.glassAccent : Theme.accentFill
            border.color: root.achieved ? Theme.accentInk : "transparent"
            border.width: root.achieved ? 1 : 0
            specularEnabled: false
            panelShadowEnabled: false

            Text {
                id: statusText
                anchors.centerIn: parent
                text: root.achieved ? qsTr("已达成") : qsTr("进行中")
                color: Theme.accentFillInk
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
            }
        }
    }
}
