import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

Item {
    id: root

    property var todayStats: ({ totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 })
    property var weekStats: []
    property var categoryStats: ({ categories: [], totalDuration: 0 })
    property var categoryManagerRef: null
    property string loadError: ""

    Component.onCompleted: refresh()

    onVisibleChanged: {
        if (visible) {
            todayFocusCard.restartIntro()
            taskCompletionCard.restartIntro()
            weekTotalCard.restartIntro()
        }
    }

    Connections {
        target: taskManager

        function onTasksChanged() {
            root.refresh()
        }
    }

    Connections {
        target: focusTimer

        function onFocusCompleted(duration) {
            root.refresh()
        }
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true

        function onCategoriesChanged() {
            root.refresh()
        }
    }

    function formatDuration(seconds) {
        var safe = Math.max(0, Math.floor(Number(seconds || 0)))
        if (safe > 0 && safe < 60) {
            return safe + "秒"
        }
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        if (hours > 0) {
            return hours + "小时" + minutes + "分钟"
        }
        return minutes + "分钟"
    }

    function decimalHours(seconds) {
        return (Math.max(0, Number(seconds || 0)) / 3600).toFixed(1)
    }

    function totalDurationValue(seconds) {
        var safe = Math.max(0, Math.floor(Number(seconds || 0)))
        if (safe < 3600) {
            return root.formatDuration(safe)
        }
        return root.decimalHours(safe)
    }

    function totalDurationUnit(seconds) {
        var safe = Math.max(0, Math.floor(Number(seconds || 0)))
        return safe >= 3600 ? "小时" : ""
    }

    function mondayOf(value) {
        var date = new Date(value)
        var day = date.getDay()
        var diff = day === 0 ? -6 : 1 - day
        date.setDate(date.getDate() + diff)
        date.setHours(0, 0, 0, 0)
        return date
    }

    function endOfWeek(start) {
        var date = new Date(start)
        date.setDate(date.getDate() + 6)
        return date
    }

    function weekTotalDuration() {
        var total = 0
        for (var i = 0; i < root.weekStats.length; i++) {
            total += Number(root.weekStats[i].duration || 0)
        }
        return total
    }

    function barData() {
        var result = []
        for (var i = 0; i < root.weekStats.length; i++) {
            var duration = Number(root.weekStats[i].duration || 0)
            result.push({
                label: "",
                value: duration / 3600,
                displayValue: root.formatDuration(duration)
            })
            result[i].label = root.weekdayLabel(root.weekStats[i].date, i)
        }
        return result
    }

    function weekdayLabel(dateValue, indexValue) {
        var fallback = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        var date = dateValue instanceof Date ? dateValue : new Date(dateValue)
        if (isNaN(date.getTime())) {
            return fallback[indexValue % fallback.length]
        }
        var labels = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return labels[date.getDay()]
    }

    function pieData() {
        var categories = root.categoryStats.categories || []
        var result = []
        for (var i = 0; i < categories.length; i++) {
            var item = categories[i]
            result.push({
                label: item.name || "未分类",
                value: Number(item.duration || 0),
                displayValue: root.formatDuration(item.duration),
                color: item.color || ""
            })
        }
        return result
    }

    function refresh() {
        try {
            root.loadError = ""
            root.todayStats = statisticsService.getTodayStats()
            root.weekStats = statisticsService.getWeekStats()
            var start = root.mondayOf(new Date())
            root.categoryStats = statisticsService.getCategoryStats(
                        Qt.formatDate(start, "yyyy-MM-dd"),
                        Qt.formatDate(root.endOfWeek(start), "yyyy-MM-dd"))
        } catch (error) {
            root.loadError = "统计数据加载失败"
            root.todayStats = { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 }
            root.weekStats = []
            root.categoryStats = { categories: [], totalDuration: 0 }
        }
    }

    ScrollView {
        anchors.fill: parent
        clip: true

        ColumnLayout {
            width: Math.max(parent.width, 1)
            spacing: 16

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 8
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                spacing: 4

                Text {
                    text: "数据统计"
                    font.pixelSize: 24
                    font.bold: true
                    color: "#5d4e37"
                }

                Text {
                    text: "看清时间流向，比靠感觉复盘可靠。"
                    font.pixelSize: 13
                    color: "#8b7355"
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Layout.preferredHeight: 1
                color: "#e8dfc8"
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                visible: root.loadError.length > 0
                text: root.loadError
                color: "#b24f3d"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                spacing: 12

                StatCard {
                    id: todayFocusCard
                    Layout.fillWidth: true
                    animationDelay: 0
                    title: "今日专注"
                    value: root.formatDuration(root.todayStats.totalDuration)
                    subtitle: "当前自然日"
                }

                StatCard {
                    id: taskCompletionCard
                    Layout.fillWidth: true
                    animationDelay: 70
                    title: "任务完成"
                    value: Number(root.todayStats.completedTasks || 0) + " / " + Number(root.todayStats.totalTasks || 0)
                    subtitle: "完成率 " + Math.round(Number(root.todayStats.completionRate || 0) * 100) + "%"
                }

                StatCard {
                    id: weekTotalCard
                    Layout.fillWidth: true
                    animationDelay: 140
                    title: "本周累计"
                    value: root.totalDurationValue(root.weekTotalDuration())
                    unit: root.totalDurationUnit(root.weekTotalDuration())
                    subtitle: "本周专注时长"
                }
            }

            ChartBar {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                title: "本周专注趋势"
                dataPoints: root.barData()
                valueSuffix: "h"
                emptyText: "本周还没有专注记录"
            }

            ChartPie {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Layout.bottomMargin: 24
                title: "科目时间分配"
                dataPoints: root.pieData()
                emptyText: "本周还没有可归类的专注记录"
            }
        }
    }
}
