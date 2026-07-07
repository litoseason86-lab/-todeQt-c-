import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../components"
import "StatisticsFormat.js" as StatFmt

Item {
    id: root

    property var todayStats: ({ totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 })
    property string currentTimeRange: "today"
    property var todayComparison: ({})
    property var weekComparison: ({})
    property var monthComparison: ({})
    property var currentDateProvider: null
    property date currentDateSnapshot: new Date()
    // 三种时间范围各自保留选中状态，切换模式时再重置，避免日/周/月导航互相污染。
    property date selectedDate: currentDateSnapshot
    property date selectedWeekStart: StatFmt.mondayOf(currentDateSnapshot)
    property int selectedYear: currentDateSnapshot.getFullYear()
    property int selectedMonth: currentDateSnapshot.getMonth() + 1
    readonly property bool isCurrentSelectedPeriod: !canGoForward
    readonly property bool canGoForward: {
        if (currentTimeRange === "today") {
            var today = new Date(currentDateSnapshot)
            today.setHours(0, 0, 0, 0)
            var selected = new Date(selectedDate)
            selected.setHours(0, 0, 0, 0)
            return selected.getTime() < today.getTime()
        }
        if (currentTimeRange === "week") {
            var currentMonday = StatFmt.mondayOf(currentDateSnapshot)
            return selectedWeekStart.getTime() < currentMonday.getTime()
        }

        var now = new Date(currentDateSnapshot)
        return selectedYear < now.getFullYear()
                || (selectedYear === now.getFullYear() && selectedMonth < now.getMonth() + 1)
    }
    readonly property string timeRangeDisplayText: {
        if (currentTimeRange === "today") {
            var today = new Date(currentDateSnapshot)
            today.setHours(0, 0, 0, 0)
            var selected = new Date(selectedDate)
            selected.setHours(0, 0, 0, 0)
            if (selected.getTime() === today.getTime()) {
                return "今天"
            }
            return (selectedDate.getMonth() + 1) + "月" + selectedDate.getDate() + "日"
        }
        if (currentTimeRange === "week") {
            var currentMonday = StatFmt.mondayOf(currentDateSnapshot)
            if (selectedWeekStart.getTime() === currentMonday.getTime()) {
                return "本周"
            }
            var weekEnd = new Date(selectedWeekStart)
            weekEnd.setDate(weekEnd.getDate() + 6)
            return StatFmt.formatWeekRange(selectedWeekStart, weekEnd)
        }

        var current = new Date(currentDateSnapshot)
        if (selectedYear === current.getFullYear() && selectedMonth === current.getMonth() + 1) {
            return "本月"
        }
        return selectedYear + "年" + selectedMonth + "月"
    }
    property var monthStats: ({ totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 })
    property var monthWeeklySummary: []
    property var weekStats: []
    property var categoryStats: ({ categories: [], totalDuration: 0 })
    property var categoryManagerRef: null
    property string loadError: ""
    // 统计页跟今日任务、本周计划保持同一套内容边距，避免每个模块各自偏移导致边界不齐。
    readonly property int contentMargin: 24

    onCurrentTimeRangeChanged: {
        // 模式切换代表用户回到该模式的当前周期；箭头导航只改变对应模式自己的选中状态。
        if (currentTimeRange === "today") {
            selectedDate = new Date(currentDateSnapshot)
        } else if (currentTimeRange === "week") {
            selectedWeekStart = StatFmt.mondayOf(currentDateSnapshot)
        } else if (currentTimeRange === "month") {
            var now = new Date(currentDateSnapshot)
            selectedYear = now.getFullYear()
            selectedMonth = now.getMonth() + 1
        }
        refresh()
    }

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

    function refreshCurrentDateSnapshot() {
        var providedDate = root.currentDateProvider ? root.currentDateProvider() : new Date()
        var normalizedDate = new Date(providedDate)
        currentDateSnapshot = isNaN(normalizedDate.getTime()) ? new Date() : normalizedDate
    }

    function applyCurrentPeriodSelection() {
        if (root.currentTimeRange === "today") {
            root.selectedDate = new Date(root.currentDateSnapshot)
        } else if (root.currentTimeRange === "week") {
            root.selectedWeekStart = StatFmt.mondayOf(root.currentDateSnapshot)
        } else if (root.currentTimeRange === "month") {
            root.selectedYear = root.currentDateSnapshot.getFullYear()
            root.selectedMonth = root.currentDateSnapshot.getMonth() + 1
        }
    }

    function resetSelectedPeriodToCurrent() {
        // 菜单项名称是“今日 / 本周 / 本月”，即使用户已经在同一模式的历史期，也必须回到当前期。
        refreshCurrentDateSnapshot()
        applyCurrentPeriodSelection()
    }

    function syncCurrentDateSnapshotForRefresh() {
        // 应用长期打开跨午夜时，如果用户停在“当前期”，刷新应滚到新的今天/本周/本月；
        // 如果用户主动查看历史期，则保留历史选择，只更新右箭头边界。
        var shouldFollowCurrentPeriod = root.isCurrentSelectedPeriod
        refreshCurrentDateSnapshot()
        if (shouldFollowCurrentPeriod) {
            applyCurrentPeriodSelection()
        }
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
                displayValue: StatFmt.formatDuration(duration)
            })
            result[i].label = StatFmt.weekdayLabel(root.weekStats[i].date, i)
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
                displayValue: StatFmt.formatDuration(duration)
            })
        }
        return result
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
                displayValue: StatFmt.formatDuration(item.duration),
                color: item.color || ""
            })
        }
        return result
    }

    function comparisonVisible(comparison) {
        return Boolean(comparison && comparison.hasData && root.comparisonDisplayText(comparison).length > 0)
    }

    function comparisonDisplayText(comparison) {
        var text = comparison && comparison.displayText ? String(comparison.displayText) : ""
        if (text.length === 0) {
            return text
        }
        return root.withSelectedPeriodComparisonLabel(text)
    }

    function withSelectedPeriodComparisonLabel(text) {
        if (root.currentTimeRange === "today") {
            return text.replace("昨天", root.dayComparisonLabel())
        }
        if (root.currentTimeRange === "week") {
            return text.replace("上周", root.weekComparisonLabel())
        }
        if (root.currentTimeRange === "month") {
            return text.replace("上月", root.monthComparisonLabel())
        }
        return text
    }

    function dayComparisonLabel() {
        var today = StatFmt.dayStart(root.currentDateSnapshot)
        var comparedDay = StatFmt.dayStart(root.selectedDate)
        comparedDay.setDate(comparedDay.getDate() - 1)

        // 标签描述的是“被比较的前一日”相对今天的位置，历史期不能简单写死为昨天。
        var daysAgo = Math.round((today.getTime() - comparedDay.getTime()) / 86400000)
        if (daysAgo <= 1) {
            return "昨天"
        }
        if (daysAgo === 2) {
            return "前天"
        }
        return daysAgo + "天前"
    }

    function weekComparisonLabel() {
        var currentMonday = StatFmt.mondayOf(root.currentDateSnapshot)
        var comparedWeekStart = new Date(root.selectedWeekStart)
        comparedWeekStart.setDate(comparedWeekStart.getDate() - 7)
        comparedWeekStart.setHours(0, 0, 0, 0)

        // 周视图的比较对象是所选周的前一周；退多周时要显示真实距离。
        var weeksAgo = Math.round((currentMonday.getTime() - comparedWeekStart.getTime()) / (7 * 86400000))
        if (weeksAgo <= 1) {
            return "上周"
        }
        if (weeksAgo === 2) {
            return "上上周"
        }
        return weeksAgo + "周前"
    }

    function monthComparisonLabel() {
        var current = new Date(root.currentDateSnapshot)
        var comparedYear = root.selectedYear
        var comparedMonth = root.selectedMonth - 1
        if (comparedMonth < 1) {
            comparedMonth = 12
            comparedYear -= 1
        }

        // 月份用 year*12+month 计算距离，避免跨年时 “1月 vs 上月” 算错。
        var currentIndex = current.getFullYear() * 12 + current.getMonth() + 1
        var comparedIndex = comparedYear * 12 + comparedMonth
        var monthsAgo = currentIndex - comparedIndex
        if (monthsAgo <= 1) {
            return "上月"
        }
        if (monthsAgo === 2) {
            return "上上月"
        }
        return monthsAgo + "个月前"
    }

    function currentComparisonGroup() {
        // 同一时间范围内的同比结果按指标拆开存放，卡片只取自己对应的那一项。
        if (root.currentTimeRange === "week") {
            return root.weekComparison || {}
        }
        if (root.currentTimeRange === "month") {
            return root.monthComparison || {}
        }
        return root.todayComparison || {}
    }

    function comparisonForMetric(metricName) {
        var comparisonGroup = root.currentComparisonGroup()
        if (!comparisonGroup) {
            return {}
        }
        return comparisonGroup[metricName] || {}
    }

    function primaryCardComparison() {
        // 今日卡片主值是“完成数 / 总数”，因此这里比较完成任务数量；周/月卡片比较有效天数。
        if (root.currentTimeRange === "today") {
            return root.comparisonForMetric("taskCompletion")
        }
        return root.comparisonForMetric("effectiveDays")
    }

    function sessionCountComparison() {
        return root.comparisonForMetric("sessionCount")
    }

    function durationComparison() {
        return root.comparisonForMetric("duration")
    }

    function refresh() {
        try {
            root.loadError = ""
            root.syncCurrentDateSnapshotForRefresh()

            if (root.currentTimeRange === "today") {
                var selectedDay = new Date(root.selectedDate)
                root.todayStats = statisticsService.getDayStats(selectedDay)
                root.todayComparison = statisticsService.getDayComparison(selectedDay)
                root.weekStats = statisticsService.getWeekStats(StatFmt.mondayOf(selectedDay))
                root.categoryStats = statisticsService.getCategoryStats(
                            Qt.formatDate(selectedDay, "yyyy-MM-dd"),
                            Qt.formatDate(selectedDay, "yyyy-MM-dd"))
            } else if (root.currentTimeRange === "week") {
                var weekStart = new Date(root.selectedWeekStart)
                var weekEnd = StatFmt.endOfWeek(weekStart)
                root.weekStats = statisticsService.getWeekStats(weekStart)
                root.weekComparison = statisticsService.getWeekComparison(weekStart)
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
                root.monthStats = statisticsService.getMonthStats(root.selectedYear, root.selectedMonth)
                root.monthComparison = statisticsService.getMonthComparison(root.selectedYear, root.selectedMonth)
                root.monthWeeklySummary = statisticsService.getMonthWeeklySummary(root.selectedYear, root.selectedMonth)
                root.todayStats = {
                    effectiveDays: root.monthStats.effectiveDays || 0,
                    sessionCount: root.monthStats.sessionCount || 0,
                    totalDuration: root.monthStats.totalDuration || 0,
                    completedTasks: root.monthStats.completedTasks || 0,
                    totalTasks: root.monthStats.totalTasks || 0,
                    completionRate: 0
                }

                var firstDay = new Date(root.selectedYear, root.selectedMonth - 1, 1)
                var lastDay = new Date(root.selectedYear, root.selectedMonth, 0)
                root.categoryStats = statisticsService.getCategoryStats(
                            Qt.formatDate(firstDay, "yyyy-MM-dd"),
                            Qt.formatDate(lastDay, "yyyy-MM-dd"))
            } else {
                root.currentTimeRange = "today"
            }
        } catch (error) {
            root.loadError = "统计数据加载失败"
            root.todayStats = { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0, sessionCount: 0 }
            root.weekStats = []
            root.monthStats = { totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 }
            root.todayComparison = {}
            root.weekComparison = {}
            root.monthComparison = {}
            root.monthWeeklySummary = []
            root.categoryStats = { categories: [], totalDuration: 0 }
        }
    }

    function goToPreviousPeriod() {
        if (root.currentTimeRange === "today") {
            var previousDay = new Date(root.selectedDate)
            previousDay.setDate(previousDay.getDate() - 1)
            root.selectedDate = previousDay
        } else if (root.currentTimeRange === "week") {
            var previousWeek = new Date(root.selectedWeekStart)
            previousWeek.setDate(previousWeek.getDate() - 7)
            root.selectedWeekStart = previousWeek
        } else {
            root.selectedMonth -= 1
            if (root.selectedMonth < 1) {
                root.selectedMonth = 12
                root.selectedYear -= 1
            }
        }

        root.refresh()
    }

    function goToNextPeriod() {
        if (!root.canGoForward) {
            return
        }

        if (root.currentTimeRange === "today") {
            var nextDay = new Date(root.selectedDate)
            nextDay.setDate(nextDay.getDate() + 1)
            root.selectedDate = nextDay
        } else if (root.currentTimeRange === "week") {
            var nextWeek = new Date(root.selectedWeekStart)
            nextWeek.setDate(nextWeek.getDate() + 7)
            root.selectedWeekStart = nextWeek
        } else {
            root.selectedMonth += 1
            if (root.selectedMonth > 12) {
                root.selectedMonth = 1
                root.selectedYear += 1
            }
        }

        root.refresh()
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
            spacing: Theme.space16

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 8
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space16

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space4

                    Text {
                        text: "数据统计"
                        font.pixelSize: Theme.fontXxl
                        font.bold: true
                        color: Theme.ink
                    }

                    Text {
                        text: "看清时间流向，比靠感觉复盘可靠。"
                        font.pixelSize: Theme.fontMd
                        color: Theme.inkSoft
                    }
                }

                RowLayout {
                    spacing: Theme.space8

                    Rectangle {
                        id: previousPeriodButton
                        objectName: "statisticsPreviousPeriodButton"

                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        radius: Theme.radiusMd
                        color: previousPeriodMouseArea.containsMouse ? Theme.accentSoft : Theme.surfaceRaised
                        border.width: 1
                        border.color: Theme.border

                        Text {
                            anchors.centerIn: parent
                            text: "←"
                            font.pixelSize: Theme.fontXl
                            color: Theme.ink
                        }

                        MouseArea {
                            id: previousPeriodMouseArea
                            objectName: "statisticsPreviousPeriodArea"

                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.goToPreviousPeriod()
                        }
                    }

                    Rectangle {
                        id: timeRangeSelectorButton
                        objectName: "statisticsTimeRangeSelector"

                        Layout.preferredWidth: 140
                        Layout.preferredHeight: 36
                        radius: Theme.radiusMd
                        color: timeRangeSelectorMouseArea.containsMouse ? Theme.accentSoft : Theme.surfaceRaised
                        border.width: 1
                        border.color: timeRangeMenu.opened ? Theme.accent : Theme.border

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.space12
                            anchors.rightMargin: Theme.space12
                            spacing: Theme.space8

                            Text {
                                id: timeRangeSelectorText
                                objectName: "statisticsTimeRangeSelectorText"

                                Layout.fillWidth: true
                                text: root.timeRangeDisplayText
                                font.pixelSize: Theme.fontLg
                                font.weight: Font.Medium
                                color: Theme.ink
                                elide: Text.ElideRight
                            }

                            Text {
                                text: "▼"
                                font.pixelSize: Theme.fontXs
                                color: Theme.inkSoft
                            }
                        }

                        MouseArea {
                            id: timeRangeSelectorMouseArea
                            objectName: "statisticsTimeRangeSelectorArea"

                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
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
                                color: Theme.surfaceRaised
                                border.width: 1
                                border.color: Theme.accent
                                radius: Theme.radiusLg
                                layer.enabled: true
                                layer.effect: MultiEffect {
                                    autoPaddingEnabled: true
                                    shadowEnabled: true
                                    shadowColor: Theme.ink
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
                                    color: parent.hovered ? Theme.accentSoft : "transparent"
                                    radius: Theme.radiusMd
                                }

                                contentItem: Text {
                                    text: "📅 今日"
                                    font.pixelSize: Theme.fontLg
                                    color: Theme.ink
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: Theme.space12
                                    rightPadding: Theme.space12
                                }

                                onTriggered: {
                                    if (root.currentTimeRange !== "today") {
                                        root.currentTimeRange = "today"
                                    } else {
                                        root.resetSelectedPeriodToCurrent()
                                        root.refresh()
                                    }
                                }
                            }

                            MenuItem {
                                objectName: "statisticsTimeRangeWeekItem"
                                height: 40

                                background: Rectangle {
                                    color: parent.hovered ? Theme.accentSoft : "transparent"
                                    radius: Theme.radiusMd
                                }

                                contentItem: Text {
                                    text: "📅 本周"
                                    font.pixelSize: Theme.fontLg
                                    color: Theme.ink
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: Theme.space12
                                    rightPadding: Theme.space12
                                }

                                onTriggered: {
                                    if (root.currentTimeRange !== "week") {
                                        root.currentTimeRange = "week"
                                    } else {
                                        root.resetSelectedPeriodToCurrent()
                                        root.refresh()
                                    }
                                }
                            }

                            MenuItem {
                                objectName: "statisticsTimeRangeMonthItem"
                                height: 40

                                background: Rectangle {
                                    color: parent.hovered ? Theme.accentSoft : "transparent"
                                    radius: Theme.radiusMd
                                }

                                contentItem: Text {
                                    text: "📅 本月"
                                    font.pixelSize: Theme.fontLg
                                    color: Theme.ink
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: Theme.space12
                                    rightPadding: Theme.space12
                                }

                                onTriggered: {
                                    if (root.currentTimeRange !== "month") {
                                        root.currentTimeRange = "month"
                                    } else {
                                        root.resetSelectedPeriodToCurrent()
                                        root.refresh()
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        id: nextPeriodButton
                        objectName: "statisticsNextPeriodButton"

                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        radius: Theme.radiusMd
                        color: root.canGoForward
                               ? (nextPeriodMouseArea.containsMouse ? Theme.accentSoft : Theme.surfaceRaised)
                               : Theme.border
                        border.width: 1
                        border.color: root.canGoForward ? Theme.border : Theme.inkMuted
                        opacity: root.canGoForward ? 1.0 : 0.55

                        Text {
                            anchors.centerIn: parent
                            text: "→"
                            font.pixelSize: Theme.fontXl
                            color: root.canGoForward ? Theme.ink : Theme.inkMuted
                        }

                        MouseArea {
                            id: nextPeriodMouseArea
                            objectName: "statisticsNextPeriodArea"

                            anchors.fill: parent
                            enabled: root.canGoForward
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: root.canGoForward ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                            onClicked: root.goToNextPeriod()
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.border
            }

            Label {
                Layout.fillWidth: true
                visible: root.loadError.length > 0
                text: root.loadError
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }

            GridLayout {
                Layout.fillWidth: true
                columns: statisticsScrollView.availableWidth >= 720 ? 3 : 1
                columnSpacing: Theme.space16
                rowSpacing: Theme.space16

                StatCard {
                    id: todayFocusCard
                    objectName: "statisticsPrimaryStatCard"

                    Layout.fillWidth: true
                    animationDelay: 0
                    showComparison: root.comparisonVisible(root.primaryCardComparison())
                    comparisonText: root.comparisonDisplayText(root.primaryCardComparison())
                    comparisonTrend: Number(root.primaryCardComparison().trend || 0)
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
                            return root.isCurrentSelectedPeriod ? "本周有记录天数" : "所选周有记录天数"
                        }
                        return root.isCurrentSelectedPeriod ? "本月有记录天数" : "所选月有记录天数"
                    }
                }

                StatCard {
                    id: taskCompletionCard
                    objectName: "statisticsSessionCountStatCard"

                    Layout.fillWidth: true
                    animationDelay: 70
                    showComparison: root.comparisonVisible(root.sessionCountComparison())
                    comparisonText: root.comparisonDisplayText(root.sessionCountComparison())
                    comparisonTrend: Number(root.sessionCountComparison().trend || 0)
                    title: "专注次数"
                    value: Number(root.todayStats.sessionCount || 0) + "次"
                    subtitle: {
                        if (root.currentTimeRange === "today") {
                            return root.isCurrentSelectedPeriod ? "今日完成次数" : "当日完成次数"
                        }
                        if (root.currentTimeRange === "week") {
                            return root.isCurrentSelectedPeriod ? "本周完成次数" : "所选周完成次数"
                        }
                        return root.isCurrentSelectedPeriod ? "本月完成次数" : "所选月完成次数"
                    }
                }

                StatCard {
                    id: weekTotalCard
                    objectName: "statisticsTotalDurationStatCard"

                    Layout.fillWidth: true
                    animationDelay: 140
                    showComparison: root.comparisonVisible(root.durationComparison())
                    comparisonText: root.comparisonDisplayText(root.durationComparison())
                    comparisonTrend: Number(root.durationComparison().trend || 0)
                    title: {
                        if (root.currentTimeRange === "today") {
                            return root.isCurrentSelectedPeriod ? "今日专注" : "当日专注"
                        }
                        if (root.currentTimeRange === "week") {
                            return root.isCurrentSelectedPeriod ? "本周累计" : "所选周累计"
                        }
                        return root.isCurrentSelectedPeriod ? "本月累计" : "所选月累计"
                    }
                    value: StatFmt.totalDurationValue(root.todayStats.totalDuration || 0)
                    unit: StatFmt.totalDurationUnit(root.todayStats.totalDuration || 0)
                    subtitle: {
                        if (root.currentTimeRange === "today") {
                            return root.isCurrentSelectedPeriod ? "当前自然日" : "所选自然日"
                        }
                        if (root.currentTimeRange === "week") {
                            return root.isCurrentSelectedPeriod ? "本周专注时长" : "所选周专注时长"
                        }
                        return root.isCurrentSelectedPeriod ? "本月专注时长" : "所选月专注时长"
                    }
                }

            }

            ChartBar {
                objectName: "statisticsTrendChart"

                Layout.fillWidth: true
                title: {
                    if (root.currentTimeRange === "month") {
                        return root.isCurrentSelectedPeriod ? "本月专注趋势" : "所选月专注趋势"
                    }
                    if (root.currentTimeRange === "week") {
                        return root.isCurrentSelectedPeriod ? "本周专注趋势" : "所选周专注趋势"
                    }
                    return root.isCurrentSelectedPeriod ? "本周专注趋势" : "所在周专注趋势"
                }
                dataPoints: root.currentTimeRange === "month" ? root.monthBarData() : root.barData()
                valueSuffix: "h"
                emptyText: {
                    if (root.currentTimeRange === "month") {
                        return root.isCurrentSelectedPeriod ? "本月还没有专注记录" : "所选月还没有专注记录"
                    }
                    if (root.currentTimeRange === "week") {
                        return root.isCurrentSelectedPeriod ? "本周还没有专注记录" : "所选周还没有专注记录"
                    }
                    return root.isCurrentSelectedPeriod ? "本周还没有专注记录" : "所在周还没有专注记录"
                }
            }

            ChartPie {
                objectName: "statisticsCategoryChart"

                Layout.fillWidth: true
                Layout.bottomMargin: Theme.space24
                title: "科目时间分配"
                dataPoints: root.pieData()
                emptyText: {
                    if (root.currentTimeRange === "today") {
                        return root.isCurrentSelectedPeriod ? "今日还没有可归类的专注记录" : "当日还没有可归类的专注记录"
                    }
                    if (root.currentTimeRange === "week") {
                        return root.isCurrentSelectedPeriod ? "本周还没有可归类的专注记录" : "所选周还没有可归类的专注记录"
                    }
                    return root.isCurrentSelectedPeriod ? "本月还没有可归类的专注记录" : "所选月还没有可归类的专注记录"
                }
            }
        }
    }
}
