pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import ".."
import "../LogicalDay.js" as LogicalDay
import "../Duration.js" as Duration

Item {
    id: root

    signal startFocus(int taskId, string taskTitle)
    signal deleteRequested(int taskId, string title)
    // 完成任务后向上冒泡，供 MainWindow 弹出“撤销完成”提示条。
    signal taskCompletionUndoable(int taskId, string title)

    property date weekStart: mondayOf(new Date())
    // logicalToday 是命令式快照。若写成绑定，设置变化会在 changed 槽保存 prev 前提前重算，
    // 导致“是否正在浏览当前周”的判断失真。
    property date logicalToday
    property var logicalNowProvider: null
    property var weekTasks: []
    // 上下文属性只在 main.qml 解包，视图内部一律消费显式引用。
    property var taskManagerRef: null
    property var logicalDayServiceRef: null
    property var settingsRef: null
    property var categoryManagerRef: null
    property int pendingDeleteTaskId: -1
    property string loadError: ""
    // 拖动改期：拖动期间只记"悬停在哪一天"，松手才落库。
    // 编辑弹窗此前只有今天/明天/后天三个按钮，最远只能挪两天；整块前后挪一周做不到。
    property int draggingTaskId: -1
    property int dropTargetIndex: -1
    readonly property bool canMoveTasks: !!root.taskManagerRef
                                         && typeof root.taskManagerRef.moveTaskToDate === "function"

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
        refreshCoalescer.cancel()
        if (root.pageActive)
            root.refresh()
    }
    onPendingDeleteTaskIdChanged: {
        if (root.pageActive)
            refresh()
    }

    Connections {
        target: root.taskManagerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onTasksChanged() {
            if (root.completionRefreshDelayActive)
                return
            refreshCoalescer.request()
        }

        function onOperationFailed(message) {
            root.loadError = String(message || "本周计划加载失败")
        }
    }

    RefreshCoalescer {
        id: refreshCoalescer

        active: root.pageActive
        onTriggered: root.refresh()
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
        target: root.logicalDayServiceRef
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
        var hour = root.settingsRef ? root.settingsRef.dayStartHour : 4
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

    function beginDrag(taskId) {
        root.draggingTaskId = taskId
        root.dropTargetIndex = -1
    }

    // 场景坐标 → 落在哪一天。逐个问每一行自己的场景矩形，而不是按行高等分：
    // 每天的任务条数不同，行高本来就不相等。
    function updateDrag(sceneY) {
        if (root.draggingTaskId < 0) {
            return
        }
        for (var i = 0; i < 7; ++i) {
            var row = root.dayRowAt(i)
            if (!row) {
                continue
            }
            var top = row.mapToItem(null, 0, 0).y
            if (sceneY >= top && sceneY <= top + row.height) {
                root.dropTargetIndex = i
                return
            }
        }
        root.dropTargetIndex = -1
    }

    function dayRowAt(index) {
        for (var i = 0; i < weekScroll.count; ++i) {
            var item = weekScroll.itemAtIndex(i)
            // itemAtIndex 静态返回 QQuickItem，运行时对象是带 index 属性的 delegate。
            // qmllint disable missing-property
            if (item && item.index === index) {
                return item
            }
            // qmllint enable missing-property
        }
        return null
    }

    function commitDrag(taskId, currentIndex, cancelled) {
        const target = root.dropTargetIndex
        root.draggingTaskId = -1
        root.dropTargetIndex = -1
        // 拖回原来那天不算改期：白写一次库还会把它挪到当天末尾。
        if (cancelled === true || !root.canMoveTasks
                || target < 0 || target === currentIndex) {
            return
        }
        if (!root.taskManagerRef.moveTaskToDate(taskId, root.isoDate(root.dayDate(target)))) {
            root.loadError = "任务改期失败，请重试"
            return
        }
        // 成功路径由 TaskManager.tasksChanged 统一触发刷新；这里再查一次会同步重建两轮 delegate。
    }

    function tasksForDay(index) {
        // weekTasks 一次性加载，按列在前端过滤，避免每个日期重复查库。
        //
        // 已完成的沉到这一天的末尾，与今日任务页的排序口径对齐——此前周计划页
        // 不做这一步，做完的两条会占满行高排在最前，得先滑过它们才看到没做的那条。
        //
        // 用两趟稳定分区而不是 sort：要求是「同一完成状态内保持原有顺序」
        // （服务层已按 display_order、创建时间、编号排好），
        // 而 sort 的比较函数一旦写成返回 0 之外的值就会悄悄改变同组内的相对位置。
        var target = root.isoDate(root.dayDate(index))
        var pending = []
        var done = []
        for (var i = 0; i < root.weekTasks.length; i++) {
            var task = root.weekTasks[i]
            if (Qt.formatDate(task.date, "yyyy-MM-dd") !== target) {
                continue
            }
            if (task.completed) {
                done.push(task)
            } else {
                pending.push(task)
            }
        }
        return pending.concat(done)
    }

    // 这一天排了多少活：当天全部任务的预计用时之和，完成与否都算——
    // 问的是「排了多少」，与今日任务页 plannedMinutesToday 同一口径。
    function plannedMinutesForDay(index) {
        var tasks = root.tasksForDay(index)
        var sum = 0
        for (var i = 0; i < tasks.length; i++) {
            sum += Math.max(0, Number(tasks[i].estimatedMinutes || 0))
        }
        return sum
    }

    function plannedMinutesForWeek() {
        var sum = 0
        for (var i = 0; i < root.weekTasks.length; i++) {
            sum += Math.max(0, Number(root.weekTasks[i].estimatedMinutes || 0))
        }
        return sum
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


    // —— 键盘导航 ——
    //
    // 外层 ListView 的 model 是 7（一项一天），任务在内层 Repeater 里，
    // 所以 ListView.currentIndex 选中的是**天**不是任务，不能直接拿来当游标。
    //
    // 游标记的是**任务编号**而不是下标：下标在任务增删、以及完成后沉底重排之后
    // 指向的就是另一条任务了。按编号记，完成一条之后焦点自然跟着它挪到当天末尾。
    property int cursorTaskId: -1

    // 全周按「天序 + 天内序」摊平后的任务编号。空日子不产生任何条目，
    // 因此 ↑↓ 天然跳过它们，不需要另写判断。
    readonly property var flatTaskIds: {
        var ids = []
        for (var d = 0; d < 7; ++d) {
            var dayTasks = root.tasksForDay(d)
            for (var i = 0; i < dayTasks.length; ++i) {
                ids.push(Number(dayTasks[i].id))
            }
        }
        return ids
    }

    function dayIndexOfTask(taskId) {
        for (var d = 0; d < 7; ++d) {
            var dayTasks = root.tasksForDay(d)
            for (var i = 0; i < dayTasks.length; ++i) {
                if (Number(dayTasks[i].id) === Number(taskId)) {
                    return d
                }
            }
        }
        return -1
    }

    function taskById(taskId) {
        for (var i = 0; i < root.weekTasks.length; ++i) {
            if (Number(root.weekTasks[i].id) === Number(taskId)) {
                return root.weekTasks[i]
            }
        }
        return null
    }

    function setCursor(taskId) {
        root.cursorTaskId = Number(taskId)
        if (root.cursorTaskId <= 0) {
            return
        }
        // 游标移出可视区就把它滚进来。外层是虚拟化列表（cacheBuffer 有限），
        // 屏幕外的 delegate 根本没被创建，不能靠累加 delegate 高度定位；
        // positionViewAtIndex 按天索引工作，不受未创建行影响。
        var dayIndex = root.dayIndexOfTask(root.cursorTaskId)
        if (dayIndex < 0) {
            return
        }
        weekScroll.positionViewAtIndex(dayIndex, ListView.Contain)
        // 只按天定位不够：一天比视口高时 Contain 会把这一天顶到视口上沿，
        // 当天靠后的任务仍在视口外（12 条的一天，第 12 条落在 562px 视口的 957px 处）。
        // 这一天的 delegate 此刻已被创建，再按任务行在内容坐标里的位置补一段日内偏移。
        root.scrollTaskRowIntoView(weekScroll.itemAtIndex(dayIndex), root.cursorTaskId)
    }

    function taskRowInDay(dayItem, taskId) {
        var stack = [dayItem]
        while (stack.length > 0) {
            var item = stack.pop()
            if (item && item.taskTitle !== undefined && Number(item.taskId) === Number(taskId)) {
                return item
            }
            var kids = item ? item.children : []
            for (var i = 0; i < kids.length; ++i) {
                stack.push(kids[i])
            }
        }
        return null
    }

    // 只需往下补：Contain 之后，比视口高的一天上沿贴着视口上沿，比视口矮的一天整个在视口内，
    // 所以任务行不会落到视口上沿之外，只可能压出下沿。
    function scrollTaskRowIntoView(dayItem, taskId) {
        var row = dayItem ? root.taskRowInDay(dayItem, taskId) : null
        if (!row) {
            return
        }
        var bottom = row.mapToItem(weekScroll.contentItem, 0, 0).y + row.height
        if (bottom > weekScroll.contentY + weekScroll.height) {
            weekScroll.contentY = bottom - weekScroll.height
        }
    }

    // delta 为正向下、为负向上。到头就停，不循环——
    // 一路按下去从周日绕回周一会让人彻底失去「我在这周的哪里」的位置感。
    function moveCursor(delta) {
        var ids = root.flatTaskIds
        if (ids.length === 0) {
            root.cursorTaskId = -1
            return
        }
        var index = ids.indexOf(root.cursorTaskId)
        if (index < 0) {
            root.setCursor(delta >= 0 ? ids[0] : ids[ids.length - 1])
            return
        }
        var next = index + delta
        if (next < 0 || next >= ids.length) {
            return
        }
        root.setCursor(ids[next])
    }

    // 删掉 taskId 之后游标该落在哪。逐级尝试，取第一个命中的：
    //   当天后继 → 当天前驱 → 后续非空日首条 → 前序非空日末条 → 清空。
    // 中间两级最容易漏：删掉当天最后一条但当天还有前序任务时应落到前驱（而不是跳去别的一天），
    // 删掉全周最后一条但前几天还有任务时应落到前序非空日末条（而不是直接清空）。
    function cursorLandingAfterRemoving(taskId) {
        var dayIndex = root.dayIndexOfTask(taskId)
        if (dayIndex < 0) {
            return -1
        }
        var dayTasks = root.tasksForDay(dayIndex)
        var within = -1
        for (var i = 0; i < dayTasks.length; ++i) {
            if (Number(dayTasks[i].id) === Number(taskId)) {
                within = i
                break
            }
        }
        if (within < 0) {
            return -1
        }
        if (within + 1 < dayTasks.length) {
            return Number(dayTasks[within + 1].id)
        }
        if (within > 0) {
            return Number(dayTasks[within - 1].id)
        }
        for (var later = dayIndex + 1; later < 7; ++later) {
            var laterTasks = root.tasksForDay(later)
            if (laterTasks.length > 0) {
                return Number(laterTasks[0].id)
            }
        }
        for (var earlier = dayIndex - 1; earlier >= 0; --earlier) {
            var earlierTasks = root.tasksForDay(earlier)
            if (earlierTasks.length > 0) {
                return Number(earlierTasks[earlierTasks.length - 1].id)
            }
        }
        return -1
    }

    // 空格：完成 / 取消完成当前游标那条。游标按编号记，因此完成后它沉到当天末尾时焦点跟着走。
    function toggleCursorCompletion() {
        var task = root.taskById(root.cursorTaskId)
        if (!task) {
            return false
        }
        root.setTaskCompletedWithAnimationDelay(Number(task.id), !task.completed, String(task.title || ""))
        return true
    }

    // 回车：从游标那条开始专注。可不可以启动只由 canStartFocusFor 决定，
    // 行内「开始」按钮读的是同一个函数——此前两边各写一份，回车漏判了已完成。
    function startCursorFocus() {
        if (!root.canStartFocusFor(root.cursorTaskId)) {
            return false
        }
        var task = root.taskById(root.cursorTaskId)
        root.startFocus(Number(task.id), String(task.title || ""))
        return true
    }

    // 完成后到列表重载之间（完成动画要播完，重载推迟约 850ms），模型里的 completed 还是旧值，
    // 行内按钮却已随完成态隐藏。这里记下用户刚改过的完成态，重载后清空。
    property var completionOverrides: ({})

    function effectiveCompleted(task) {
        var id = Number(task.id)
        return root.completionOverrides[id] !== undefined
                ? Boolean(root.completionOverrides[id]) : Boolean(task.completed)
    }

    // 本周页「能不能从这条开始专注」的唯一口径：键盘回车与行内「开始」按钮共用。
    // 只有今天那一行、且没完成的任务可以。
    function canStartFocusFor(taskId) {
        var task = root.taskById(taskId)
        if (!task) {
            return false
        }
        return root.isTodayIndex(root.dayIndexOfTask(taskId)) && !root.effectiveCompleted(task)
    }

    // —— 键盘入口 ——
    //
    // 列表的 focus: true 只在所在焦点域拿到焦点时才生效。鼠标点侧栏切页时，
    // 侧栏条目会把焦点留在自己身上（见 Sidebar.qml），于是 ↑↓ 等按键全部落空，
    // 点任务行也拿不回来——此前的用例都直接调 moveCursor，从没发过真实按键。
    // 进入本页、或点了任务行，都把键盘入口交给列表。

    function isTextInputItem(item) {
        // 与 MainWindow.isTextInputItem 同一套鸭子类型：TextInput / TextEdit 系独有的两个属性。
        return !!item
                && typeof item.selectedText !== "undefined"
                && typeof item.inputMethodComposing !== "undefined"
    }

    function itemInsideOverlay(item) {
        var overlay = root.Overlay.overlay
        var current = item
        while (overlay && current) {
            if (current === overlay)
                return true
            current = current.parent
        }
        return false
    }

    function currentFocusItem() {
        return root.Window.window ? root.Window.window.activeFocusItem : null
    }

    // 页面可见且激活时才交接；输入框正在编辑、或弹窗占着焦点时不抢。
    readonly property bool keyboardEntryReady: root.pageActive && root.visible

    onKeyboardEntryReadyChanged: {
        if (root.keyboardEntryReady)
            Qt.callLater(root.takeKeyboardEntry)
    }

    function takeKeyboardEntry() {
        if (!root.keyboardEntryReady)
            return
        var current = root.currentFocusItem()
        if (root.isTextInputItem(current) || root.itemInsideOverlay(current))
            return
        weekScroll.forceActiveFocus(Qt.OtherFocusReason)
    }

    // 点任务行：游标落到这一行，键盘入口交给列表，接着 ↑↓ 从这里继续。
    // 双击标题进入改名时，输入框已经拿到焦点，这里不能再抢回来。
    function focusListOnTask(taskId) {
        if (root.isTextInputItem(root.currentFocusItem()))
            return
        root.setCursor(taskId)
        weekScroll.forceActiveFocus(Qt.MouseFocusReason)
    }

    function editCursorTask() {
        var task = root.taskById(root.cursorTaskId)
        if (!task) {
            return false
        }
        editTaskDialog.openForTask(task)
        return true
    }

    // 删除：落点必须在发出请求**之前**算好。请求一发出宿主就会把这一行从模型里藏起来，
    // 那时再算，当前行已经不在 tasksForDay 里了，落点会退化成"找不到"。
    function deleteCursorTask() {
        var task = root.taskById(root.cursorTaskId)
        if (!task) {
            return false
        }
        var landing = root.cursorLandingAfterRemoving(Number(task.id))
        root.deleteRequested(Number(task.id), String(task.title || ""))
        root.cursorTaskId = landing
        return true
    }

    // 刷新后按编号恢复游标：任务增删之后同一个下标指向的是另一条任务。
    // 目标任务已经不在了（被删掉、改期到别的周）就清空，不要留一个指向空气的游标。
    function restoreCursorAfterRefresh() {
        if (root.cursorTaskId > 0 && root.flatTaskIds.indexOf(root.cursorTaskId) < 0) {
            root.cursorTaskId = -1
        }
    }

    function refresh() {
        try {
            root.loadError = ""
            var loaded = root.taskManagerRef.getWeekTasks(root.isoDate(root.weekStart))
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
        // 模型已经是数据库里的最新值，完成态覆盖不再需要。
        root.completionOverrides = ({})
        root.restoreCursorAfterRefresh()
    }

    function setTaskCompletedWithAnimationDelay(id, completed, title) {
        var overrides = Object.assign({}, root.completionOverrides)
        overrides[Number(id)] = Boolean(completed)
        root.completionOverrides = overrides
        if (completed) {
            // 完成动画依附在当前 TaskItem delegate 上；TaskManager 会同步发 tasksChanged，
            // 如果立即刷新 Repeater，delegate 会被销毁，粒子动画看不到结束。
            root.completionRefreshDelayActive = true
            completionRefreshTimer.restart()
        }

        var ok = root.taskManagerRef.setTaskCompleted(id, completed)
        if (!ok) {
            completionRefreshTimer.stop()
            root.completionRefreshDelayActive = false
            // 失败时当前 delegate 已经被 TaskItem 乐观切到完成态；先清空模型强制销毁它，
            // 再从数据源重载，避免界面停在“已完成”的假状态。
            root.weekTasks = []
            root.refresh()
            root.loadError = completed ? "任务完成失败，请重试" : "取消完成失败，请重试"
            return
        }
        if (completed) {
            root.taskCompletionUndoable(id, String(title || ""))
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
                    objectName: "weekSummaryText"
                    // 副标题升级为周概览：日期区间 + 本周任务量与完成数，一眼读出这一周的负载。
                    text: {
                        var range = Qt.formatDate(root.weekStart, "M.d") + " – " + Qt.formatDate(root.dayDate(6), "M.d")
                        if (root.weekTasks.length === 0)
                            return range + " · 本周暂无任务"
                        // 只数条目个数答不了排期页最该回答的那个问题——这一周到底排了多少小时。
                        // 每条的预计用时本来就画在行里，缺的只是一个加法。
                        return range + " · 本周 " + root.weekTasks.length + " 个任务 · 已完成 "
                                + root.weekCompletedCount() + " · 共排 "
                                + Duration.format(root.plannedMinutesForWeek())
                    }
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                }
            }

            Button {
                id: prevWeekButton
                text: "上一周"
                implicitWidth: 84
                implicitHeight: Theme.controlHeightMd

                // 次级暖色描边样式：低调、与卡片协调，避免满屏强调色块。
                background: Rectangle {
                    color: prevWeekButton.pressed ? Theme.glassHover : (prevWeekButton.hovered ? Theme.glassHover : Theme.glassCard)
                    border.color: prevWeekButton.hovered || prevWeekButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                    Behavior on border.color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                }

                contentItem: Text {
                    text: prevWeekButton.text
                    textFormat: Text.PlainText
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
                implicitHeight: Theme.controlHeightMd

                background: Rectangle {
                    color: thisWeekButton.pressed ? Theme.glassHover : (thisWeekButton.hovered ? Theme.glassHover : Theme.glassCard)
                    border.color: thisWeekButton.hovered || thisWeekButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                    Behavior on border.color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                }

                contentItem: Text {
                    text: thisWeekButton.text
                    textFormat: Text.PlainText
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
                implicitHeight: Theme.controlHeightMd

                background: Rectangle {
                    color: nextWeekButton.pressed ? Theme.glassHover : (nextWeekButton.hovered ? Theme.glassHover : Theme.glassCard)
                    border.color: nextWeekButton.hovered || nextWeekButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                    Behavior on border.color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                }

                contentItem: Text {
                    text: nextWeekButton.text
                    textFormat: Text.PlainText
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
            textFormat: Text.PlainText
            color: Theme.danger
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        ListView {
            id: weekScroll
            objectName: "weekScroll"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: 7

            // 键盘导航的接收点。列表本身可聚焦，Tab 能进来。
            focus: true
            activeFocusOnTab: true
            Accessible.role: Accessible.List
            Accessible.name: qsTr("本周任务列表")

            // 内联重命名的输入框在 delegate 里，它拿到焦点时会自己消费按键，
            // 事件不会冒到这里，所以无修饰键的空格与 E 天然让路。
            // 拖动中不接受键盘操作：此时模型正被按住不动，改游标只会和落点算不到一起。
            Keys.onPressed: function (event) {
                if (root.draggingTaskId > 0) {
                    return
                }
                switch (event.key) {
                case Qt.Key_Down:
                    root.moveCursor(1)
                    event.accepted = true
                    return
                case Qt.Key_Up:
                    root.moveCursor(-1)
                    event.accepted = true
                    return
                case Qt.Key_Space:
                    event.accepted = root.toggleCursorCompletion()
                    return
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    event.accepted = root.startCursorFocus()
                    return
                case Qt.Key_E:
                    if (event.modifiers === Qt.NoModifier) {
                        event.accepted = root.editCursorTask()
                    }
                    return
                case Qt.Key_Backspace:
                case Qt.Key_Delete:
                    // macOS 笔记本主键盘上写着 delete 的那颗发的是 Backspace，
                    // 只认 Key_Delete 等于这条通路在本应用的唯一目标平台上不存在。
                    if (event.modifiers & Qt.ControlModifier) {
                        event.accepted = root.deleteCursorTask()
                    }
                    return
                default:
                    return
                }
            }
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
                            color: dayRow.isToday ? Theme.accentFill : Theme.glassCard
                            border.color: dayRow.isToday ? Theme.accentStrong : Theme.border
                            border.width: 1

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 2

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: root.weekdayGlyphs[dayRow.index]
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontXl
                                    font.bold: true
                                    // 「今天」徽章底已从实心焦糖换成淡罩，近白的 surface 会消失，
                                    // 改用罩上专用的深焦糖字。
                                    color: dayRow.isToday ? Theme.accentFillInk
                                           : (dayRow.isWeekend ? Theme.inkSoft : Theme.ink)
                                }

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    // 日期数字走全应用统一的计时数字字体，与侧栏计时同一张脸。
                                    text: Qt.formatDate(root.dayDate(dayRow.index), "M/d")
                                    textFormat: Text.PlainText
                                    font.family: Theme.fontFamilyClock
                                    font.pixelSize: Theme.fontXs
                                    color: dayRow.isToday ? Theme.accentFillInk : Theme.inkSoft
                                }

                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: dayRow.isToday
                                    text: "今天"
                                    font.pixelSize: 9
                                    font.letterSpacing: 1
                                    color: Theme.accentFillInk
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

                                Button {
                                    id: emptyAddButton

                                    objectName: "weekEmptyAddButton-" + dayRow.index
                                    text: "+ 添加"
                                    visible: dayRow.canAddTask
                                    enabled: dayRow.canAddTask
                                    implicitWidth: 72
                                    implicitHeight: Theme.controlHeightMd

                                    // 空日子用次级描边的添加，保持安静；强调色只留给有活动的日子。
                                    background: Rectangle {
                                        color: !emptyAddButton.enabled ? Theme.surfaceSunken
                                               : (emptyAddButton.pressed ? Theme.glassHover : (emptyAddButton.hovered ? Theme.glassHover : Theme.glassCard))
                                        border.color: emptyAddButton.enabled && (emptyAddButton.hovered || emptyAddButton.pressed) ? Theme.accent : Theme.border
                                        border.width: 1
                                        radius: Theme.radiusMd

                                        Behavior on color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                                        Behavior on border.color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                                    }

                                    contentItem: Text {
                                        text: emptyAddButton.text
                                        textFormat: Text.PlainText
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
                                    id: weekTaskRow

                                    // pragma ComponentBehavior: Bound 之后 delegate 不再继承
                                    // 外层作用域，必须显式声明消费的模型角色。
                                    required property var modelData

                                    Layout.fillWidth: true
                                    taskId: weekTaskRow.modelData.id
                                    taskTitle: weekTaskRow.modelData.title
                                    taskCategory: weekTaskRow.modelData.category && weekTaskRow.modelData.category.name
                                                  ? weekTaskRow.modelData.category
                                                  : (weekTaskRow.modelData.categoryData && weekTaskRow.modelData.categoryData.name
                                                     ? weekTaskRow.modelData.categoryData
                                                     : (weekTaskRow.modelData.categoryText || ""))
                                    taskCompleted: weekTaskRow.modelData.completed
                                    estimatedMinutes: Number(weekTaskRow.modelData.estimatedMinutes || 0)
                                    taskNotes: String(weekTaskRow.modelData.notes || "")
                                    focusedMinutes: Number(weekTaskRow.modelData.focusedMinutes || 0)
                                    startFocusAllowed: dayRow.isToday
                                    showStartFocus: root.canStartFocusFor(weekTaskRow.taskId)
                                    keyboardFocused: root.cursorTaskId === weekTaskRow.taskId
                                    draggable: root.canMoveTasks && !weekTaskRow.modelData.completed
                                    opacity: root.draggingTaskId === weekTaskRow.taskId ? 0.6 : 1

                                    onDragStarted: root.beginDrag(weekTaskRow.taskId)
                                    onDragMoved: function (sceneX, sceneY) { root.updateDrag(sceneY) }
                                    onDragFinished: function (cancelled) {
                                        root.commitDrag(weekTaskRow.taskId,
                                                        dayRow.index,
                                                        cancelled)
                                    }

                                    onCompletionChanged: function(id, completed) {
                                        root.setTaskCompletedWithAnimationDelay(id, completed, weekTaskRow.modelData.title)
                                    }

                                    onStartFocusClicked: function(id, title) {
                                        if (root.canStartFocusFor(id))
                                            root.startFocus(id, title)
                                    }

                                    // 点行把键盘入口交给列表。挂在本页的实例上，不改 TaskItem 本身——
                                    // 今日任务页也用它，而那一页本轮不动。
                                    TapHandler {
                                        acceptedButtons: Qt.LeftButton
                                        onTapped: root.focusListOnTask(weekTaskRow.taskId)
                                    }

                                    onDeleteClicked: function(id, title) {
                                        root.deleteRequested(id, title)
                                    }

                                    renameSubmitter: function(id, newTitle) {
                                        var originalCategoryId = Number(weekTaskRow.modelData.categoryId || -1)
                                        var originalDate = root.taskIsoDate(weekTaskRow.modelData.date)
                                        var succeeded = Boolean(root.taskManagerRef.updateTask(
                                            id, newTitle, originalCategoryId, originalDate))
                                        if (!succeeded) {
                                            root.loadError = "任务更新失败，请重试"
                                        }
                                        return succeeded
                                    }

                                    onEditClicked: function(id) {
                                        editTaskDialog.openForTask(weekTaskRow.modelData)
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true

                                Text {
                                    objectName: "weekDayPlannedTotal-" + dayRow.index

                                    // 这一天排了多少。排期页最该回答的就是这个，
                                    // 而此前整页一个分钟数都没有，只能靠数条目个数猜。
                                    readonly property int plannedMinutes: root.plannedMinutesForDay(dayRow.index)
                                    // 一条都没排时间的日子不显示「0 分钟」——那不是信息，是噪音。
                                    // 单独暴露成属性：测试断言它，而不是断言会沿父链级联的 visible。
                                    readonly property bool showsTotal: plannedMinutes > 0

                                    Layout.alignment: Qt.AlignVCenter
                                    visible: showsTotal
                                    text: qsTr("已排 %1").arg(Duration.format(plannedMinutes))
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSm
                                    color: Theme.inkSoft
                                }

                                Item { Layout.fillWidth: true }

                                Button {
                                    id: addDayButton

                                    objectName: "weekAddButton-" + dayRow.index
                                    text: "添加"
                                    visible: dayRow.canAddTask
                                    enabled: dayRow.canAddTask
                                    implicitWidth: 72
                                    implicitHeight: Theme.controlHeightMd

                                    // 主强调填充，与今日任务页的「添加」按钮保持一致。
                                    background: Rectangle {
                                        color: !addDayButton.enabled ? Theme.border
                                               : (addDayButton.pressed || addDayButton.hovered ? Theme.accentStrong : Theme.accent)
                                        border.color: addDayButton.enabled && addDayButton.hovered ? Theme.accentStrong : "transparent"
                                        border.width: addDayButton.enabled && addDayButton.hovered ? 1 : 0
                                        radius: Theme.radiusMd

                                        Behavior on color { ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad } }
                                    }

                                    contentItem: Text {
                                        text: addDayButton.text
                                        textFormat: Text.PlainText
                                        // 底是实心 accent：近白字只有 2.20:1，
                                        // 必须用为此定义的固定深色前景。禁用态维持 inkMuted。
                                        color: addDayButton.enabled ? Theme.accentForeground : Theme.inkMuted
                                        font.pixelSize: Theme.fontMd
                                        font.weight: Font.Medium
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        scale: addDayButton.pressed ? 0.96 : 1.0

                                        Behavior on scale { NumberAnimation { duration: Theme.reduceMotion ? 0 : 90; easing.type: Easing.OutQuad } }
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
        taskSubmitter: function (title, date, categoryId, estimatedMinutes, notes) {
            return root.taskManagerRef.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), Number(categoryId), Number(estimatedMinutes), String(notes || ""))
        }
    }

    EditTaskDialog {
        id: editTaskDialog

        parent: root
        categoryManagerRef: root.categoryManagerRef

        taskSubmitter: function (taskId, title, categoryId, isoDate, estimatedMinutes, notes) {
            var succeeded = Boolean(root.taskManagerRef.updateTask(
                taskId, title, categoryId, isoDate, Number(estimatedMinutes), String(notes || "")))
            if (!succeeded) {
                root.loadError = "任务更新失败，请重试"
            }
            return succeeded
        }
    }
}
