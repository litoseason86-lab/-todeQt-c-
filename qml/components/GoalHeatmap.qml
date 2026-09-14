pragma ComponentBehavior: Bound

import QtQuick
// 只用 ToolTip 附加属性、不定制任何控件外观，因此保持不锁定具体样式的导入。
import QtQuick.Controls
import QtQuick.Layouts
import ".."
import "../Duration.js" as Duration
import "../HeatmapBands.js" as HeatmapBands

// 月历只负责把服务层的 [{day,count}] 映射成档位，不重复判断“什么算有效番茄”。
// count 是**分钟**（GoalService 按有效会话 SUM(duration)/60 汇总），不是番茄数。
// 周一作为首列，与项目现有专注历史月历保持一致。
//
// 取档与专注历史月历共用 HeatmapBands.bandForMinutes：共用的是「分钟数 → 档位」的映射，
// 不是输入——这里是该目标的投入，那边是当天全部投入，同一天落进不同档是正确的。
// 零值、今日、未来逐格按传入的 today（调用方给逻辑今日）判断，
// 规则见 docs/业务规则.md「热力取档与专注历史月历的投入条」。
Item {
    id: root

    property int year: new Date().getFullYear()
    property int month: new Date().getMonth() + 1
    property var dailyCounts: []
    // 调用方传逻辑今日（凌晨记账算前一天）；这里不自己拿 new Date() 比。
    property date today: new Date()
    readonly property int daysInMonth: new Date(root.year, root.month, 0).getDate()
    readonly property int firstOffset: {
        var weekDay = new Date(root.year, root.month - 1, 1).getDay()
        return weekDay === 0 ? 6 : weekDay - 1
    }
    readonly property var countsByDay: root.buildCounts(root.dailyCounts)
    readonly property int todayKey: root.today.getFullYear() * 10000
                                    + (root.today.getMonth() + 1) * 100 + root.today.getDate()

    implicitWidth: 360
    implicitHeight: weekdayRow.implicitHeight + Theme.space8
                    + calendarGrid.implicitHeight

    function buildCounts(source) {
        var values = ({})
        for (var i = 0; i < (source || []).length; ++i) {
            var day = Number(source[i].day || 0)
            var count = Math.max(0, Number(source[i].count || 0))
            if (day >= 1 && day <= root.daysInMonth && count > 0)
                values[day] = count
        }
        return values
    }

    function countForDay(day) {
        return Number(root.countsByDay[day] || 0)
    }

    RowLayout {
        id: weekdayRow

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Theme.space4

        Repeater {
            model: [qsTr("一"), qsTr("二"), qsTr("三"), qsTr("四"),
                    qsTr("五"), qsTr("六"), qsTr("日")]

            Text {
                required property string modelData
                Layout.fillWidth: true
                text: modelData
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontXs
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    Grid {
        id: calendarGrid

        anchors.top: weekdayRow.bottom
        anchors.topMargin: Theme.space8
        width: parent.width
        columns: 7
        columnSpacing: Theme.space4
        rowSpacing: Theme.space4

        Repeater {
            model: root.firstOffset + root.daysInMonth

            Rectangle {
                id: dayCell

                required property int index
                readonly property int day: dayCell.index - root.firstOffset + 1
                readonly property bool inMonth: day > 0
                readonly property int count: inMonth ? root.countForDay(day) : 0
                readonly property int dayKey: root.year * 10000 + root.month * 100 + day
                readonly property bool isToday: inMonth && dayKey === root.todayKey
                // 未来格不参与投入比较：不取档、不填色。
                readonly property bool futureCell: inMonth && dayKey > root.todayKey
                readonly property int heatBand: inMonth && !futureCell
                                                ? HeatmapBands.bandForMinutes(count)
                                                : HeatmapBands.NONE
                // 四种语义各给各的词：未来不能播成「没学」，今天没过完也不是「无投入」。
                readonly property string statusText: {
                    if (dayCell.futureCell)
                        return qsTr("尚未到来")
                    if (dayCell.heatBand !== HeatmapBands.NONE)
                        return qsTr("投入 %1").arg(Duration.format(dayCell.count))
                    return dayCell.isToday ? qsTr("今日暂无投入") : qsTr("无投入")
                }
                readonly property string accessibilityName: {
                    if (!dayCell.inMonth)
                        return ""
                    if (dayCell.isToday && dayCell.heatBand !== HeatmapBands.NONE)
                        return qsTr("%1 日，今天，%2").arg(dayCell.day).arg(dayCell.statusText)
                    return qsTr("%1 日，%2").arg(dayCell.day).arg(dayCell.statusText)
                }
                readonly property string tooltipText: dayCell.inMonth
                    ? qsTr("%1 月 %2 日 · %3").arg(root.month).arg(dayCell.day).arg(dayCell.statusText)
                    : ""

                objectName: inMonth ? "goalHeatmapDay-" + day : "goalHeatmapOffset-" + index
                width: (calendarGrid.width - Theme.space4 * 6) / 7
                height: 38
                radius: Theme.radiusSm
                // 定稿色值是不透明纯色，不再叠 opacity：规格色就是屏幕上那个色，才能按规格复核。
                color: {
                    if (!dayCell.inMonth || dayCell.futureCell)
                        return "transparent"
                    return dayCell.heatBand === HeatmapBands.NONE
                            ? Theme.surfaceSunken : Theme.heatmapBandColors[dayCell.heatBand]
                }
                // 过去零投入与未来的区分落在未来格这圈描边上（零值底色对页面底只有 ΔE00 4.8、夜间 2.6），
                // 调细到 borderSubtle 两态会在夜间合并。今日标记 accent 2px 优先。
                border.color: dayCell.isToday ? Theme.accent
                                              : (dayCell.futureCell ? Theme.border : "transparent")
                border.width: dayCell.isToday ? 2 : (dayCell.futureCell ? 1 : 0)

                // 投入量此前只由色块深浅表达，读屏用户和色觉障碍用户拿不到任何数量信息，
                // 格子里的数字又是日期不是数量。这里补两条非颜色通道：
                // 读屏播报走 Accessible.name，鼠标用户走悬停提示。
                Accessible.role: Accessible.StaticText
                Accessible.ignored: !dayCell.inMonth
                Accessible.name: dayCell.accessibilityName

                ToolTip {
                    visible: dayHover.hovered && dayCell.inMonth
                    delay: 300
                    text: dayCell.tooltipText
                }

                HoverHandler {
                    id: dayHover
                    enabled: dayCell.inMonth
                }

                Text {
                    objectName: dayCell.inMonth ? "goalHeatmapDayText-" + dayCell.day : ""
                    anchors.centerIn: parent
                    text: dayCell.inMonth ? dayCell.day : ""
                    textFormat: Text.PlainText
                    // 零投入与未来的日期保留 ink，不降成 inkMuted：inkMuted 在零值底上日间只有 2.88:1。
                    color: dayCell.heatBand === HeatmapBands.NONE
                           ? Theme.ink : Theme.heatmapBandInkColors[dayCell.heatBand]
                    font.pixelSize: Theme.fontSm
                    font.weight: dayCell.isToday ? Font.Bold : Font.Normal
                    // 无障碍名称由父格子统一提供，避免辅助技术重复朗读日期。
                    Accessible.ignored: true
                }
            }
        }
    }
}
