import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)

    property date weekStart: mondayOf(new Date())
    property var weekTasks: []
    property var categoryManagerRef: null
    property string loadError: ""
    property date pendingAddDate: new Date()

    Component.onCompleted: refresh()

    Connections {
        target: taskManager

        function onTasksChanged() {
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

    function mondayOf(value) {
        var date = new Date(value)
        var day = date.getDay()
        var diff = day === 0 ? -6 : 1 - day
        date.setDate(date.getDate() + diff)
        date.setHours(0, 0, 0, 0)
        return date
    }

    function isoDate(value) {
        return Qt.formatDate(value, "yyyy-MM-dd")
    }

    function dayDate(index) {
        var date = new Date(root.weekStart)
        date.setDate(date.getDate() + index)
        return date
    }

    function tasksForDay(index) {
        var target = root.isoDate(root.dayDate(index))
        var result = []
        for (var i = 0; i < root.weekTasks.length; i++) {
            if (Qt.formatDate(root.weekTasks[i].date, "yyyy-MM-dd") === target) {
                result.push(root.weekTasks[i])
            }
        }
        return result
    }

    function refresh() {
        try {
            root.loadError = ""
            root.weekTasks = taskManager.getWeekTasks(root.isoDate(root.weekStart))
        } catch (error) {
            root.weekTasks = []
            root.loadError = "本周计划加载失败"
        }
    }

    function openAddTaskForDay(index) {
        root.pendingAddDate = root.dayDate(index)
        addTaskDialog.selectedDate = root.pendingAddDate
        addTaskDialog.open()
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
                    text: "本周计划"
                    font.pixelSize: 24
                    font.bold: true
                    color: "#5d4e37"
                }

                Text {
                    text: root.isoDate(root.weekStart) + " - " + root.isoDate(root.dayDate(6))
                    font.pixelSize: 13
                    color: "#8b7355"
                }
            }

            Button {
                text: "上一周"
                implicitWidth: 84
                implicitHeight: 40
                onClicked: {
                    var date = new Date(root.weekStart)
                    date.setDate(date.getDate() - 7)
                    root.weekStart = date
                    root.refresh()
                }
            }

            Button {
                text: "本周"
                implicitWidth: 72
                implicitHeight: 40
                onClicked: {
                    root.weekStart = root.mondayOf(new Date())
                    root.refresh()
                }
            }

            Button {
                text: "下一周"
                implicitWidth: 84
                implicitHeight: 40
                onClicked: {
                    var date = new Date(root.weekStart)
                    date.setDate(date.getDate() + 7)
                    root.weekStart = date
                    root.refresh()
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

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
                width: Math.max(parent.width, 1)
                spacing: 10

                Repeater {
                    model: 7

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: dayColumn.implicitHeight + 24
                        radius: 6
                        color: "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1

                        property var dayTasks: root.tasksForDay(index)

                        ColumnLayout {
                            id: dayColumn

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 12
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    Layout.fillWidth: true
                                    text: ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][index]
                                          + " " + Qt.formatDate(root.dayDate(index), "M月d日")
                                    font.pixelSize: 16
                                    font.bold: true
                                    color: "#5d4e37"
                                }

                                Button {
                                    text: "添加"
                                    implicitWidth: 72
                                    implicitHeight: 36
                                    onClicked: root.openAddTaskForDay(index)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: dayTasks.length === 0
                                text: "暂无任务"
                                font.pixelSize: 13
                                color: "#8b7355"
                            }

                            Repeater {
                                model: dayTasks

                                TaskItem {
                                    taskId: modelData.id
                                    taskTitle: modelData.title
                                    taskCategory: modelData.category && modelData.category.name
                                                  ? modelData.category
                                                  : (modelData.categoryData && modelData.categoryData.name
                                                     ? modelData.categoryData
                                                     : (modelData.categoryText || ""))
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

                                    onDeleteClicked: function(id, title) {
                                        if (!taskManager.deleteTask(id)) {
                                            root.loadError = "任务删除失败，请重试"
                                        }
                                    }
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

        selectedDate: root.pendingAddDate
        categoryManagerRef: root.categoryManagerRef

        onTaskAdded: function(title, date, categoryId) {
            taskManager.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), Number(categoryId))
        }
    }
}
