import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import ".."

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)

    property date weekStart: mondayOf(new Date())
    property var weekTasks: []
    property var categoryManagerRef: null
    property string loadError: ""
    property date pendingAddDate: new Date()
    property bool completionRefreshDelayActive: false

    Component.onCompleted: refresh()

    Connections {
        target: taskManager

        function onTasksChanged() {
            if (root.completionRefreshDelayActive)
                return
            root.refresh()
        }
    }

    Timer {
        id: completionRefreshTimer

        interval: 850
        repeat: false
        onTriggered: {
            root.completionRefreshDelayActive = false
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
        // 周计划固定以周一为起点，避免系统区域设置影响列顺序。
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
        // weekTasks 一次性加载，按列在前端过滤，避免每个日期重复查库。
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

    function setTaskCompletedWithAnimationDelay(id, completed) {
        if (completed) {
            // 完成动画依附在当前 TaskItem delegate 上；TaskManager 会同步发 tasksChanged，
            // 如果立即刷新 Repeater，delegate 会被销毁，粒子动画看不到结束。
            root.completionRefreshDelayActive = true
            completionRefreshTimer.restart()
        }

        var ok = taskManager.setTaskCompleted(id, completed)
        if (!ok) {
            completionRefreshTimer.stop()
            root.completionRefreshDelayActive = false
            // 失败时当前 delegate 已经被 TaskItem 乐观切到完成态；先清空模型强制销毁它，
            // 再从数据源重载，避免界面停在“已完成”的假状态。
            root.weekTasks = []
            root.refresh()
            root.loadError = completed ? "任务完成失败，请重试" : "取消完成失败，请重试"
        }
    }

    function openAddTaskForDay(index) {
        root.pendingAddDate = root.dayDate(index)
        addTaskDialog.selectedDate = root.pendingAddDate
        addTaskDialog.open()
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
                    text: "本周计划"
                    font.pixelSize: Theme.fontXxl
                    font.bold: true
                    color: Theme.ink
                }

                Text {
                    text: root.isoDate(root.weekStart) + " - " + root.isoDate(root.dayDate(6))
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                }
            }

            Button {
                id: prevWeekButton
                text: "上一周"
                implicitWidth: 84
                implicitHeight: 40

                // 次级暖色描边样式：低调、与卡片协调，避免满屏强调色块。
                background: Rectangle {
                    color: prevWeekButton.pressed ? Theme.borderSubtle : (prevWeekButton.hovered ? Theme.surfaceSunken : Theme.surface)
                    border.color: prevWeekButton.hovered || prevWeekButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                    Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                }

                contentItem: Text {
                    text: prevWeekButton.text
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: {
                    var date = new Date(root.weekStart)
                    date.setDate(date.getDate() - 7)
                    root.weekStart = date
                    root.refresh()
                }
            }

            Button {
                id: thisWeekButton
                text: "本周"
                implicitWidth: 72
                implicitHeight: 40

                background: Rectangle {
                    color: thisWeekButton.pressed ? Theme.borderSubtle : (thisWeekButton.hovered ? Theme.surfaceSunken : Theme.surface)
                    border.color: thisWeekButton.hovered || thisWeekButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                    Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                }

                contentItem: Text {
                    text: thisWeekButton.text
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: {
                    root.weekStart = root.mondayOf(new Date())
                    root.refresh()
                }
            }

            Button {
                id: nextWeekButton
                text: "下一周"
                implicitWidth: 84
                implicitHeight: 40

                background: Rectangle {
                    color: nextWeekButton.pressed ? Theme.borderSubtle : (nextWeekButton.hovered ? Theme.surfaceSunken : Theme.surface)
                    border.color: nextWeekButton.hovered || nextWeekButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                    Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                }

                contentItem: Text {
                    text: nextWeekButton.text
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

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

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
                width: Math.max(parent.width, 1)
                spacing: Theme.space12

                Repeater {
                    model: 7

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: dayColumn.implicitHeight + 24
                        radius: Theme.radiusMd
                        color: Theme.surfaceRaised
                        border.color: Theme.border
                        border.width: 1

                        property var dayTasks: root.tasksForDay(index)

                        ColumnLayout {
                            id: dayColumn

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.space12
                            spacing: Theme.space8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space8

                                Text {
                                    Layout.fillWidth: true
                                    text: ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][index]
                                          + " " + Qt.formatDate(root.dayDate(index), "M月d日")
                                    font.pixelSize: Theme.fontXl
                                    font.bold: true
                                    color: Theme.ink
                                }

                                Button {
                                    id: addDayButton
                                    text: "添加"
                                    implicitWidth: 72
                                    implicitHeight: 36

                                    // 主强调填充，与今日任务页的「添加」按钮保持一致。
                                    background: Rectangle {
                                        color: addDayButton.pressed || addDayButton.hovered ? Theme.accentStrong : Theme.accent
                                        border.color: addDayButton.hovered ? Theme.accentStrong : "transparent"
                                        border.width: addDayButton.hovered ? 1 : 0
                                        radius: Theme.radiusMd

                                        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                                    }

                                    contentItem: Text {
                                        text: addDayButton.text
                                        color: Theme.surface
                                        font.pixelSize: Theme.fontMd
                                        font.weight: Font.Medium
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        scale: addDayButton.pressed ? 0.96 : 1.0

                                        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                                    }

                                    onClicked: root.openAddTaskForDay(index)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: dayTasks.length === 0
                                text: "暂无任务"
                                font.pixelSize: Theme.fontMd
                                color: Theme.inkSoft
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
                                        root.setTaskCompletedWithAnimationDelay(id, completed)
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
