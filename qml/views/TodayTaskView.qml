import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import "../components"
import ".."

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)
    signal countdownRequested()

    property var tasks: []
    property var todayStats: ({
            totalDuration: 0,
            completedTasks: 0,
            totalTasks: 0,
            completionRate: 0
        })
    property var categoryManagerRef: null
    property var countdownServiceRef: null
    property string loadError: ""
    property bool completionRefreshDelayActive: false

    Component.onCompleted: refresh()

    Connections {
        target: taskManager

        function onTasksChanged() {
            if (root.completionRefreshDelayActive)
                return;
            root.refresh();
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

        function onCategoriesChanged() {
            root.refresh();
        }
    }

    Connections {
        target: focusTimer

        function onFocusCompleted(duration) {
            root.refresh();
        }
    }

    Connections {
        target: typeof routineManager !== "undefined" ? routineManager : null
        ignoreUnknownSignals: true

        function onRoutinesChanged() {
            root.refresh();
        }
    }

    function refresh() {
        // 每次刷新前先确保当天真实任务行已生成；跨午夜后只要页面触发刷新就会补上当天例行项。
        // materializeToday 幂等且不发 tasksChanged，避免 refresh 递归。
        if (typeof routineManager !== "undefined" && routineManager && routineManager.materializeToday) {
            routineManager.materializeToday();
        }

        // 任务和统计分开加载，避免统计失败拖垮任务列表。
        loadTasks();
        loadStats();
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
            root.tasks = taskManager.getTodayTasks();
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
                    color: Theme.surface
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

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            Rectangle {
                objectName: "todayFocusStatCard"
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                radius: Theme.radiusLg
                color: Theme.surface
                border.color: Theme.border
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
                    anchors.margins: Theme.space12
                    spacing: Theme.space4

                    Text {
                        text: root.formatDuration(root.todayStats.totalDuration)
                        font.pixelSize: Theme.fontXl
                        font.weight: Font.Bold
                        color: Theme.ink
                    }

                    Text {
                        text: "今日专注"
                        font.pixelSize: Theme.fontSm
                        color: Theme.inkSoft
                    }
                }
            }

            Rectangle {
                objectName: "todayCompletionStatCard"
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                radius: Theme.radiusLg
                color: Theme.surface
                border.color: Theme.border
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
                    anchors.margins: Theme.space12
                    spacing: Theme.space4

                    Text {
                        text: Number(root.todayStats.completedTasks || 0) + " / " + Number(root.todayStats.totalTasks || 0)
                        font.pixelSize: Theme.fontXl
                        font.weight: Font.Bold
                        color: Theme.ink
                    }

                    Text {
                        text: "任务完成"
                        font.pixelSize: Theme.fontSm
                        color: Theme.inkSoft
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
            color: Theme.surface
            radius: Theme.radiusLg
            border.color: Theme.border
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

            ScrollView {
                anchors.fill: parent
                clip: true
                visible: root.tasks.length > 0

                ColumnLayout {
                    width: Math.max(parent.width, 1)
                    spacing: Theme.space8

                    Repeater {
                        model: root.tasks

                        TaskItem {
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
                                if (!taskManager.deleteTask(id)) {
                                    root.loadError = "任务删除失败，请重试";
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    AddTaskDialog {
        id: addTaskDialog

        selectedDate: new Date()
        categoryManagerRef: root.categoryManagerRef

        onTaskAdded: function (title, date, categoryId) {
            taskManager.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), Number(categoryId));
        }
    }

    CountdownDialog {
        id: countdownDialog

        parent: root
        countdownServiceRef: root.countdownServiceRef
    }
}
