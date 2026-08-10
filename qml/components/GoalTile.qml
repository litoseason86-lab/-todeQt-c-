pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../Duration.js" as Duration
import "../GoalForecast.js" as GoalForecast
import ".."

// 网格瓦片与列表卡使用同一个 goal map 和同一个结论函数，只是排布不同：
// 环形是网格模式的辨识度，留着；科目和「来不来得及」补齐，
// 否则切到网格等于丢信息（2026-08-10 之前网格比列表还少三项）。
AbstractButton {
    id: root

    property var goal: ({})
    readonly property int goalId: Number(root.goal.id || -1)
    readonly property int doneMinutes: Math.max(0, Number(root.goal.doneMinutes || 0))
    readonly property int targetMinutes: Math.max(0, Number(root.goal.targetMinutes || 0))
    readonly property int percent: Math.max(0, Math.min(100, Number(root.goal.percent || 0)))
    readonly property bool achieved: Boolean(root.goal.achieved)
    readonly property string categoryName: String(root.goal.categoryName || "")
    readonly property color categoryColor: String(root.goal.categoryColor || "").length > 0
                                           ? root.goal.categoryColor : Theme.accent
    // 计数行始终报计数：达成与否由环形和下面的结论行表达，
    // 这里再写一次「已达成」会让同一张卡上出现两遍同样的词。
    readonly property string secondaryText: Duration.format(root.doneMinutes)
                                           + " / " + Duration.format(root.targetMinutes)

    // 逻辑日由页面注入，与列表卡同一来源。
    property var today: new Date()
    readonly property var forecastVerdict: GoalForecast.verdict(root.goal, root.today)
    readonly property color verdictColor: {
        if (root.forecastVerdict.tone === "good")
            return Theme.focusBreakInk
        if (root.forecastVerdict.tone === "warn")
            return Theme.danger
        return Theme.inkSoft
    }

    implicitWidth: 160
    implicitHeight: 196
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    // 与列表卡同理：AbstractButton 默认零内边距，contentItem 会铺到描边，
    // 长标题会一路 elide 到边框上。瓦片比列表卡窄，取小一档避免挤压中间的进度环。
    leftPadding: Theme.space12
    rightPadding: Theme.space12
    topPadding: Theme.space12
    bottomPadding: Theme.space12
    Accessible.name: String(root.goal.title || qsTr("未命名目标")) + "，"
                     + root.secondaryText + "，" + root.forecastVerdict.text

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

        // 科目：与列表行同一套语汇（色点 + 名字），居中排。
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.space4
            visible: root.categoryName.length > 0

            Rectangle {
                Layout.preferredWidth: 8
                Layout.preferredHeight: 8
                Layout.alignment: Qt.AlignVCenter
                radius: 4
                color: root.categoryColor
            }

            Text {
                objectName: "goalTileCategory"
                text: root.categoryName
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontXs
            }
        }

        Text {
            objectName: "goalTileCount"
            Layout.fillWidth: true
            text: root.secondaryText
            textFormat: Text.PlainText
            color: root.achieved ? Theme.focusBreakInk : Theme.inkSoft
            font.pixelSize: Theme.fontSm
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }

        // 结论。窄卡放不下完整的事实行，只保留判断本身——
        // 「照此速度 N 天完成 · 距截止 M 天」留给列表模式和详情页。
        Text {
            objectName: "goalTileVerdict"
            Layout.fillWidth: true
            text: root.forecastVerdict.text
            textFormat: Text.PlainText
            color: root.verdictColor
            font.pixelSize: Theme.fontXs
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }
}
