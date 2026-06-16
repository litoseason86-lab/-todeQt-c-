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

    // 周一起点对应的星期字，索引 0~6 = 周一~周日。
    readonly property var weekdayGlyphs: ["一", "二", "三", "四", "五", "六", "日"]

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

    function isTodayIndex(index) {
        // 用本地年月日比较，避免时区或时分秒影响“是否今天”的判断。
        var d = root.dayDate(index)
        var now = new Date()
        return d.getFullYear() === now.getFullYear()
                && d.getMonth() === now.getMonth()
                && d.getDate() === now.getDate()
    }

    function weekCompletedCount() {
        var n = 0
        for (var i = 0; i < root.weekTasks.length; i++) {
            if (root.weekTasks[i].completed)
                n++
        }
        return n
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
        // 右边距设为 0，让滚动区一直延伸到视图右缘、滚动条贴边（对齐其它页面）；
        // 表头、分隔线、错误行各自补 24 右边距，滚动内容靠收窄自身宽度留白。
        anchors.leftMargin: Theme.space24
        anchors.topMargin: Theme.space24
        anchors.bottomMargin: Theme.space24
        anchors.rightMargin: 0
        spacing: Theme.space16

        RowLayout {
            Layout.fillWidth: true
            Layout.rightMargin: Theme.space24
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
                    // 副标题升级为周概览：日期区间 + 本周任务量与完成数，一眼读出这一周的负载。
                    text: {
                        var range = Qt.formatDate(root.weekStart, "M.d") + " – " + Qt.formatDate(root.dayDate(6), "M.d")
                        if (root.weekTasks.length === 0)
                            return range + " · 本周暂无任务"
                        return range + " · 本周 " + root.weekTasks.length + " 个任务 · 已完成 " + root.weekCompletedCount()
                    }
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
            Layout.rightMargin: Theme.space24
            Layout.preferredHeight: 1
            color: Theme.border
        }

        Label {
            Layout.fillWidth: true
            Layout.rightMargin: Theme.space24
            visible: root.loadError.length > 0
            text: root.loadError
            color: Theme.danger
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        ScrollView {
            id: weekScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            // 主题化竖向滚动条：细、暖色，悬停/按下转 accent，与其它滚动页面一致。
            ScrollBar.vertical: ScrollBar {
                id: weekVerticalScrollBar
                policy: ScrollBar.AsNeeded
                width: 8

                contentItem: Rectangle {
                    implicitWidth: 4
                    radius: Theme.radiusSm
                    color: weekVerticalScrollBar.pressed || weekVerticalScrollBar.hovered ? Theme.accent : Theme.border
                }

                background: Rectangle {
                    color: Theme.surface
                }
            }

            ColumnLayout {
                // 绑视口宽度而非内容隐含宽度：嵌套 RowLayout 会把内容隐含宽度压窄，
                // 直接用 ScrollView 的可用宽度才能让每天的 TaskItem 撑满整行；
                // 再减一个 space24 给右侧留白，使内容不顶到贴边的滚动条。
                width: Math.max(weekScroll.availableWidth - Theme.space24, 1)
                spacing: Theme.space12

                Repeater {
                    model: 7

                    // 一整天为一行：左侧星期脊柱 + 右侧正文。
                    // 正文随负载变形——空日子塌成一行、有任务的日子展开，行高因此不对称。
                    RowLayout {
                        id: dayRow

                        Layout.fillWidth: true
                        spacing: Theme.space12

                        property var dayTasks: root.tasksForDay(index)
                        property bool hasTasks: dayTasks.length > 0
                        property bool isToday: root.isTodayIndex(index)
                        property bool isWeekend: index >= 5

                        // —— 星期脊柱：领起一整天；今天用强调色高亮，周末底色略沉 ——
                        Rectangle {
                            Layout.preferredWidth: 52
                            Layout.fillHeight: true
                            radius: Theme.radiusMd
                            color: dayRow.isToday ? Theme.accent
                                   : (dayRow.isWeekend ? Theme.surfaceSunken : Theme.surfaceRaised)
                            border.color: dayRow.isToday ? Theme.accentStrong : Theme.border
                            border.width: 1

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 2

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: root.weekdayGlyphs[index]
                                    font.pixelSize: Theme.fontXl
                                    font.bold: true
                                    color: dayRow.isToday ? Theme.surface
                                           : (dayRow.isWeekend ? Theme.inkSoft : Theme.ink)
                                }

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    // 等宽字体让日期数字像计时器/账本，强化“按日推进”的节奏。
                                    text: Qt.formatDate(root.dayDate(index), "M/d")
                                    font.family: "Menlo"
                                    font.pixelSize: Theme.fontXs
                                    color: dayRow.isToday ? Theme.surface : Theme.inkSoft
                                }

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: dayRow.isToday
                                    text: "今天"
                                    font.pixelSize: 9
                                    font.letterSpacing: 1
                                    color: Theme.surface
                                }
                            }
                        }

                        // —— 空日子：塌成一行，安静地给出添加入口 ——
                        Rectangle {
                            visible: !dayRow.hasTasks
                            Layout.fillWidth: true
                            Layout.preferredHeight: 48
                            radius: Theme.radiusMd
                            color: Theme.surfaceRaised
                            border.color: Theme.borderSubtle
                            border.width: 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.space12
                                anchors.rightMargin: Theme.space8
                                spacing: Theme.space8

                                Text {
                                    Layout.fillWidth: true
                                    text: "暂无任务"
                                    font.pixelSize: Theme.fontMd
                                    color: Theme.inkMuted
                                }

                                Button {
                                    id: emptyAddButton
                                    text: "+ 添加"
                                    implicitWidth: 72
                                    implicitHeight: 32

                                    // 空日子用次级描边的添加，保持安静；强调色只留给有活动的日子。
                                    background: Rectangle {
                                        color: emptyAddButton.pressed ? Theme.borderSubtle : (emptyAddButton.hovered ? Theme.surfaceSunken : Theme.surface)
                                        border.color: emptyAddButton.hovered || emptyAddButton.pressed ? Theme.accent : Theme.border
                                        border.width: 1
                                        radius: Theme.radiusMd

                                        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                                        Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                                    }

                                    contentItem: Text {
                                        text: emptyAddButton.text
                                        color: Theme.inkSoft
                                        font.pixelSize: Theme.fontSm
                                        font.weight: Font.Medium
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }

                                    onClicked: root.openAddTaskForDay(index)
                                }
                            }
                        }

                        // —— 有任务的日子：展开任务列表 + 强调填充的添加 ——
                        ColumnLayout {
                            visible: dayRow.hasTasks
                            Layout.fillWidth: true
                            spacing: Theme.space8

                            Repeater {
                                model: dayRow.dayTasks

                                TaskItem {
                                    Layout.fillWidth: true
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

                            RowLayout {
                                Layout.fillWidth: true

                                Item { Layout.fillWidth: true }

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
