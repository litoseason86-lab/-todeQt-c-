import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)

    property var tasks: []
    property var todayStats: ({ totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 })
    property string loadError: ""

    Component.onCompleted: refresh()

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

    function refresh() {
        loadTasks()
        loadStats()
    }

    function loadTasks() {
        try {
            root.loadError = ""
            root.tasks = taskManager.getTodayTasks()
        } catch (error) {
            root.tasks = []
            root.loadError = "任务加载失败"
        }
    }

    function loadStats() {
        try {
            root.todayStats = statisticsService.getTodayStats()
        } catch (error) {
            root.todayStats = { totalDuration: 0, completedTasks: 0, totalTasks: root.tasks.length, completionRate: 0 }
        }
    }

    function formatDuration(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        if (hours > 0) {
            return hours + "小时" + minutes + "分钟"
        }
        return minutes + "分钟"
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
                    font.bold: true
                    color: "#5d4e37"
                }

                Text {
                    text: "把今天的学习任务收拢到一个清单里。"
                    font.pixelSize: 13
                    color: "#8b7355"
                }
            }

            Button {
                id: addButton

                text: "添加任务"
                implicitWidth: 112
                implicitHeight: 44

                background: Rectangle {
                    color: "#d4a574"
                    radius: 4
                }

                contentItem: Text {
                    text: addButton.text
                    color: "#fffef9"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
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
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                radius: 6
                color: "#faf6ee"
                border.color: "#e8dfc8"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 4

                    Text {
                        text: root.formatDuration(root.todayStats.totalDuration)
                        font.pixelSize: 20
                        font.bold: true
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
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                radius: 6
                color: "#faf6ee"
                border.color: "#e8dfc8"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 4

                    Text {
                        text: Number(root.todayStats.completedTasks || 0) + " / " + Number(root.todayStats.totalTasks || 0)
                        font.pixelSize: 20
                        font.bold: true
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
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "transparent"

            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                visible: root.tasks.length === 0 && root.loadError.length === 0

                Item {
                    Layout.fillHeight: true
                }

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 420
                    Layout.preferredHeight: 150
                    radius: 6
                    color: "#faf6ee"
                    border.color: "#e8dfc8"
                    border.width: 1

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width - 48
                        spacing: 10

                        Text {
                            Layout.fillWidth: true
                            text: "今天还没有任务"
                            font.pixelSize: 18
                            font.bold: true
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
                            taskCategory: modelData.category || ""
                            taskCompleted: modelData.completed

                            onCompletionChanged: function(id, completed) {
                                taskManager.setTaskCompleted(id, completed)
                            }

                            onStartFocusClicked: function(id, title) {
                                if (focusTimer.startFocus(id, title)) {
                                    root.startFocus(id, title)
                                } else {
                                    root.loadError = "专注启动失败，请重试"
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

        onTaskAdded: function(title, date, category) {
            taskManager.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), category)
        }
    }
}
