import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import ".."
import "../LogicalDay.js" as LogicalDay

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)
    signal deleteRequested(int taskId, string title)

    property date weekStart: mondayOf(new Date())
    // logicalToday 是命令式快照。若写成绑定，设置变化会在 changed 槽保存 prev 前提前重算，
    // 导致“是否正在浏览当前周”的判断失真。
    property date logicalToday
    property var logicalNowProvider: null
    property var weekTasks: []
    property var categoryManagerRef: null
    property int pendingDeleteTaskId: -1
    property string loadError: ""
    property date pendingAddDate: new Date()
    property bool completionRefreshDelayActive: false
    property bool pageActive: true

    // 周一起点对应的星期字，索引 0~6 = 周一~周日。
    readonly property var weekdayGlyphs: ["一", "二", "三", "四", "五", "六", "日"]

    Component.onCompleted: {
        root.logicalToday = root.computeLogicalToday()
        root.weekStart = root.mondayOf(root.logicalToday)
        if (root.pageActive)
            root.refresh()
    }
    onPageActiveChanged: {
        if (root.pageActive)
            root.refresh()
    }
    onPendingDeleteTaskIdChanged: {
        if (root.pageActive)
            refresh()
    }

    Connections {
        target: taskManager
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onTasksChanged() {
            if (root.completionRefreshDelayActive)
                return
            root.refresh()
        }

        function onOperationFailed(message) {
            root.loadError = String(message || "本周计划加载失败")
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
        enabled: root.pageActive

        function onCategoriesChanged() {
            root.refresh()
        }
    }

    Connections {
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            // 必须先基于旧 logicalToday 判断跟随关系，再读取新时间；顺序反转会把历史周误判为当前周。
            var previousLogicalToday = new Date(root.logicalToday)
            var wasFollowingCurrentWeek = root.isoDate(root.weekStart)
                    === root.isoDate(root.mondayOf(previousLogicalToday))
            var nextLogicalToday = root.computeLogicalToday()
            root.logicalToday = nextLogicalToday
            if (wasFollowingCurrentWeek)
                root.weekStart = root.mondayOf(nextLogicalToday)
            root.refresh()
        }
    }

    function computeLogicalToday() {
        // provider 仅用于稳定测试；生产默认读取真实本地时间。
        // qmllint disable use-proper-function
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint enable use-proper-function
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(hour, now)
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

    function taskIsoDate(value) {
        if (value instanceof Date) {
            return Qt.formatDate(value, "yyyy-MM-dd")
        }
        return String(value || "").substring(0, 10)
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
        // 比较命令式逻辑日快照，避免凌晨 0~日界点仍被标成物理新日。
        var d = root.dayDate(index)
        var today = new Date(root.logicalToday)
        return d.getFullYear() === today.getFullYear()
                && d.getMonth() === today.getMonth()
                && d.getDate() === today.getDate()
    }

    function isPastIndex(index) {
        var d = root.dayDate(index)
        d.setHours(0, 0, 0, 0)
        var today = new Date(root.logicalToday)
        today.setHours(0, 0, 0, 0)
        return d.getTime() < today.getTime()
    }

    function canAddTaskForIndex(index) {
        return !root.isPastIndex(index)
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
            var loaded = taskManager.getWeekTasks(root.isoDate(root.weekStart))
            // 待删除行先从周视图消失；撤销时 pendingDeleteTaskId 清空后刷新恢复。
            root.weekTasks = root.pendingDeleteTaskId > 0
                    ? loaded.filter(function(task) {
                        return Number(task.id) !== root.pendingDeleteTaskId
                    })
                    : loaded
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
        if (!root.canAddTaskForIndex(index))
            return

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
                    color: prevWeekButton.pressed ? Theme.glassHover : (prevWeekButton.hovered ? Theme.glassHover : Theme.glassCard)
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
                objectName: "weekThisWeekButton"
                text: "本周"
                implicitWidth: 72
                implicitHeight: 40

                background: Rectangle {
                    color: thisWeekButton.pressed ? Theme.glassHover : (thisWeekButton.hovered ? Theme.glassHover : Theme.glassCard)
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
                    root.weekStart = root.mondayOf(root.logicalToday)
                    root.refresh()
                }
            }

            Button {
                id: nextWeekButton
                text: "下一周"
                implicitWidth: 84
                implicitHeight: 40

                background: Rectangle {
                    color: nextWeekButton.pressed ? Theme.glassHover : (nextWeekButton.hovered ? Theme.glassHover : Theme.glassCard)
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

        ListView {
            id: weekScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: 7
            spacing: Theme.space12
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: 180
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
                    objectName: "weekScrollTrack"

                    // 主容器透明后轨道必须跟着透明，否则是一条压在壁纸上的白带。
                    color: "transparent"
                }
            }

            // 以“日”为虚拟化单位；屏幕外日期的任务组件不会常驻，避免整周任务一次性全部创建。
            delegate: RowLayout {
                        id: dayRow

                        required property int index

                        objectName: "weekDayRow-" + dayRow.index
                        width: Math.max(ListView.view.width - Theme.space24, 1)
                        height: implicitHeight
                        spacing: Theme.space12

                        property var dayTasks: root.tasksForDay(dayRow.index)
                        property bool hasTasks: dayTasks.length > 0
                        property bool isToday: root.isTodayIndex(dayRow.index)
                        property bool canAddTask: root.canAddTaskForIndex(dayRow.index)
                        property bool isWeekend: dayRow.index >= 5

                        // —— 星期脊柱：领起一整天；今天用强调色高亮，其余为透壁纸玻璃 ——
                        Rectangle {
                            Layout.preferredWidth: 52
                            Layout.fillHeight: true
                            radius: Theme.radiusMd
                            color: dayRow.isToday ? Theme.accent : Theme.glassCard
                            border.color: dayRow.isToday ? Theme.accentStrong : Theme.border
                            border.width: 1

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 2

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: root.weekdayGlyphs[dayRow.index]
                                    font.pixelSize: Theme.fontXl
                                    font.bold: true
                                    color: dayRow.isToday ? Theme.surface
                                           : (dayRow.isWeekend ? Theme.inkSoft : Theme.ink)
                                }

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    // 等宽字体让日期数字像计时器/账本，强化“按日推进”的节奏。
                                    text: Qt.formatDate(root.dayDate(dayRow.index), "M/d")
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
                            objectName: "weekEmptyDayCard"

                            visible: !dayRow.hasTasks
                            Layout.fillWidth: true
                            Layout.preferredHeight: 48
                            radius: Theme.radiusMd
                            // 占位应比内容更轻：玻璃占位 vs 暖纸内容卡是有意的材质层级。
                            color: Theme.glassCard
                            border.color: Theme.glassBorder
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

                                    objectName: "weekEmptyAddButton-" + dayRow.index
                                    text: "+ 添加"
                                    visible: dayRow.canAddTask
                                    enabled: dayRow.canAddTask
                                    implicitWidth: 72
                                    implicitHeight: 32

                                    // 空日子用次级描边的添加，保持安静；强调色只留给有活动的日子。
                                    background: Rectangle {
                                        color: !emptyAddButton.enabled ? Theme.surfaceSunken
                                               : (emptyAddButton.pressed ? Theme.glassHover : (emptyAddButton.hovered ? Theme.glassHover : Theme.glassCard))
                                        border.color: emptyAddButton.enabled && (emptyAddButton.hovered || emptyAddButton.pressed) ? Theme.accent : Theme.border
                                        border.width: 1
                                        radius: Theme.radiusMd

                                        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                                        Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                                    }

                                    contentItem: Text {
                                        text: emptyAddButton.text
                                        color: emptyAddButton.enabled ? Theme.inkSoft : Theme.inkMuted
                                        font.pixelSize: Theme.fontSm
                                        font.weight: Font.Medium
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }

                                    onClicked: root.openAddTaskForDay(dayRow.index)
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
                                    startFocusAllowed: dayRow.isToday
                                    showStartFocus: dayRow.isToday

                                    onCompletionChanged: function(id, completed) {
                                        root.setTaskCompletedWithAnimationDelay(id, completed)
                                    }

                                    onStartFocusClicked: function(id, title) {
                                        if (dayRow.isToday)
                                            root.startFocus(id, title)
                                    }

                                    onDeleteClicked: function(id, title) {
                                        root.deleteRequested(id, title)
                                    }

                                    onRenameSubmitted: function(id, newTitle) {
                                        var originalCategoryId = Number(modelData.categoryId || -1)
                                        var originalDate = root.taskIsoDate(modelData.date)
                                        if (!taskManager.updateTask(id, newTitle, originalCategoryId, originalDate)) {
                                            root.loadError = "任务更新失败，请重试"
                                        }
                                    }

                                    onEditClicked: function(id) {
                                        editTaskDialog.openForTask(modelData)
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true

                                Item { Layout.fillWidth: true }

                                Button {
                                    id: addDayButton

                                    objectName: "weekAddButton-" + dayRow.index
                                    text: "添加"
                                    visible: dayRow.canAddTask
                                    enabled: dayRow.canAddTask
                                    implicitWidth: 72
                                    implicitHeight: 36

                                    // 主强调填充，与今日任务页的「添加」按钮保持一致。
                                    background: Rectangle {
                                        color: !addDayButton.enabled ? Theme.border
                                               : (addDayButton.pressed || addDayButton.hovered ? Theme.accentStrong : Theme.accent)
                                        border.color: addDayButton.enabled && addDayButton.hovered ? Theme.accentStrong : "transparent"
                                        border.width: addDayButton.enabled && addDayButton.hovered ? 1 : 0
                                        radius: Theme.radiusMd

                                        Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
                                    }

                                    contentItem: Text {
                                        text: addDayButton.text
                                        color: addDayButton.enabled ? Theme.surface : Theme.inkMuted
                                        font.pixelSize: Theme.fontMd
                                        font.weight: Font.Medium
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        scale: addDayButton.pressed ? 0.96 : 1.0

                                        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                                    }

                                    onClicked: root.openAddTaskForDay(dayRow.index)
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
        taskSubmitter: function(title, date, categoryId) {
            return taskManager.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), Number(categoryId))
        }
    }

    EditTaskDialog {
        id: editTaskDialog

        parent: root
        categoryManagerRef: root.categoryManagerRef

        onTaskEdited: function(taskId, title, categoryId, isoDate) {
            if (!taskManager.updateTask(taskId, title, categoryId, isoDate)) {
                root.loadError = "任务更新失败，请重试"
            }
        }
    }
}
