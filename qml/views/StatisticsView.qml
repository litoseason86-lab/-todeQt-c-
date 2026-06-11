import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import "../components"

Item {
    id: root

    property var todayStats: ({ totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 })
    property string currentTimeRange: "today"
    property var monthStats: ({ totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 })
    property var monthWeeklySummary: []
    property var weekStats: []
    property var categoryStats: ({ categories: [], totalDuration: 0 })
    property var categoryManagerRef: null
    property string loadError: ""
    // 统计页跟今日任务、本周计划保持同一套内容边距，避免每个模块各自偏移导致边界不齐。
    readonly property int contentMargin: 24

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
        // 小于一小时显示分钟/秒；超过一小时后切成小数小时，卡片不会过宽。
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
        // 图表组件以小时为单位绘制柱高，但标签仍显示人类可读时长。
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

    function monthBarData() {
        // 月视图按“周桶”汇总。这里把秒转成小时给柱图计算高度，显示文案仍保留完整时长。
        var result = []
        for (var i = 0; i < root.monthWeeklySummary.length; i++) {
            var weekData = root.monthWeeklySummary[i] || {}
            var duration = Number(weekData.duration || 0)
            result.push({
                label: weekData.label || ("第" + (i + 1) + "周"),
                value: duration / 3600,
                displayValue: root.formatDuration(duration)
            })
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
        // 饼图只关心数值和颜色，服务层返回的秒数在这里格式化成显示文案。
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
            var today = new Date()

            if (root.currentTimeRange === "week") {
                root.weekStats = statisticsService.getWeekStats()
                var weekStart = root.mondayOf(today)
                var weekEnd = root.endOfWeek(weekStart)
                var weekTotal = root.weekTotalDuration()

                // 多范围卡片复用 todayStats 这个绑定入口，避免 UI 层维护三套重复卡片状态。
                root.todayStats = {
                    effectiveDays: statisticsService.getEffectiveDays(weekStart, weekEnd),
                    sessionCount: statisticsService.getFocusSessionCount(weekStart, weekEnd),
                    totalDuration: weekTotal,
                    completedTasks: 0,
                    totalTasks: 0,
                    completionRate: 0
                }
                root.categoryStats = statisticsService.getCategoryStats(
                            Qt.formatDate(weekStart, "yyyy-MM-dd"),
                            Qt.formatDate(weekEnd, "yyyy-MM-dd"))
            } else if (root.currentTimeRange === "month") {
                root.monthStats = statisticsService.getMonthStats()
                root.monthWeeklySummary = statisticsService.getMonthWeeklySummary()
                root.todayStats = {
                    effectiveDays: root.monthStats.effectiveDays || 0,
                    sessionCount: root.monthStats.sessionCount || 0,
                    totalDuration: root.monthStats.totalDuration || 0,
                    completedTasks: root.monthStats.completedTasks || 0,
                    totalTasks: root.monthStats.totalTasks || 0,
                    completionRate: 0
                }

                var firstDay = new Date(today.getFullYear(), today.getMonth(), 1)
                var lastDay = new Date(today.getFullYear(), today.getMonth() + 1, 0)
                root.categoryStats = statisticsService.getCategoryStats(
                            Qt.formatDate(firstDay, "yyyy-MM-dd"),
                            Qt.formatDate(lastDay, "yyyy-MM-dd"))
            } else {
                root.currentTimeRange = "today"
                var todayStats = statisticsService.getTodayStats()
                todayStats.sessionCount = statisticsService.getFocusSessionCount(today, today)
                root.todayStats = todayStats
                root.weekStats = statisticsService.getWeekStats()
                root.categoryStats = statisticsService.getCategoryStats(
                            Qt.formatDate(today, "yyyy-MM-dd"),
                            Qt.formatDate(today, "yyyy-MM-dd"))
            }
        } catch (error) {
            root.loadError = "统计数据加载失败"
            root.todayStats = { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0, sessionCount: 0 }
            root.weekStats = []
            root.monthStats = { totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 }
            root.monthWeeklySummary = []
            root.categoryStats = { categories: [], totalDuration: 0 }
        }
    }

    ScrollView {
        id: statisticsScrollView

        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            x: root.contentMargin
            width: Math.max(statisticsScrollView.availableWidth - root.contentMargin * 2, 1)
            spacing: 16

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 8
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 16

                ColumnLayout {
                    Layout.fillWidth: true
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
                    id: timeRangeSelectorButton
                    objectName: "statisticsTimeRangeSelector"

                    Layout.preferredWidth: 118
                    Layout.preferredHeight: 36
                    radius: 6
                    color: timeRangeSelectorMouseArea.containsMouse ? "#f0e6d2" : "#faf6ee"
                    border.width: 1
                    border.color: timeRangeMenu.opened ? "#d4a574" : "#e8dfc8"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: {
                                if (root.currentTimeRange === "week") {
                                    return "📅 本周"
                                }
                                if (root.currentTimeRange === "month") {
                                    return "📅 本月"
                                }
                                return "📅 今日"
                            }
                            font.pixelSize: 14
                            font.weight: Font.Medium
                            color: "#5d4e37"
                            elide: Text.ElideRight
                        }

                        Text {
                            text: "▼"
                            font.pixelSize: 10
                            color: "#8b7355"
                        }
                    }

                    MouseArea {
                        id: timeRangeSelectorMouseArea
                        objectName: "statisticsTimeRangeSelectorArea"

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: timeRangeMenu.open()
                    }

                    Menu {
                        id: timeRangeMenu
                        objectName: "statisticsTimeRangeMenu"
                        popupType: Popup.Item

                        x: timeRangeSelectorButton.width - width
                        y: timeRangeSelectorButton.height + 4
                        width: 124

                        background: Rectangle {
                            implicitWidth: 124
                            color: "#faf8f3"
                            border.width: 1
                            border.color: "#d4a574"
                            radius: 8
                            layer.enabled: true
                            layer.effect: MultiEffect {
                                autoPaddingEnabled: true
                                shadowEnabled: true
                                shadowColor: "#5d4e37"
                                shadowOpacity: 0.15
                                shadowBlur: 0.18
                                shadowHorizontalOffset: 0
                                shadowVerticalOffset: 4
                            }
                        }

                        MenuItem {
                            objectName: "statisticsTimeRangeTodayItem"
                            height: 40

                            background: Rectangle {
                                color: parent.hovered ? "#f0e6d2" : "transparent"
                                radius: 6
                            }

                            contentItem: Text {
                                text: "📅 今日"
                                font.pixelSize: 14
                                color: "#5d4e37"
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: 10
                                rightPadding: 10
                            }

                            onTriggered: {
                                root.currentTimeRange = "today"
                                root.refresh()
                            }
                        }

                        MenuItem {
                            objectName: "statisticsTimeRangeWeekItem"
                            height: 40

                            background: Rectangle {
                                color: parent.hovered ? "#f0e6d2" : "transparent"
                                radius: 6
                            }

                            contentItem: Text {
                                text: "📅 本周"
                                font.pixelSize: 14
                                color: "#5d4e37"
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: 10
                                rightPadding: 10
                            }

                            onTriggered: {
                                root.currentTimeRange = "week"
                                root.refresh()
                            }
                        }

                        MenuItem {
                            objectName: "statisticsTimeRangeMonthItem"
                            height: 40

                            background: Rectangle {
                                color: parent.hovered ? "#f0e6d2" : "transparent"
                                radius: 6
                            }

                            contentItem: Text {
                                text: "📅 本月"
                                font.pixelSize: 14
                                color: "#5d4e37"
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: 10
                                rightPadding: 10
                            }

                            onTriggered: {
                                root.currentTimeRange = "month"
                                root.refresh()
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: "#e8dfc8"
            }

            Label {
                Layout.fillWidth: true
                visible: root.loadError.length > 0
                text: root.loadError
                color: "#b24f3d"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            GridLayout {
                Layout.fillWidth: true
                columns: statisticsScrollView.availableWidth >= 720 ? 3 : 1
                columnSpacing: 16
                rowSpacing: 16

                StatCard {
                    id: todayFocusCard
                    objectName: "statisticsPrimaryStatCard"

                    Layout.fillWidth: true
                    animationDelay: 0
                    title: root.currentTimeRange === "today" ? "任务完成" : "有效天数"
                    value: {
                        if (root.currentTimeRange === "today") {
                            return Number(root.todayStats.completedTasks || 0) + " / " + Number(root.todayStats.totalTasks || 0)
                        }
                        return Number(root.todayStats.effectiveDays || 0) + "天"
                    }
                    subtitle: {
                        if (root.currentTimeRange === "today") {
                            return "完成率 " + Math.round(Number(root.todayStats.completionRate || 0) * 100) + "%"
                        }
                        if (root.currentTimeRange === "week") {
                            return "本周有记录天数"
                        }
                        return "本月有记录天数"
                    }
                }

                StatCard {
                    id: taskCompletionCard
                    objectName: "statisticsSessionCountStatCard"

                    Layout.fillWidth: true
                    animationDelay: 70
                    title: "专注次数"
                    value: Number(root.todayStats.sessionCount || 0) + "次"
                    subtitle: {
                        if (root.currentTimeRange === "today") {
                            return "今日完成次数"
                        }
                        if (root.currentTimeRange === "week") {
                            return "本周完成次数"
                        }
                        return "本月完成次数"
                    }
                }

                StatCard {
                    id: weekTotalCard
                    objectName: "statisticsTotalDurationStatCard"

                    Layout.fillWidth: true
                    animationDelay: 140
                    title: {
                        if (root.currentTimeRange === "today") {
                            return "今日专注"
                        }
                        if (root.currentTimeRange === "week") {
                            return "本周累计"
                        }
                        return "本月累计"
                    }
                    value: root.totalDurationValue(root.todayStats.totalDuration || 0)
                    unit: root.totalDurationUnit(root.todayStats.totalDuration || 0)
                    subtitle: {
                        if (root.currentTimeRange === "today") {
                            return "当前自然日"
                        }
                        if (root.currentTimeRange === "week") {
                            return "本周专注时长"
                        }
                        return "本月专注时长"
                    }
                }

            }

            ChartBar {
                objectName: "statisticsTrendChart"

                Layout.fillWidth: true
                title: root.currentTimeRange === "month" ? "本月专注趋势" : "本周专注趋势"
                dataPoints: root.currentTimeRange === "month" ? root.monthBarData() : root.barData()
                valueSuffix: "h"
                emptyText: root.currentTimeRange === "month" ? "本月还没有专注记录" : "本周还没有专注记录"
            }

            ChartPie {
                objectName: "statisticsCategoryChart"

                Layout.fillWidth: true
                Layout.bottomMargin: 24
                title: "科目时间分配"
                dataPoints: root.pieData()
                emptyText: {
                    if (root.currentTimeRange === "today") {
                        return "今日还没有可归类的专注记录"
                    }
                    if (root.currentTimeRange === "week") {
                        return "本周还没有可归类的专注记录"
                    }
                    return "本月还没有可归类的专注记录"
                }
            }
        }
    }
}
