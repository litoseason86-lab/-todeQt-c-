import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import "../components"
import ".."
import "../LogicalDay.js" as LogicalDay

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)
    signal countdownRequested()
    signal deleteRequested(int taskId, string title)

    property var tasks: []
    property var todayStats: ({
            totalDuration: 0,
            completedTasks: 0,
            totalTasks: 0,
            completionRate: 0
    })
    property var categoryManagerRef: null
    property var countdownServiceRef: null
    property var settingsRef: null
    property var overdueTasks: []
    property bool rolloverBannerActive: false
    property int pendingDeleteTaskId: -1
    property string loadError: ""
    property bool completionRefreshDelayActive: false
    property bool pageActive: true
    // 当日专注目标（分钟）；0 = 今天尚未设置。设置/修改只在本页发生。
    property int dailyFocusGoalMinutes: 0
    // 昨天的目标分钟数：未设置态快捷 chip 的数据源（单键快照跨日后即昨天值）。
    property int yesterdayGoalMinutes: 0

    // 实时专注秒数统一口径（与仪表盘共用 FocusLiveSeconds，禁止各自拼接）。
    readonly property FocusLiveSeconds liveSecondsSource: FocusLiveSeconds {
        // qmllint disable unqualified
        timerRef: typeof focusTimer !== "undefined" ? focusTimer : null
        // qmllint enable unqualified
        baseSeconds: Number(root.todayStats.totalDuration || 0)
    }

    Component.onCompleted: {
        if (root.pageActive)
            refresh()
    }
    onPageActiveChanged: {
        if (root.pageActive)
            refresh()
    }
    onPendingDeleteTaskIdChanged: {
        if (root.pageActive)
            refresh()
    }

    Connections {
        // 目标保存后（本页或未来其它入口）重读，保证展示与存储一致。
        target: root.settingsRef
        ignoreUnknownSignals: true

        function onDailyFocusGoalChanged() {
            root.loadDailyFocusGoal()
        }
    }

    Connections {
        target: taskManager
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onTasksChanged() {
            if (root.completionRefreshDelayActive)
                return;
            root.refresh();
        }

        function onOperationFailed(message) {
            root.loadError = String(message || "任务加载失败")
        }
    }

    Timer {
        id: completionRefreshTimer

        interval: 850
        repeat: false
        onTriggered: {
            root.completionRefreshDelayActive = false;
            root.refresh();
        }
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onCategoriesChanged() {
            root.refresh();
        }
    }

    Connections {
        target: focusTimer
        enabled: root.pageActive

        function onFocusCompleted(duration) {
            root.refresh();
        }
    }

    Connections {
        target: statisticsService
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onOperationFailed(message) {
            root.loadError = String(message || "统计数据加载失败")
        }
    }

    Connections {
        target: typeof routineManager !== "undefined" ? routineManager : null
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onRoutinesChanged() {
            root.refresh();
        }

        function onOperationFailed(message) {
            root.loadError = String(message || "每日例行生成失败")
        }
    }

    Connections {
        // 逻辑日失效后重新查询今日任务与结转。main.cpp 的直连会先补齐新日例行任务，
        // 因此这个视图槽只负责重载，不重复承担跨层调度职责。
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            root.refresh()
        }
    }

    function todayIsoDate() {
        // 结转忽略日期与 TaskManager 的逾期判定必须使用同一逻辑今天。
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayIso(hour, new Date());
    }

    function yesterdayIsoDate() {
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        var today = LogicalDay.todayDate(hour, new Date())
        var yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1)
        return Qt.formatDate(yesterday, "yyyy-MM-dd")
    }

    function loadDailyFocusGoal() {
        // 只认「目标日期 == 逻辑今天」；不一致视为今天未设置。
        if (!root.settingsRef || !root.settingsRef.dailyFocusGoalMinutesForDate) {
            root.dailyFocusGoalMinutes = 0
            root.yesterdayGoalMinutes = 0
            return
        }
        root.dailyFocusGoalMinutes = Number(
            root.settingsRef.dailyFocusGoalMinutesForDate(root.todayIsoDate()) || 0)
        root.yesterdayGoalMinutes = Number(
            root.settingsRef.dailyFocusGoalMinutesForDate(root.yesterdayIsoDate()) || 0)
    }

    function saveDailyFocusGoal(minutes) {
        if (!root.settingsRef || !root.settingsRef.setDailyFocusGoal) {
            return false
        }
        return Boolean(root.settingsRef.setDailyFocusGoal(root.todayIsoDate(), minutes))
    }

    function loadOverdueTasks() {
        // 测试桩或旧上下文可能还没提供结转接口；缺失时按无逾期处理，不能拖垮今日页。
        if (!taskManager.getOverdueUncompletedTasks) {
            root.overdueTasks = [];
            root.rolloverBannerActive = false;
            return;
        }

        root.overdueTasks = taskManager.getOverdueUncompletedTasks();
        var ignoredToday = root.settingsRef && root.settingsRef.rolloverIgnoredDate === root.todayIsoDate();
        root.rolloverBannerActive = root.overdueTasks.length > 0 && !ignoredToday;
    }

    function moveOverdueToToday() {
        var ids = [];
        for (var i = 0; i < root.overdueTasks.length; i++) {
            ids.push(Number(root.overdueTasks[i].id));
        }

        if (taskManager.moveTasksToToday(ids)) {
            root.refresh();
        } else {
            root.loadError = "结转失败，请重试";
        }
    }

    function ignoreOverdueForToday() {
        if (root.settingsRef) {
            root.settingsRef.rolloverIgnoredDate = root.todayIsoDate();
        }
        root.rolloverBannerActive = false;
    }

    function taskIsoDate(value) {
        if (value instanceof Date) {
            return Qt.formatDate(value, "yyyy-MM-dd");
        }
        return String(value || "").substring(0, 10);
    }

    function refresh() {
        // 每次刷新前先确保当天真实任务行已生成；跨午夜后只要页面触发刷新就会补上当天例行项。
        // materializeToday 幂等且不发 tasksChanged，避免 refresh 递归。
        if (typeof routineManager !== "undefined" && routineManager && routineManager.materializeToday) {
            routineManager.materializeToday();
        }

        // 任务和统计分开加载，避免统计失败拖垮任务列表。
        loadOverdueTasks();
        loadTasks();
        loadStats();
        loadDailyFocusGoal();
    }

    function setTaskCompletedWithAnimationDelay(id, completed) {
        if (completed) {
            // 完成动画依附在当前 TaskItem delegate 上；TaskManager 会同步发 tasksChanged，
            // 如果立即刷新 Repeater，delegate 会被销毁，粒子动画看不到结束。
            root.completionRefreshDelayActive = true;
            completionRefreshTimer.restart();
        }

        var ok = taskManager.setTaskCompleted(id, completed);
        if (!ok) {
            completionRefreshTimer.stop();
            root.completionRefreshDelayActive = false;
            // 失败时当前 delegate 已经被 TaskItem 乐观切到完成态；先清空模型强制销毁它，
            // 再从数据源重载，避免界面停在“已完成”的假状态。
            root.tasks = [];
            root.refresh();
            root.loadError = completed ? "任务完成失败，请重试" : "取消完成失败，请重试";
            return;
        }
    }

    function loadTasks() {
        try {
            root.loadError = "";
            var loaded = taskManager.getTodayTasks();
            // 待删除行先在界面消失；撤销时 pendingDeleteTaskId 回到 -1，刷新后自然恢复。
            root.tasks = root.pendingDeleteTaskId > 0
                    ? loaded.filter(function(task) {
                        return Number(task.id) !== root.pendingDeleteTaskId;
                    })
                    : loaded;
        } catch (error) {
            root.tasks = [];
            root.loadError = "任务加载失败";
        }
    }

    function loadStats() {
        try {
            root.todayStats = statisticsService.getTodayStats();
        } catch (error) {
            root.todayStats = {
                totalDuration: 0,
                completedTasks: 0,
                totalTasks: root.tasks.length,
                completionRate: 0
            };
        }
    }

    function formatDuration(seconds) {
        // 秒级专注也要显示出来，否则短测试会看起来像没有记录。
        var safe = Math.max(0, Math.floor(Number(seconds || 0)));
        if (safe > 0 && safe < 60) {
            return safe + "秒";
        }
        var hours = Math.floor(safe / 3600);
        var minutes = Math.floor((safe % 3600) / 60);
        if (hours > 0) {
            return hours + "小时" + minutes + "分钟";
        }
        return minutes + "分钟";
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space4

                Text {
                    text: "今日任务"
                    font.pixelSize: Theme.fontXxl
                    font.weight: Font.Bold
                    color: Theme.ink
                }

                Text {
                    objectName: "todayDescriptionText"
                    text: "把今天的学习任务收拢到一个清单里。"
                    font.pixelSize: Theme.fontMd
                    color: Theme.ink
                }
            }

            Button {
                id: addButton
                objectName: "todayAddButton"

                text: "添加任务"
                implicitWidth: 112
                implicitHeight: 44

                background: Rectangle {
                    objectName: "todayAddButtonBackground"
                    color: addButton.pressed ? Theme.accentStrong : (addButton.hovered ? Theme.accentStrong : Theme.accent)
                    border.color: addButton.hovered ? Theme.accentStrong : "transparent"
                    border.width: addButton.hovered ? 1 : 0
                    radius: Theme.radiusLg

                    Behavior on color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }

                    Behavior on border.color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }

                    Behavior on border.width {
                        NumberAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    objectName: "todayAddButtonLabel"
                    text: addButton.text
                    color: Theme.accentForeground
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    scale: addButton.pressed ? 0.96 : 1.0

                    Behavior on scale {
                        NumberAnimation {
                            duration: 90
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                onClicked: addTaskDialog.open()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.border
        }

        CountdownBanner {
            Layout.fillWidth: true
            primaryGoal: root.countdownServiceRef ? root.countdownServiceRef.primaryGoal : null
            visible: root.countdownServiceRef !== null

            onClicked: root.countdownRequested()
            onAddRequested: countdownDialog.openForAdd()
        }

        FocusGoalStrip {
            id: todayGoalCard
            objectName: "todayGoalCard"

            Layout.fillWidth: true
            // 倒计时横幅下方通栏（与仪表盘同构）：设置/修改只在本页；
            // 「任务完成」计数并入条右端。
            totalSeconds: root.liveSecondsSource.liveSeconds
            goalMinutes: root.dailyFocusGoalMinutes
            quickFillMinutes: root.yesterdayGoalMinutes
            completedTasks: Number(root.todayStats.completedTasks || 0)
            totalTasks: Number(root.todayStats.totalTasks || 0)
            reduceMotion: root.settingsRef ? Boolean(root.settingsRef.reduceMotion) : false

            onGoalSubmitted: function (totalMinutes) {
                todayGoalCard.handleSaveResult(root.saveDailyFocusGoal(totalMinutes))
            }
        }

        Rectangle {
            objectName: "rolloverBanner"
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            visible: root.rolloverBannerActive
            radius: Theme.radiusLg
            color: Theme.glassAccent
            border.color: Theme.accent
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.space16
                anchors.rightMargin: Theme.space12
                spacing: Theme.space12

                Text {
                    objectName: "rolloverBannerText"
                    Layout.fillWidth: true
                    text: "之前还有 " + root.overdueTasks.length + " 个未完成任务"
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    color: Theme.inkStrong
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }

                Button {
                    id: rolloverMoveButton
                    objectName: "rolloverMoveButton"
                    text: "全部移到今天"
                    implicitHeight: 34

                    onClicked: root.moveOverdueToToday()

                    background: Rectangle {
                        color: rolloverMoveButton.hovered ? Theme.accentStrong : Theme.accent
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: rolloverMoveButton.text
                        textFormat: Text.PlainText
                        color: Theme.accentForeground
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: rolloverIgnoreButton
                    objectName: "rolloverIgnoreButton"
                    text: "忽略"
                    implicitHeight: 34

                    onClicked: root.ignoreOverdueForToday()

                    background: Rectangle {
                        color: rolloverIgnoreButton.hovered ? Theme.surfaceSunken : "transparent"
                        border.color: Theme.border
                        border.width: 1
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: rolloverIgnoreButton.text
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
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

        Rectangle {
            objectName: "todayTaskListContainer"
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Theme.glassCard
            radius: Theme.radiusLg
            border.color: Theme.glassBorder
            border.width: 1
            layer.enabled: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                shadowEnabled: true
                shadowColor: Theme.shadow
                shadowOpacity: 0.08
                shadowBlur: 0.14
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 2
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                visible: root.tasks.length === 0 && root.loadError.length === 0

                Item {
                    Layout.fillHeight: true
                }

                Rectangle {
                    objectName: "todayEmptyStateCard"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 420
                    Layout.preferredHeight: 150
                    radius: Theme.radiusLg
                    color: Theme.surfaceRaised
                    border.color: Theme.border
                    border.width: 1

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width - 48
                        spacing: 10

                        Rectangle {
                            objectName: "todayEmptyStateIcon"
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: 40
                            Layout.preferredHeight: 40
                            radius: Theme.radiusLg
                            color: Theme.accentSoft
                            border.color: Theme.border
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: "今"
                                font.pixelSize: Theme.fontXl
                                font.weight: Font.Bold
                                color: Theme.accent
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "今天还没有任务"
                            font.pixelSize: Theme.fontXl
                            font.weight: Font.Bold
                            color: Theme.ink
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "先添加一个明确到可执行的任务。空清单不是轻松，只是没有外化。"
                            font.pixelSize: Theme.fontMd
                            color: Theme.inkSoft
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }

                Item {
                    Layout.fillHeight: true
                }
            }

            ListView {
                id: todayTaskList

                anchors.fill: parent
                clip: true
                visible: root.tasks.length > 0
                model: root.tasks
                spacing: Theme.space8
                boundsBehavior: Flickable.StopAtBounds

                delegate: TaskItem {
                            width: todayTaskList.width
                            height: implicitHeight
                            taskId: modelData.id
                            taskTitle: modelData.title
                            taskCategory: modelData.category && modelData.category.name ? modelData.category : (modelData.categoryData && modelData.categoryData.name ? modelData.categoryData : (modelData.categoryText || ""))
                            taskCompleted: modelData.completed

                            onCompletionChanged: function (id, completed) {
                                root.setTaskCompletedWithAnimationDelay(id, completed);
                            }

                            onStartFocusClicked: function (id, title) {
                                root.startFocus(id, title);
                            }

                            onDeleteClicked: function (id, title) {
                                root.deleteRequested(id, title);
                            }

                            onRenameSubmitted: function (id, newTitle) {
                                var originalCategoryId = Number(modelData.categoryId || -1);
                                var originalDate = root.taskIsoDate(modelData.date);
                                if (!taskManager.updateTask(id, newTitle, originalCategoryId, originalDate)) {
                                    root.loadError = "任务更新失败，请重试";
                                }
                            }

                            onEditClicked: function (id) {
                                editTaskDialog.openForTask(modelData);
                            }
                        }
            }
        }

    }

    AddTaskDialog {
        id: addTaskDialog

        categoryManagerRef: root.categoryManagerRef
        taskSubmitter: function (title, date, categoryId) {
            return taskManager.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), Number(categoryId));
        }
    }

    EditTaskDialog {
        id: editTaskDialog

        parent: root
        categoryManagerRef: root.categoryManagerRef

        onTaskEdited: function (taskId, title, categoryId, isoDate) {
            if (!taskManager.updateTask(taskId, title, categoryId, isoDate)) {
                root.loadError = "任务更新失败，请重试";
            }
        }
    }

    CountdownDialog {
        id: countdownDialog

        parent: root
        countdownServiceRef: root.countdownServiceRef
    }
}
