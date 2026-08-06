import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../views/StatisticsFormat.js" as StatFmt

// 今日学习统计列表：仪表盘任务面板「学习统计」分段的内容体。
// 只呈现 StatisticsService.getTodayTaskStats 给出的数据，不在 QML 里做任何统计计算。
// 本身不带玻璃背景——背景由外层 dashboardTaskPanel 提供。
Item {
    id: root

    property var stats: ({})

    readonly property var tasks: root.stats && root.stats.tasks ? root.stats.tasks : []
    readonly property int totalDuration: root.stats ? Number(root.stats.totalDuration || 0) : 0
    readonly property int taskCount: root.stats ? Number(root.stats.taskCount || 0) : 0

    function rowValueText(item) {
        var seconds = Number(item.focusedSeconds || 0)
        var pomodoros = Number(item.pomodoros || 0)
        var base = StatFmt.formatDuration(seconds)
        return pomodoros > 0 ? base + " · " + pomodoros + " 个番茄" : base
    }

    // 空状态：居中提示
    Text {
        objectName: "todayLearningEmptyText"
        anchors.centerIn: parent
        width: parent.width - Theme.space24
        visible: root.taskCount === 0
        text: "今天还没有专注记录。\n开始一次专注后，这里会按任务汇总时长。"
        textFormat: Text.PlainText
        color: Theme.inkMuted
        font.pixelSize: Theme.fontMd
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        lineHeight: 1.3
    }

    // 有数据：摘要 + 滚动行列表
    ColumnLayout {
        anchors.fill: parent
        visible: root.taskCount > 0
        spacing: Theme.space12

        Text {
            objectName: "todayLearningSummary"
            Layout.fillWidth: true
            text: "共 " + root.taskCount + " 项 · 今日 " + StatFmt.formatDuration(root.totalDuration)
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
                width: Math.max(parent.width, 1)
                spacing: Theme.space12

                Repeater {
                    model: root.tasks

                    RowLayout {
                        id: taskRow
                        objectName: "todayLearningRow"
                        required property var modelData
                        required property int index

                        Layout.fillWidth: true
                        spacing: Theme.space8

                        Rectangle {
                            Layout.preferredWidth: 11
                            Layout.preferredHeight: 11
                            Layout.alignment: Qt.AlignVCenter
                            radius: 3
                            color: taskRow.modelData.color
                                   ? taskRow.modelData.color
                                   : Theme.chartColors[taskRow.index % Theme.chartColors.length]
                        }

                        Text {
                            Layout.fillWidth: true
                            text: taskRow.modelData.unassigned === true
                                  ? "未关联专注"
                                  : (taskRow.modelData.title || "未命名任务")
                            textFormat: Text.PlainText
                            color: taskRow.modelData.unassigned === true
                                   ? Theme.inkMuted
                                   : Theme.ink
                            font.pixelSize: Theme.fontMd
                            elide: Text.ElideRight
                        }

                        Text {
                            text: root.rowValueText(taskRow.modelData)
                            textFormat: Text.PlainText
                            color: Theme.inkSoft
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.fontFamilyData
                        }
                    }
                }
            }
        }
    }
}
