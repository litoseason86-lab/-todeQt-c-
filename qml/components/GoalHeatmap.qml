pragma ComponentBehavior: Bound

import QtQuick
// 只用 ToolTip 附加属性、不定制任何控件外观，因此保持不锁定具体样式的导入。
import QtQuick.Controls
import QtQuick.Layouts
import ".."

// 月历只负责把服务层的 [{day,count}] 映射成强度，不重复判断“什么算有效番茄”。
// 周一作为首列，与项目现有专注历史月历保持一致。
Item {
    id: root

    property int year: new Date().getFullYear()
    property int month: new Date().getMonth() + 1
    property var dailyCounts: []
    property date today: new Date()
    readonly property int daysInMonth: new Date(root.year, root.month, 0).getDate()
    readonly property int firstOffset: {
        var weekDay = new Date(root.year, root.month - 1, 1).getDay()
        return weekDay === 0 ? 6 : weekDay - 1
    }
    readonly property var countsByDay: root.buildCounts(root.dailyCounts)
    readonly property int maxCount: root.findMaxCount(root.dailyCounts)

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

    function findMaxCount(source) {
        var maximum = 0
        for (var i = 0; i < (source || []).length; ++i)
            maximum = Math.max(maximum, Number(source[i].count || 0))
        return maximum
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
                readonly property bool isToday: inMonth
                                                   && root.today.getFullYear() === root.year
                                                   && root.today.getMonth() + 1 === root.month
                                                   && root.today.getDate() === day
                readonly property real intensity: count > 0 && root.maxCount > 0
                                                  ? 0.25 + 0.75 * count / root.maxCount : 0
                readonly property string accessibilityName: {
                    if (!dayCell.inMonth)
                        return ""
                    if (dayCell.isToday) {
                        return dayCell.count > 0
                                ? qsTr("%1 日，今天，%2 个番茄").arg(dayCell.day).arg(dayCell.count)
                                : qsTr("%1 日，今天，无投入").arg(dayCell.day)
                    }
                    return dayCell.count > 0
                            ? qsTr("%1 日，%2 个番茄").arg(dayCell.day).arg(dayCell.count)
                            : qsTr("%1 日，无投入").arg(dayCell.day)
                }

                objectName: inMonth ? "goalHeatmapDay-" + day : "goalHeatmapOffset-" + index
                width: (calendarGrid.width - Theme.space4 * 6) / 7
                height: 38
                radius: Theme.radiusSm
                color: inMonth ? Theme.surfaceSunken : "transparent"
                border.color: dayCell.isToday ? Theme.accent : "transparent"
                border.width: dayCell.isToday ? 2 : 0

                // 投入量此前只由色块深浅表达，读屏用户和色觉障碍用户拿不到任何数量信息，
                // 格子里的数字又是日期不是数量。这里补两条非颜色通道：
                // 读屏播报走 Accessible.name，鼠标用户走悬停提示。
                Accessible.role: Accessible.StaticText
                Accessible.ignored: !dayCell.inMonth
                Accessible.name: dayCell.accessibilityName

                ToolTip {
                    visible: dayHover.hovered && dayCell.inMonth
                    delay: 300
                    text: dayCell.count > 0
                          ? qsTr("%1 月 %2 日 · %3 个番茄")
                            .arg(root.month).arg(dayCell.day).arg(dayCell.count)
                          : qsTr("%1 月 %2 日 · 无投入").arg(root.month).arg(dayCell.day)
                }

                HoverHandler {
                    id: dayHover
                    enabled: dayCell.inMonth
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: dayCell.isToday ? 2 : 0
                    radius: Math.max(1, parent.radius - anchors.margins)
                    color: Theme.accent
                    opacity: dayCell.intensity
                }

                Text {
                    anchors.centerIn: parent
                    text: dayCell.inMonth ? dayCell.day : ""
                    color: dayCell.count > 0 && dayCell.intensity > 0.55
                           ? Theme.accentForeground : Theme.ink
                    font.pixelSize: Theme.fontSm
                    font.weight: dayCell.isToday ? Font.Bold : Font.Normal
                    // 无障碍名称由父格子统一提供，避免辅助技术重复朗读日期。
                    Accessible.ignored: true
                }
            }
        }
    }
}
