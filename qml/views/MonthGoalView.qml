import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import "../components"

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)

    property int currentYear: new Date().getFullYear()
    property int currentMonth: new Date().getMonth() + 1
    property int selectedDay: new Date().getDate()
    property var monthTasks: []
    property var categoryManagerRef: null
    property string loadError: ""
    property date pendingAddDate: dateForDay(selectedDay)

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

    function refresh() {
        try {
            root.loadError = "";
            root.monthTasks = taskManager.getMonthTasks(root.currentYear, root.currentMonth);
        } catch (error) {
            root.monthTasks = [];
            root.loadError = "月度目标加载失败";
        }
    }

    function daysInMonth() {
        return new Date(root.currentYear, root.currentMonth, 0).getDate();
    }

    function firstOffset() {
        // 月历按周一开头；JS getDay() 的周日为 0，需要映射到最后一列。
        var day = new Date(root.currentYear, root.currentMonth - 1, 1).getDay();
        return day === 0 ? 6 : day - 1;
    }

    function dateForDay(day) {
        return new Date(root.currentYear, root.currentMonth - 1, Math.max(1, day));
    }

    function isoDate(value) {
        return Qt.formatDate(value, "yyyy-MM-dd");
    }

    function tasksForDay(day) {
        var target = root.isoDate(root.dateForDay(day));
        var result = [];
        for (var i = 0; i < root.monthTasks.length; i++) {
            if (Qt.formatDate(root.monthTasks[i].date, "yyyy-MM-dd") === target) {
                result.push(root.monthTasks[i]);
            }
        }
        return result;
    }

    function completedCount(tasks) {
        var count = 0;
        for (var i = 0; i < tasks.length; i++) {
            if (tasks[i].completed) {
                count++;
            }
        }
        return count;
    }

    function monthCompletedCount() {
        return root.completedCount(root.monthTasks);
    }

    function selectedTasks() {
        return root.tasksForDay(root.selectedDay);
    }

    function setMonth(year, month) {
        root.currentYear = year;
        root.currentMonth = month;
        // 切到短月份时，避免 selectedDay 指向不存在的日期。
        root.selectedDay = Math.min(root.selectedDay, root.daysInMonth());
        root.refresh();
    }

    function openAddTask() {
        root.pendingAddDate = root.dateForDay(root.selectedDay);
        addTaskDialog.selectedDate = root.pendingAddDate;
        addTaskDialog.open();
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
                    text: "月度目标"
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    color: "#5d4e37"
                }

                Text {
                    text: root.currentYear + "年" + root.currentMonth + "月"
                    font.pixelSize: 13
                    color: "#8b7355"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                spacing: 12

                Button {
                    id: previousMonthButton
                    objectName: "monthPreviousButton"
                    text: "上月"
                    implicitWidth: 72
                    implicitHeight: 40
                    background: Rectangle {
                        objectName: "monthPreviousButtonBackground"
                        color: previousMonthButton.pressed ? "#ddd4bb" : (previousMonthButton.hovered ? "#f5ede3" : "#fffef9")
                        border.color: previousMonthButton.hovered || previousMonthButton.pressed ? "#d4a574" : "#e8dfc8"
                        border.width: 1
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
                    }
                    contentItem: Text {
                        text: previousMonthButton.text
                        color: "#5d4e37"
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        scale: previousMonthButton.pressed ? 0.96 : 1.0
                    }
                    onClicked: {
                        if (root.currentMonth === 1) {
                            root.setMonth(root.currentYear - 1, 12);
                        } else {
                            root.setMonth(root.currentYear, root.currentMonth - 1);
                        }
                    }
                }

                Button {
                    id: currentMonthButton
                    objectName: "monthCurrentButton"
                    text: "本月"
                    implicitWidth: 72
                    implicitHeight: 40
                    background: Rectangle {
                        objectName: "monthCurrentButtonBackground"
                        color: currentMonthButton.pressed ? "#ddd4bb" : (currentMonthButton.hovered ? "#f5ede3" : "#fffef9")
                        border.color: currentMonthButton.hovered || currentMonthButton.pressed ? "#d4a574" : "#e8dfc8"
                        border.width: 1
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
                    }
                    contentItem: Text {
                        text: currentMonthButton.text
                        color: "#5d4e37"
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        scale: currentMonthButton.pressed ? 0.96 : 1.0
                    }
                    onClicked: {
                        var today = new Date();
                        root.currentYear = today.getFullYear();
                        root.currentMonth = today.getMonth() + 1;
                        root.selectedDay = today.getDate();
                        root.refresh();
                    }
                }

                Button {
                    id: nextMonthButton
                    objectName: "monthNextButton"
                    text: "下月"
                    implicitWidth: 72
                    implicitHeight: 40
                    background: Rectangle {
                        objectName: "monthNextButtonBackground"
                        color: nextMonthButton.pressed ? "#ddd4bb" : (nextMonthButton.hovered ? "#f5ede3" : "#fffef9")
                        border.color: nextMonthButton.hovered || nextMonthButton.pressed ? "#d4a574" : "#e8dfc8"
                        border.width: 1
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
                    }
                    contentItem: Text {
                        text: nextMonthButton.text
                        color: "#5d4e37"
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        scale: nextMonthButton.pressed ? 0.96 : 1.0
                    }
                    onClicked: {
                        if (root.currentMonth === 12) {
                            root.setMonth(root.currentYear + 1, 1);
                        } else {
                            root.setMonth(root.currentYear, root.currentMonth + 1);
                        }
                    }
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
                    objectName: "monthTotalStatCard"
                    Layout.fillWidth: true
                    title: "本月任务"
                    value: String(root.monthTasks.length)
                    subtitle: "计划内任务总数"
                }

                StatCard {
                    objectName: "monthCompletedStatCard"
                    Layout.fillWidth: true
                    title: "已完成"
                    value: String(root.monthCompletedCount())
                    subtitle: "完成后会计入月度进度"
                }

                StatCard {
                    objectName: "monthRateStatCard"
                    Layout.fillWidth: true
                    title: "完成率"
                    value: root.monthTasks.length > 0 ? Math.round(root.monthCompletedCount() * 100 / root.monthTasks.length) + "%" : "0%"
                    subtitle: "只统计本月任务"
                }
            }

            ColumnLayout {
                objectName: "monthContentStack"
                // 日历和详情上下排列，避免左右挤压导致日期单元格过窄。
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Layout.bottomMargin: 24
                spacing: 16

                Rectangle {
                    objectName: "monthCalendarContainer"
                    Layout.fillWidth: true
                    Layout.minimumHeight: 520
                    Layout.preferredHeight: 560
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
                        spacing: 8

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 7
                            columnSpacing: 6

                            Repeater {
                                model: ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    color: "#8b7355"
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            columns: 7
                            columnSpacing: 6
                            rowSpacing: 6

                            Repeater {
                                model: 42

                                Rectangle {
                                    // 固定 6 周网格，月份切换时日历高度不会跳动。
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: 58
                                    property int dayNumber: {
                                        var day = index - root.firstOffset() + 1;
                                        return day >= 1 && day <= root.daysInMonth() ? day : 0;
                                    }
                                    property var dayTasks: dayNumber > 0 ? root.tasksForDay(dayNumber) : []
                                    property bool todayCell: {
                                        var today = new Date();
                                        return dayNumber > 0 && root.currentYear === today.getFullYear() && root.currentMonth === today.getMonth() + 1 && dayNumber === today.getDate();
                                    }

                                    objectName: dayNumber > 0 ? "monthDayCell-" + dayNumber : "monthDayCell-empty-" + index
                                    radius: 6
                                    color: {
                                        if (dayNumber === root.selectedDay)
                                            return "#f0e6d2";
                                        if (todayCell)
                                            return "#f5ede3";
                                        if (dayMouseArea.containsMouse)
                                            return "#faf8f3";
                                        return "#fffef9";
                                    }
                                    border.color: {
                                        if (dayNumber === root.selectedDay || todayCell || dayMouseArea.containsMouse)
                                            return "#d4a574";
                                        return "#e8dfc8";
                                    }
                                    border.width: (dayNumber === root.selectedDay || todayCell) ? 2 : 1
                                    opacity: dayNumber > 0 ? 1.0 : 0.35

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

                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 6
                                        spacing: 2

                                        Text {
                                            Layout.fillWidth: true
                                            text: dayNumber > 0 ? String(dayNumber) : ""
                                            font.pixelSize: 13
                                            font.weight: dayNumber === root.selectedDay ? Font.Bold : Font.Normal
                                            color: "#5d4e37"
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            visible: dayNumber > 0 && dayTasks.length > 0
                                            text: dayTasks.length + "项 / 完成" + root.completedCount(dayTasks)
                                            font.pixelSize: 11
                                            color: "#8b7355"
                                            elide: Text.ElideRight
                                        }
                                    }

                                    MouseArea {
                                        id: dayMouseArea
                                        anchors.fill: parent
                                        enabled: parent.dayNumber > 0
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.selectedDay = parent.dayNumber
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    objectName: "monthDetailPanel"
                    Layout.fillWidth: true
                    Layout.minimumHeight: 260
                    Layout.preferredHeight: 300
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
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                Layout.fillWidth: true
                                text: root.currentMonth + "月" + root.selectedDay + "日"
                                font.pixelSize: 16
                                font.weight: Font.Bold
                                color: "#5d4e37"
                            }

                            Button {
                                id: detailAddButton
                                objectName: "monthDetailAddButton"
                                text: "添加"
                                implicitWidth: 72
                                implicitHeight: 36
                                background: Rectangle {
                                    objectName: "monthDetailAddButtonBackground"
                                    color: detailAddButton.pressed ? "#c99666" : (detailAddButton.hovered ? "#d9a574" : "#d4a574")
                                    radius: 8
                                    Behavior on color {
                                        ColorAnimation {
                                            duration: 160
                                            easing.type: Easing.OutQuad
                                        }
                                    }
                                }
                                contentItem: Text {
                                    text: detailAddButton.text
                                    color: "#fffef9"
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    scale: detailAddButton.pressed ? 0.96 : 1.0
                                }
                                onClicked: root.openAddTask()
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: root.selectedTasks().length === 0
                            text: "这一天还没有任务。"
                            font.pixelSize: 13
                            color: "#8b7355"
                            wrapMode: Text.WordWrap
                        }

                        ScrollView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true

                            ColumnLayout {
                                width: Math.max(parent.width, 1)
                                spacing: 8

                                Repeater {
                                    model: root.selectedTasks()

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
            }
        }
    }

    AddTaskDialog {
        id: addTaskDialog

        selectedDate: root.pendingAddDate
        categoryManagerRef: root.categoryManagerRef

        onTaskAdded: function (title, date, categoryId) {
            taskManager.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), Number(categoryId));
        }
    }
}
