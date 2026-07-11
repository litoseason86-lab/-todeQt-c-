import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import ".."
import "../LogicalDay.js" as LogicalDay
import "DashboardFormat.js" as DashboardFormat

// 仪表盘：问候头部 + 倒计时英雄横幅 + 四张统计卡 + 今日任务面板 + 专注计时面板。
// 内容区保持清晰的半透明色块，毛玻璃只出现在右侧专注面板（重要控制组件）。
Item {
    id: root

    signal startFocus(int taskId, string taskTitle)
    signal countdownRequested()
    signal deleteRequested(int taskId, string title)
    signal focusPageRequested()

    property var categoryManagerRef: null
    property var countdownServiceRef: null
    property var settingsRef: null
    property var wallpaperRef: null
    property int pendingDeleteTaskId: -1

    property var tasks: []
    property var todayStats: ({ totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0, sessionCount: 0 })
    property int streakDays: 0
    property int totalFocusSeconds: 0
    property string loadError: ""
    // all=全部 active=进行中 done=已完成；对应头部三个筛选片。
    property string filterMode: "all"
    property bool completionRefreshDelayActive: false
    // 时钟快照：问候语与日期卡共用，分钟级刷新足够。
    property var now: new Date()

    readonly property var filteredTasks: {
        if (root.filterMode === "active") {
            return root.tasks.filter(function(task) { return !task.completed })
        }
        if (root.filterMode === "done") {
            return root.tasks.filter(function(task) { return Boolean(task.completed) })
        }
        return root.tasks
    }

    Component.onCompleted: refresh()
    onPendingDeleteTaskIdChanged: refresh()

    Timer {
        // 问候语跨时段、日期跨天都靠这只分钟表推进；页面不可见时停走。
        interval: 60000
        repeat: true
        running: root.visible
        onTriggered: root.now = new Date()
    }

    Connections {
        target: taskManager

        function onTasksChanged() {
            if (root.completionRefreshDelayActive)
                return
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

    Connections {
        target: focusTimer

        function onFocusCompleted(duration) {
            root.refresh()
        }
    }

    Connections {
        target: typeof routineManager !== "undefined" ? routineManager : null
        ignoreUnknownSignals: true

        function onRoutinesChanged() {
            root.refresh()
        }
    }

    Connections {
        // 逻辑日翻转后所有“今日”口径的数据都要重查。
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            root.now = new Date()
            root.refresh()
        }
    }

    Timer {
        id: completionRefreshTimer

        // 完成动画依附在 TaskItem 上，延迟刷新让粒子播完再重建列表。
        interval: 850
        repeat: false
        onTriggered: {
            root.completionRefreshDelayActive = false
            root.refresh()
        }
    }

    function todayIsoDate() {
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayIso(hour, new Date())
    }

    function refresh() {
        // 先幂等补齐当天例行任务，再分别加载任务与统计，互不拖垮。
        if (typeof routineManager !== "undefined" && routineManager && routineManager.materializeToday) {
            routineManager.materializeToday()
        }
        loadTasks()
        loadStats()
    }

    function loadTasks() {
        try {
            root.loadError = ""
            var loaded = taskManager.getTodayTasks()
            root.tasks = root.pendingDeleteTaskId > 0
                    ? loaded.filter(function(task) {
                        return Number(task.id) !== root.pendingDeleteTaskId
                    })
                    : loaded
        } catch (error) {
            root.tasks = []
            root.loadError = "任务加载失败"
        }
    }

    function loadStats() {
        try {
            root.todayStats = statisticsService.getTodayStats()
            root.streakDays = Number(statisticsService.getStreakDays() || 0)
            root.totalFocusSeconds = Number(statisticsService.getTotalFocusDuration() || 0)
        } catch (error) {
            root.todayStats = { totalDuration: 0, completedTasks: 0, totalTasks: root.tasks.length,
                                completionRate: 0, sessionCount: 0 }
            root.streakDays = 0
            root.totalFocusSeconds = 0
        }
    }

    function setTaskCompletedWithAnimationDelay(id, completed) {
        if (completed) {
            root.completionRefreshDelayActive = true
            completionRefreshTimer.restart()
        }

        if (!taskManager.setTaskCompleted(id, completed)) {
            completionRefreshTimer.stop()
            root.completionRefreshDelayActive = false
            root.tasks = []
            root.refresh()
            root.loadError = completed ? "任务完成失败，请重试" : "取消完成失败，请重试"
        }
    }

    function submitQuickAdd() {
        var title = quickAddField.text.trim()
        if (title.length === 0) {
            return
        }
        // -1 = 未分类；仪表盘只求快速记下，分类留给编辑弹窗补充。
        if (taskManager.addTask(title, root.todayIsoDate(), -1)) {
            quickAddField.clear()
        } else {
            root.loadError = "任务添加失败，请重试"
        }
    }

    function startFirstPendingTask() {
        // 待机态“开始专注”：捡列表第一个未完成任务；空手时带用户去专注页选模式。
        for (var i = 0; i < root.tasks.length; i++) {
            if (!root.tasks[i].completed) {
                root.startFocus(Number(root.tasks[i].id), String(root.tasks[i].title))
                return
            }
        }
        root.focusPageRequested()
    }

    function taskIsoDate(value) {
        // 数据层可能给 Date 对象也可能给 ISO 字符串，改名回写前统一成 yyyy-MM-dd。
        if (value instanceof Date) {
            return Qt.formatDate(value, "yyyy-MM-dd")
        }
        return String(value || "").substring(0, 10)
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

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.space16

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space4

                    Text {
                        objectName: "dashboardGreeting"

                        // 有昵称念名字，没有就只问好；逗号跟随昵称一起出现。
                        text: {
                            var nickname = root.settingsRef ? String(root.settingsRef.nickname || "") : ""
                            var greeting = DashboardFormat.greetingFor(root.now.getHours())
                            return nickname.length > 0 ? greeting + "，" + nickname : greeting
                        }
                        textFormat: Text.PlainText
                        font.pixelSize: Theme.fontXxl
                        font.weight: Font.Bold
                        color: Theme.inkStrong
                    }

                    Text {
                        text: "专注的每一分钟，都是未来的自己在为你加分。"
                        font.pixelSize: Theme.fontMd
                        color: Theme.inkSoft
                    }
                }

                GlassPanel {
                    Layout.preferredWidth: dateRow.implicitWidth + Theme.space32
                    Layout.preferredHeight: 60

                    RowLayout {
                        id: dateRow

                        anchors.centerIn: parent
                        spacing: Theme.space8

                        ColumnLayout {
                            spacing: 2

                            Text {
                                objectName: "dashboardDateText"

                                text: Qt.formatDate(root.now, "yyyy年M月d日") + " " + Qt.formatDate(root.now, "dddd")
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontMd
                                font.weight: Font.Medium
                                color: Theme.inkStrong
                            }

                            Text {
                                // 参考图此处是农历，暂无历表数据，先用“今年第 N 天”占位。
                                text: "今年第 " + (Math.floor((root.now.getTime()
                                        - new Date(root.now.getFullYear(), 0, 1).getTime()) / 86400000) + 1) + " 天"
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontXs
                                color: Theme.inkSoft
                            }
                        }
                    }
                }
            }

            CountdownBanner {
                objectName: "dashboardCountdownBanner"

                Layout.fillWidth: true
                primaryGoal: root.countdownServiceRef ? root.countdownServiceRef.primaryGoal : null
                visible: root.countdownServiceRef !== null

                onClicked: root.countdownRequested()
                onAddRequested: countdownDialog.openForAdd()
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space12

                StatCard {
                    Layout.fillWidth: true
                    title: "今日专注番茄"
                    value: String(Number(root.todayStats.sessionCount || 0))
                    unit: "个"
                    subtitle: "专注 " + root.formatDuration(root.todayStats.totalDuration)
                }

                StatCard {
                    Layout.fillWidth: true
                    title: "今日任务完成"
                    value: Number(root.todayStats.completedTasks || 0) + " / " + Number(root.todayStats.totalTasks || 0)
                    subtitle: "完成率 " + Math.round(Number(root.todayStats.completionRate || 0) * 100) + "%"
                    animationDelay: 60
                }

                StatCard {
                    objectName: "dashboardStreakCard"

                    Layout.fillWidth: true
                    title: "专注连续天数"
                    value: String(root.streakDays)
                    unit: "天"
                    subtitle: root.streakDays > 0 ? "继续保持这股势头" : "今天就是第一天"
                    animationDelay: 120
                }

                StatCard {
                    objectName: "dashboardTotalCard"

                    Layout.fillWidth: true
                    title: "累计专注时长"
                    value: DashboardFormat.totalHoursText(root.totalFocusSeconds)
                    unit: "小时"
                    subtitle: "相当于 " + DashboardFormat.equivalentDaysText(root.totalFocusSeconds) + " 天"
                    animationDelay: 180
                }
            }

            Label {
                Layout.fillWidth: true
                visible: root.loadError.length > 0
                text: root.loadError
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }

            GlassPanel {
                objectName: "dashboardTaskPanel"

                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.space16
                    spacing: Theme.space12

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space8

                        Text {
                            text: "今日任务"
                            font.pixelSize: Theme.fontLg
                            font.weight: Font.Bold
                            color: Theme.inkStrong
                        }

                        Rectangle {
                            implicitWidth: taskCountLabel.implicitWidth + Theme.space12
                            implicitHeight: 20
                            radius: 10
                            color: Theme.glassAccent

                            Text {
                                id: taskCountLabel
                                objectName: "dashboardTaskCount"

                                anchors.centerIn: parent
                                text: String(root.tasks.length)
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontXs
                                font.weight: Font.Bold
                                color: Theme.accentInk
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        Repeater {
                            model: [
                                { key: "all", label: "全部" },
                                { key: "active", label: "进行中" },
                                { key: "done", label: "已完成" }
                            ]

                            Rectangle {
                                id: filterChip

                                required property var modelData
                                readonly property bool selected: root.filterMode === filterChip.modelData.key

                                objectName: "dashboardFilter-" + filterChip.modelData.key
                                implicitWidth: filterLabel.implicitWidth + Theme.space16
                                implicitHeight: 26
                                radius: 13
                                color: filterChip.selected ? Theme.glassAccent
                                       : (filterArea.containsMouse ? Theme.glassHover : Qt.rgba(1, 1, 1, 0))
                                border.color: filterChip.selected ? Theme.accent : Theme.borderSubtle
                                border.width: 1

                                Behavior on color {
                                    ColorAnimation {
                                        duration: 120
                                        easing.type: Easing.OutQuad
                                    }
                                }

                                Text {
                                    id: filterLabel

                                    anchors.centerIn: parent
                                    text: filterChip.modelData.label
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSm
                                    font.weight: filterChip.selected ? Font.Medium : Font.Normal
                                    color: filterChip.selected ? Theme.accentInk : Theme.inkSoft
                                }

                                MouseArea {
                                    id: filterArea

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.filterMode = filterChip.modelData.key
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space8

                        TextField {
                            id: quickAddField
                            objectName: "dashboardQuickAddField"

                            Layout.fillWidth: true
                            implicitHeight: 38
                            placeholderText: "添加一项任务，按 Enter 快速保存"
                            placeholderTextColor: Theme.inkMuted
                            color: Theme.ink
                            font.pixelSize: Theme.fontMd

                            background: Rectangle {
                                color: Theme.surfaceSunken
                                radius: Theme.radiusLg
                                border.color: quickAddField.activeFocus ? Theme.accent : Theme.borderSubtle
                                border.width: 1
                            }

                            onAccepted: root.submitQuickAdd()
                        }

                        Button {
                            id: quickAddButton
                            objectName: "dashboardQuickAddButton"

                            text: "＋ 添加"
                            implicitWidth: 84
                            implicitHeight: 38

                            onClicked: root.submitQuickAdd()

                            background: Rectangle {
                                color: quickAddButton.pressed || quickAddButton.hovered ? Theme.accentStrong : Theme.accent
                                radius: Theme.radiusLg

                                Behavior on color {
                                    ColorAnimation {
                                        duration: 160
                                        easing.type: Easing.OutQuad
                                    }
                                }
                            }

                            contentItem: Text {
                                text: quickAddButton.text
                                textFormat: Text.PlainText
                                color: Theme.surface
                                font.pixelSize: Theme.fontMd
                                font.weight: Font.Medium
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }

                    Text {
                        objectName: "dashboardEmptyHint"

                        Layout.fillWidth: true
                        Layout.topMargin: Theme.space24
                        visible: root.filteredTasks.length === 0 && root.loadError.length === 0
                        text: root.tasks.length === 0
                              ? "今天还没有任务，先记下第一件要做的事。"
                              : "这个筛选下没有任务。"
                        font.pixelSize: Theme.fontMd
                        color: Theme.inkMuted
                        horizontalAlignment: Text.AlignHCenter
                    }

                    ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        visible: root.filteredTasks.length > 0

                        ColumnLayout {
                            width: Math.max(parent.width, 1)
                            spacing: Theme.space8

                            Repeater {
                                model: root.filteredTasks

                                TaskItem {
                                    taskId: modelData.id
                                    taskTitle: modelData.title
                                    taskCategory: modelData.category && modelData.category.name ? modelData.category : (modelData.categoryData && modelData.categoryData.name ? modelData.categoryData : (modelData.categoryText || ""))
                                    taskCompleted: modelData.completed

                                    onCompletionChanged: function (id, completed) {
                                        root.setTaskCompletedWithAnimationDelay(id, completed)
                                    }

                                    onStartFocusClicked: function (id, title) {
                                        root.startFocus(id, title)
                                    }

                                    onDeleteClicked: function (id, title) {
                                        root.deleteRequested(id, title)
                                    }

                                    onRenameSubmitted: function (id, newTitle) {
                                        var originalCategoryId = Number(modelData.categoryId || -1)
                                        var originalDate = root.taskIsoDate(modelData.date)
                                        if (!taskManager.updateTask(id, newTitle, originalCategoryId, originalDate)) {
                                            root.loadError = "任务更新失败，请重试"
                                        }
                                    }

                                    onEditClicked: function (id) {
                                        editTaskDialog.openForTask(modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        DashboardTimerPanel {
            objectName: "dashboardTimerPanel"

            Layout.preferredWidth: 300
            Layout.fillHeight: true
            timerRef: typeof focusTimer !== "undefined" ? focusTimer : null
            settingsRef: root.settingsRef
            wallpaperRef: root.wallpaperRef
            sessionCount: Number(root.todayStats.sessionCount || 0)

            onOpenFocusRequested: root.focusPageRequested()
            onStartRequested: root.startFirstPendingTask()
        }
    }

    EditTaskDialog {
        id: editTaskDialog

        parent: root
        categoryManagerRef: root.categoryManagerRef

        onTaskEdited: function (taskId, title, categoryId, isoDate) {
            if (!taskManager.updateTask(taskId, title, categoryId, isoDate)) {
                root.loadError = "任务更新失败，请重试"
            }
        }
    }

    CountdownDialog {
        id: countdownDialog

        parent: root
        countdownServiceRef: root.countdownServiceRef
    }
}
