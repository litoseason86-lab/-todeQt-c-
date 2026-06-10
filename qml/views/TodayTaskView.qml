import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import "../components"

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)

    property var tasks: []
    property var todayStats: ({
            totalDuration: 0,
            completedTasks: 0,
            totalTasks: 0,
            completionRate: 0
        })
    property var categoryManagerRef: null
    property string loadError: ""

    Component.onCompleted: refresh()

    Connections {
        target: taskManager

        function onTasksChanged() {
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

    function refresh() {
        // 任务和统计分开加载，避免统计失败拖垮任务列表。
        loadTasks();
        loadStats();
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
        anchors.margins: 24
        spacing: 16

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4

                Text {
                    text: "今日任务"
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    color: "#5d4e37"
                }

                Text {
                    objectName: "todayDescriptionText"
                    text: "把今天的学习任务收拢到一个清单里。"
                    font.pixelSize: 13
                    color: "#6d5e47"
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
                    color: addButton.pressed ? "#c99666" : (addButton.hovered ? "#d9a574" : "#d4a574")
                    border.color: addButton.hovered ? "#c99666" : "transparent"
                    border.width: addButton.hovered ? 1 : 0
                    radius: 8

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
                    color: "#fffef9"
                    font.pixelSize: 14
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
            color: "#e8dfc8"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Rectangle {
                objectName: "todayFocusStatCard"
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                radius: 8
                color: "#fffef9"
                border.color: "#e8dfc8"
                border.width: 1
                layer.enabled: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: "#000000"
                    shadowOpacity: 0.08
                    shadowBlur: 0.14
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 2
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 4

                    Text {
                        text: root.formatDuration(root.todayStats.totalDuration)
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: "#5d4e37"
                    }

                    Text {
                        text: "今日专注"
                        font.pixelSize: 12
                        color: "#8b7355"
                    }
                }
            }

            Rectangle {
                objectName: "todayCompletionStatCard"
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                radius: 8
                color: "#fffef9"
                border.color: "#e8dfc8"
                border.width: 1
                layer.enabled: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: "#000000"
                    shadowOpacity: 0.08
                    shadowBlur: 0.14
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 2
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 4

                    Text {
                        text: Number(root.todayStats.completedTasks || 0) + " / " + Number(root.todayStats.totalTasks || 0)
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: "#5d4e37"
                    }

                    Text {
                        text: "任务完成"
                        font.pixelSize: 12
                        color: "#8b7355"
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: root.loadError.length > 0
            text: root.loadError
            color: "#b24f3d"
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }

        Rectangle {
            objectName: "todayTaskListContainer"
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#fffef9"
            radius: 8
            border.color: "#e8dfc8"
            border.width: 1
            layer.enabled: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                shadowEnabled: true
                shadowColor: "#000000"
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
                    radius: 8
                    color: "#faf8f3"
                    border.color: "#e8dfc8"
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
                            radius: 8
                            color: "#f0e6d2"
                            border.color: "#e8dfc8"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: "今"
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: "#d4a574"
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "今天还没有任务"
                            font.pixelSize: 18
                            font.weight: Font.Bold
                            color: "#5d4e37"
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "先添加一个明确到可执行的任务。空清单不是轻松，只是没有外化。"
                            font.pixelSize: 13
                            color: "#8b7355"
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
                    spacing: 8

                    Repeater {
                        model: root.tasks

                        TaskItem {
                            taskId: modelData.id
                            taskTitle: modelData.title
                            taskCategory: modelData.category && modelData.category.name ? modelData.category : (modelData.categoryData && modelData.categoryData.name ? modelData.categoryData : (modelData.categoryText || ""))
                            taskCompleted: modelData.completed

                            onCompletionChanged: function (id, completed) {
                                taskManager.setTaskCompleted(id, completed);
                            }

                            onStartFocusClicked: function (id, title) {
                                if (focusTimer.startFocus(id, title)) {
                                    root.startFocus(id, title);
                                } else {
                                    root.loadError = "专注启动失败，请重试";
                                }
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
}
