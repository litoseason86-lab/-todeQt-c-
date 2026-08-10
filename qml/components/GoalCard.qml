pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../GoalForecast.js" as GoalForecast
import ".."

// 列表卡只消费 GoalService 已聚合好的 map，不在组件内部查服务。
// 这样列表、网格和后续详情页共享同一份进度事实，避免刷新时出现不同口径。
//
// 版式（2026-08-10 定）：三层——标题行、横贯的进度条、结论行。
// 此前是「小环形 + 两行文字 + 一个恒为『进行中』的徽章」，右侧近半宽度全空，
// 科目和截止日都没露出，而「照这个速度来不来得及」要用户拿两个数自己心算。
AbstractButton {
    id: root

    property var goal: ({})
    // 逻辑日由页面注入：凌晨 4 点前算前一天，这条规则只能有一个来源。
    property var today: new Date()

    readonly property int goalId: Number(root.goal.id || -1)
    readonly property int doneCount: Math.max(0, Number(root.goal.doneCount || 0))
    readonly property int targetCount: Math.max(0, Number(root.goal.targetPomodoros || 0))
    readonly property int percent: Math.max(0, Math.min(100, Number(root.goal.percent || 0)))
    readonly property bool achieved: Boolean(root.goal.achieved)
    readonly property string categoryName: String(root.goal.categoryName || "")
    readonly property color categoryColor: String(root.goal.categoryColor || "").length > 0
                                           ? root.goal.categoryColor : Theme.accent

    readonly property var forecastVerdict: GoalForecast.verdict(root.goal, root.today)
    readonly property string detailText: GoalForecast.detail(root.goal, root.today)
    readonly property color verdictColor: {
        if (root.forecastVerdict.tone === "good")
            return Theme.focusBreakInk
        if (root.forecastVerdict.tone === "warn")
            return Theme.danger
        return Theme.inkSoft
    }

    implicitWidth: 560
    implicitHeight: 94
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    leftPadding: Theme.space16
    rightPadding: Theme.space16
    topPadding: Theme.space12
    bottomPadding: Theme.space12
    Accessible.name: String(root.goal.title || qsTr("未命名目标"))
                     + "，" + root.percent + "%，"
                     + root.detailText + "，" + root.forecastVerdict.text

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

    contentItem: ColumnLayout {
        spacing: Theme.space8

        // ① 标题行：科目在最左，计数与百分比靠右——右侧原本是整片空白。
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Rectangle {
                Layout.preferredWidth: 8
                Layout.preferredHeight: 8
                Layout.alignment: Qt.AlignVCenter
                radius: 4
                visible: root.categoryName.length > 0
                color: root.categoryColor
            }

            Text {
                objectName: "goalCardCategory"
                text: root.categoryName
                visible: root.categoryName.length > 0
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }

            Text {
                objectName: "goalCardTitle"
                Layout.fillWidth: true
                text: String(root.goal.title || qsTr("未命名目标"))
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                objectName: "goalCardCount"
                text: qsTr("%1 / %2").arg(root.doneCount).arg(root.targetCount)
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamilyData
            }

            Text {
                objectName: "goalCardPercent"
                text: root.percent + "%"
                textFormat: Text.PlainText
                color: root.achieved ? Theme.focusBreakInk : Theme.accentInk
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
                font.family: Theme.fontFamilyData
            }
        }

        // ② 进度条横贯整行。长期目标的主信息是「推进到哪了」，
        // 一条贯穿的条比角落里一个 44px 的环形更能表达这件事，也把右侧空白用起来。
        Rectangle {
            objectName: "goalCardProgressTrack"
            Layout.fillWidth: true
            Layout.preferredHeight: 6
            radius: 3
            color: Theme.surfaceSunken

            Rectangle {
                objectName: "goalCardProgressFill"
                width: parent.width * root.percent / 100
                height: parent.height
                radius: 3
                color: root.achieved ? Theme.focusBreakAccent : Theme.accent
                // 不给宽度加 Behavior：列表开了 reuseItems，卡片实例会被换到另一个
                // 目标上，动画会让它先显示上一个目标的进度再滑过去——那正是
                // tst_goals_view 里「复用后必须立刻用新数据」要防的事。
            }
        }

        // ③ 结论行：左边陈述事实，右边给判断。
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Text {
                objectName: "goalCardDetail"
                Layout.fillWidth: true
                text: root.detailText
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontXs
                elide: Text.ElideRight
            }

            Text {
                objectName: "goalCardVerdict"
                text: root.forecastVerdict.text
                textFormat: Text.PlainText
                color: root.verdictColor
                font.pixelSize: Theme.fontXs
                font.weight: Font.Medium
            }
        }
    }
}
