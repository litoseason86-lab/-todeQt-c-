pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import "../components"
import ".."
import "../LogicalDay.js" as LogicalDay

Item {
    id: root

    // 新建任务对话框归本页所有；快捷键（⌘N）经 MainWindow 走这个入口，
    // 而不是从外面直接摸内部 id。
    function openAddTaskDialog() {
        addTaskDialog.open()
    }

    signal startFocus(int taskId, string taskTitle)
    // 入口只属于今日页；实际计时由 MainWindow 交给全局 FocusTimer，避免页面持有业务状态。
    signal manualRestRequested()
    signal manualRestPageRequested()
    signal countdownRequested()
    // 切到知识缺口清单页；页面自己不做路由。
    signal knowledgeGapsRequested()
    // 捕获成功后由 MainWindow 统一弹 Toast。
    signal knowledgeGapCaptured(string title)
    signal knowledgeGapsConverted(int count)
    signal deleteRequested(int taskId, string title)
    // 完成任务后向上冒泡，供 MainWindow 弹出“撤销完成”提示条。
    signal taskCompletionUndoable(int taskId, string title)

    property var tasks: []
    property var todayStats: ({
            totalDuration: 0,
            completedTasks: 0,
            totalTasks: 0,
            completionRate: 0
    })
    // 上下文属性只在 main.qml 解包，视图内部一律消费显式引用。
    // 裸名字依赖 QML 的动态作用域，视图对外部的真实依赖既看不出来也换不掉。
    property var taskManagerRef: null
    property var statisticsServiceRef: null
    property var routineManagerRef: null
    property var focusTimerRef: null
    property var logicalDayServiceRef: null
    property var categoryManagerRef: null
    property var countdownServiceRef: null
    property var knowledgeGapServiceRef: null
    property var settingsRef: null
    property var overdueTasks: []
    property bool rolloverBannerActive: false
    // 知识缺口提醒摘要。整份结果由服务算好，页面不自己比日期——
    // 「今天」的口径只能有一份，在 C++ 侧。
    property var knowledgeGapSummary: ({})
    readonly property int gapDueToday: Number(root.knowledgeGapSummary.dueToday || 0)
    readonly property int gapOverdue: Number(root.knowledgeGapSummary.overdue || 0)
    readonly property int gapOldestOverdueDays: Number(root.knowledgeGapSummary.oldestOverdueDays || 0)
    // 只在服务确认查询成功、且确实有到期条目时才提醒。读取失败时保持安静：
    // 一条内容为「0 条」的提醒条比没有提醒更让人困惑。
    readonly property bool knowledgeGapBannerActive: Boolean(root.knowledgeGapSummary.valid)
                                                     && (root.gapDueToday + root.gapOverdue) > 0
    property int pendingDeleteTaskId: -1
    property string loadError: ""
    property bool completionRefreshDelayActive: false
    property bool pageActive: true
    // 系统时间本身不是 QML 的可观察属性。把“当前时刻”保存成显式状态，
    // 由逻辑日服务和页面刷新推进，避免应用跨过日界点后实时统计仍使用旧日期。
    property var logicalNow: new Date()
    // 测试可注入固定时钟；生产环境为空时读取系统时间。
    property var nowProvider: null
    readonly property string logicalTodayIso: {
        var hour = root.settingsRef ? root.settingsRef.dayStartHour : 4
        return LogicalDay.todayIso(hour, root.logicalNow)
    }
    // 当日专注目标（分钟）；0 = 今天尚未设置。设置/修改只在本页发生。
    property int dailyFocusGoalMinutes: 0
    // 拖动排序。拖动期间**完全不动模型**，只记「要落在第几位」，松手才重排并落库。
    //
    // 早先的做法是每跨过一行就 slice/splice 出一个新数组赋给 model。那会让 ListView
    // 认成全新模型、整片重建 delegate；而 TaskItem 带 layer.enabled + MultiEffect 阴影，
    // 每次重建都是一个新 FBO 加一遍阴影 pass。实测单次跨行 10 条列表 0.87ms、
    // 60 条 2.13ms——还没超帧预算，但随总数线性恶化，且这是发生在交互手势中途的开销。
    // 现在拖动期间模型引用恒定不变，代价与列表长度无关。
    property int draggingTaskId: -1
    // 目标插入位（模型下标）。-1 表示当前没有有效落点。
    property int dropTargetIndex: -1
    readonly property int draggingFromIndex: {
        if (root.draggingTaskId < 0) {
            return -1
        }
        for (var i = 0; i < root.tasks.length; ++i) {
            if (Number(root.tasks[i].id) === root.draggingTaskId) {
                return i
            }
        }
        return -1
    }
    // dropTargetIndex 表示最终下标。源项向下移动时会落在目标行之后，
    // 向上移动时落在目标行之前；指示线必须和这条持久化语义完全一致。
    readonly property bool dropIndicatorAfterTarget: root.draggingFromIndex >= 0
                                                      && root.dropTargetIndex > root.draggingFromIndex
    readonly property real dropIndicatorContentY: {
        if (root.dropTargetIndex < 0 || root.dropTargetIndex === root.draggingFromIndex) {
            return -1
        }
        var targetItem = todayTaskList.itemAtIndex(root.dropTargetIndex)
        if (!targetItem) {
            return -1
        }
        var slotY = root.dropIndicatorAfterTarget
                ? targetItem.y + targetItem.height + todayTaskList.spacing / 2
                : targetItem.y - todayTaskList.spacing / 2
        // 列表容器本身也有离屏阴影图层。首行上方和末行下方不能越出它的纹理边界，
        // 否则逻辑上可见、实际渲染仍被裁掉；留 1px 让 2px 指示线完整落在内部。
        return Math.max(1, Math.min(todayTaskList.contentHeight - 1, slotY))
    }
    // 今天排了多少活（全部任务的预计用时之和，完成与否都算——问的是"排了多少"）。
    readonly property int plannedMinutesToday: {
        var sum = 0
        for (var i = 0; i < root.tasks.length; ++i) {
            sum += Math.max(0, Number(root.tasks[i].estimatedMinutes || 0))
        }
        return sum
    }
    // 昨天的目标分钟数：未设置态快捷 chip 的数据源（单键快照跨日后即昨天值）。
    property int yesterdayGoalMinutes: 0

    readonly property bool manualRestActive: !!root.focusTimerRef
                                            && Number(root.focusTimerRef.mode) === 2
                                            && Number(root.focusTimerRef.phase) === 3
    readonly property bool timerBusy: !!root.focusTimerRef
                                     && (Boolean(root.focusTimerRef.hasActiveSession)
                                         || Number(root.focusTimerRef.phase) !== 0)

    // 实时专注秒数统一口径（与仪表盘共用 FocusLiveSeconds，禁止各自拼接）。
    readonly property FocusLiveSeconds liveSecondsSource: FocusLiveSeconds {
        timerRef: root.focusTimerRef
        baseSeconds: Number(root.todayStats.totalDuration || 0)
        logicalDate: root.logicalTodayIso
    }

    Component.onCompleted: {
        if (root.pageActive)
            refresh()
    }
    onPageActiveChanged: {
        refreshCoalescer.cancel()
        if (root.pageActive)
            refresh()
    }
    onPendingDeleteTaskIdChanged: {
        // 待删除窗口会把一行从 UI 模型隐藏，但数据库里的完整集合仍包含它。
        // 立即清掉拖拽快照，避免松手把不完整数组提交给服务层。
        if (root.pendingDeleteTaskId > 0) {
            root.draggingTaskId = -1
            root.dropTargetIndex = -1
        }
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
        // 在别处记下或解决了缺口，今日页的提示条也要跟着变。
        target: root.knowledgeGapServiceRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onGapsChanged() {
            root.loadKnowledgeGapSummary()
        }
    }

    Connections {
        target: root.taskManagerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onTasksChanged() {
            if (root.completionRefreshDelayActive)
                return;
            refreshCoalescer.request();
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
            // 定时刷新已覆盖这一轮数据；取消排队失效，避免粒子结束后紧跟第二次重查。
            refreshCoalescer.cancel();
            root.refresh();
        }
    }

    RefreshCoalescer {
        id: refreshCoalescer

        active: root.pageActive
        onTriggered: root.refresh()
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onCategoriesChanged() {
            refreshCoalescer.request();
        }
    }

    Connections {
        target: root.focusTimerRef
        enabled: root.pageActive

        function onFocusCompleted(duration) {
            refreshCoalescer.request();
        }
    }

    Connections {
        target: root.statisticsServiceRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onOperationFailed(message) {
            root.loadError = String(message || "统计数据加载失败")
        }
    }

    Connections {
        target: root.routineManagerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onRoutinesChanged() {
            refreshCoalescer.request();
        }

        function onOperationFailed(message) {
            root.loadError = String(message || "每日例行生成失败")
        }
    }

    Connections {
        // 逻辑日失效后重新查询今日任务与结转。main.cpp 的直连会先补齐新日例行任务，
        // 因此这个视图槽只负责重载，不重复承担跨层调度职责。
        target: root.logicalDayServiceRef
        ignoreUnknownSignals: true

        function onChanged() {
            // 先推进日期状态，再安排数据重查。否则同一事件循环内开始的新会话
            // 会被 FocusLiveSeconds 用昨天的日期过滤掉，界面只剩已落库累计值。
            root.logicalNow = root.currentNow()
            refreshCoalescer.request()
        }
    }

    function currentNow() {
        // qmllint disable use-proper-function
        return root.nowProvider ? root.nowProvider() : new Date()
        // qmllint enable use-proper-function
    }

    function todayIsoDate() {
        return root.logicalTodayIso
    }

    function currentLogicalTodayDate() {
        var hour = root.settingsRef ? root.settingsRef.dayStartHour : 4
        return LogicalDay.todayDate(hour, root.logicalNow)
    }

    function yesterdayIsoDate() {
        var hour = root.settingsRef ? root.settingsRef.dayStartHour : 4
        var today = LogicalDay.todayDate(hour, root.logicalNow)
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
        if (!root.taskManagerRef || !root.taskManagerRef.getOverdueUncompletedTasks) {
            root.overdueTasks = [];
            root.rolloverBannerActive = false;
            return;
        }

        root.overdueTasks = root.taskManagerRef.getOverdueUncompletedTasks();
        var ignoredToday = root.settingsRef && root.settingsRef.rolloverIgnoredDate === root.todayIsoDate();
        root.rolloverBannerActive = root.overdueTasks.length > 0 && !ignoredToday;
    }

    function moveOverdueToToday() {
        var ids = [];
        for (var i = 0; i < root.overdueTasks.length; i++) {
            ids.push(Number(root.overdueTasks[i].id));
        }

        if (root.taskManagerRef && root.taskManagerRef.moveTasksToToday(ids)) {
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

    readonly property bool canReorderTasks: !!root.taskManagerRef
                                           && typeof root.taskManagerRef.reorderTasks === "function"
                                           && root.pendingDeleteTaskId <= 0

    function beginReorder(taskId) {
        if (!root.canReorderTasks) {
            return
        }
        for (var i = 0; i < root.tasks.length; ++i) {
            if (Number(root.tasks[i].id) === taskId && root.tasks[i].completed) {
                return
            }
        }
        root.draggingTaskId = taskId
        root.dropTargetIndex = -1
    }

    function updateReorder(taskId, listY) {
        if (root.draggingTaskId !== taskId || root.draggingFromIndex < 0) {
            return
        }
        // listY 是内容坐标；离开当前可见区域就撤销落点。若继续保留旧值，
        // 用户在列表外松手仍会按最后经过的那一行写库。
        if (listY < todayTaskList.contentY
                || listY >= todayTaskList.contentY + todayTaskList.height) {
            root.dropTargetIndex = -1
            return
        }
        // 用 ListView.indexAt 而不是逐个问 delegate 要高度再累加：长列表会虚拟化，
        // 屏幕外的 delegate 根本没被创建，累加法会把它们当成高度 0，
        // 滚动之后落点整体偏移（实测 60 条的列表滚到底，落点差 2 位）。
        // indexAt 按内容坐标工作，变高行与未创建行都不影响结果。
        var target = todayTaskList.indexAt(todayTaskList.width / 2, listY)
        // -1 表示落在行与行之间的间隙或列表之外，保持上一次的落点不动；
        // 拖动过程中很快就会命中下一行。
        if (target < 0) {
            return
        }
        // 完成项由查询固定在末尾，不能成为未完成任务的落点。把指针进入完成区
        // 解释为“未完成组末位”，这样指示线和最终可兑现的顺序保持一致。
        var firstCompletedIndex = root.tasks.length
        for (var i = 0; i < root.tasks.length; ++i) {
            if (root.tasks[i].completed) {
                firstCompletedIndex = i
                break
            }
        }
        if (firstCompletedIndex <= 0) {
            root.dropTargetIndex = -1
            return
        }
        target = Math.min(target, firstCompletedIndex - 1)
        root.dropTargetIndex = target
    }

    function commitReorder(cancelled) {
        const from = root.draggingFromIndex
        const target = root.dropTargetIndex
        root.draggingTaskId = -1
        root.dropTargetIndex = -1

        if (cancelled === true || !root.canReorderTasks
                || from < 0 || target < 0 || target === from) {
            return
        }

        var ids = []
        for (var i = 0; i < root.tasks.length; ++i) {
            ids.push(Number(root.tasks[i].id))
        }
        ids.splice(target, 0, ids.splice(from, 1)[0])
        if (!root.taskManagerRef.reorderTasks(root.todayIsoDate(), ids)) {
            root.loadError = "任务排序保存失败，请重试"
        }
    }

    function taskIsoDate(value) {
        if (value instanceof Date) {
            return Qt.formatDate(value, "yyyy-MM-dd");
        }
        return String(value || "").substring(0, 10);
    }

    function refresh() {
        // refresh 也是恢复、任务变更等入口的兜底。即使平台漏发日界通知，
        // 下一次刷新也会修正日期，不让错误状态一直活到应用重启。
        root.logicalNow = root.currentNow()
        // 每次刷新前先确保当天真实任务行已生成；跨午夜后只要页面触发刷新就会补上当天例行项。
        // materializeToday 幂等且不发 tasksChanged，避免 refresh 递归。
        if (root.routineManagerRef && root.routineManagerRef.materializeToday) {
            root.routineManagerRef.materializeToday();
        }

        // 任务和统计分开加载，避免统计失败拖垮任务列表。
        loadOverdueTasks();
        loadTasks();
        loadStats();
        loadDailyFocusGoal();
        loadKnowledgeGapSummary();
    }

    function loadKnowledgeGapSummary() {
        // 服务替身可能没有这个方法；先查可调用性，避免运行时 TypeError。
        if (!root.knowledgeGapServiceRef
                || typeof root.knowledgeGapServiceRef.getReminderSummary !== "function") {
            root.knowledgeGapSummary = ({})
            return
        }
        root.knowledgeGapSummary = root.knowledgeGapServiceRef.getReminderSummary()
    }

    // 把今天到期和已逾期的条目一次性变成今天的任务。逾期条目的日期保持原样不动——
    // 顺延会把「这条拖了多久」抹掉，而拖了多久正是判断该不该现在停下来处理它的依据。
    function convertDueGapsToTasks() {
        if (!root.knowledgeGapServiceRef
                || typeof root.knowledgeGapServiceRef.listGaps !== "function"
                || typeof root.knowledgeGapServiceRef.convertToTask !== "function") {
            root.loadError = "记录服务不可用"
            return
        }
        // -2 是 kFilterUnresolved：待处理和已安排都要，已解决的不用再做。
        var candidates = root.knowledgeGapServiceRef.listGaps(-2, 0, "", 0)
        var converted = 0
        for (var i = 0; i < candidates.length; ++i) {
            var gap = candidates[i]
            if (!gap.dueToday && !gap.overdue) {
                continue
            }
            if (Number(root.knowledgeGapServiceRef.convertToTask(gap.id, root.logicalTodayIso)) > 0) {
                converted += 1
            }
        }
        root.loadKnowledgeGapSummary()
        if (converted > 0) {
            root.knowledgeGapsConverted(converted)
        }
    }

    function setTaskCompletedWithAnimationDelay(id, completed) {
        if (completed) {
            // 完成动画依附在当前 TaskItem delegate 上；TaskManager 会同步发 tasksChanged，
            // 如果立即刷新 Repeater，delegate 会被销毁，粒子动画看不到结束。
            root.completionRefreshDelayActive = true;
            completionRefreshTimer.restart();
        }

        var ok = root.taskManagerRef.setTaskCompleted(id, completed);
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
        // 仅在“完成”时给撤销入口；取消完成本身就是一种撤销，不再叠加提示。
        if (completed) {
            root.taskCompletionUndoable(id, root.taskTitleById(id));
        }
    }

    function taskTitleById(id) {
        for (var i = 0; i < root.tasks.length; i++) {
            if (Number(root.tasks[i].id) === id) {
                return String(root.tasks[i].title || "");
            }
        }
        return "";
    }

    function loadTasks() {
        try {
            root.loadError = "";
            var loaded = root.taskManagerRef.getTodayTasks();
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
            root.todayStats = root.statisticsServiceRef.getTodayStats();
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

    function formatClockTime(seconds) {
        var safe = Math.max(0, Math.floor(Number(seconds || 0)))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16

        GridLayout {
            id: taskHeader
            objectName: "todayTaskHeader"
            Layout.fillWidth: true
            // 让操作区按自身内容决定换行，休息计时变长时也不会挤压标题。
            columns: width >= taskTitle.implicitWidth + taskActions.implicitWidth + Theme.space24 ? 2 : 1
            columnSpacing: Theme.space24
            rowSpacing: Theme.space12

            Text {
                id: taskTitle
                Layout.fillWidth: true
                text: qsTr("今日任务")
                font.pixelSize: Theme.fontXxl
                font.weight: Font.Bold
                color: Theme.ink
            }

            RowLayout {
                id: taskActions
                Layout.alignment: taskHeader.columns === 2 ? Qt.AlignRight : Qt.AlignLeft
                spacing: Theme.space8

                PageActionButton {
                    objectName: "taskToolsButton"
                    text: qsTr("搜索 / 批量改期")
                    glyph: "search"
                    onClicked: taskTools.open()
                }

                PageActionButton {
                    id: gapCaptureButton
                    objectName: "todayGapCaptureButton"
                    text: qsTr("记一笔")
                    glyph: "gap"
                    // 今日任务页没有「当前任务」的概念，所以这里的捕获不带来源；
                    // 带来源的那条路径在专注页上。
                    onClicked: gapCapturePopup.openWithSource(0, "", 0)
                }

                PageActionButton {
                    id: manualRestButton
                    objectName: "todayManualRestButton"
                    // 专注或番茄休息进行时不允许再开主动休息；主动休息保留返回入口。
                    visible: !!root.focusTimerRef && (!root.timerBusy || root.manualRestActive)
                    text: root.manualRestActive
                          ? qsTr("休息 %1").arg(root.formatClockTime(root.focusTimerRef.elapsedSeconds))
                          : qsTr("开始休息")
                    // 暂停符号读作「暂停」，与「开始休息」不符；月牙是这套图标里表示休息的那个。
                    glyph: "moon"
                    // 休息中文字每秒变化，比例数字会让按钮宽度抖动，把左侧按钮一起挤动；
                    // 计时期间给一个足够放下 00:00:00 的下限宽度。
                    implicitWidth: Math.max(root.manualRestActive ? 168 : 0,
                                            manualRestButton.contentItem.implicitWidth
                                            + manualRestButton.leftPadding + manualRestButton.rightPadding)
                    onClicked: {
                        if (root.manualRestActive) {
                            root.manualRestPageRequested()
                        } else {
                            root.manualRestRequested()
                        }
                    }
                }

                PageActionButton {
                    id: addButton
                    objectName: "todayAddButton"
                    text: qsTr("添加任务")
                    glyph: "plus"
                    primary: true
                    onClicked: addTaskDialog.open()
                }
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
            plannedMinutes: root.plannedMinutesToday
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
                    implicitHeight: Theme.controlHeightMd

                    onClicked: root.moveOverdueToToday()

                    background: Rectangle {
                        color: rolloverMoveButton.hovered ? Theme.accentFillStrong : Theme.accentFill
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: rolloverMoveButton.text
                        textFormat: Text.PlainText
                        color: Theme.accentFillInk
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
                    implicitHeight: Theme.controlHeightMd

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

        // 知识缺口提醒条。视觉与交互照搬上面的结转提示条：同一个位置、同一种分量，
        // 用户不需要学第二套语言。区别只在逾期项不会被顺延，只会被摆到今天来做。
        Rectangle {
            objectName: "knowledgeGapBanner"
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            visible: root.knowledgeGapBannerActive
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
                    objectName: "knowledgeGapBannerText"
                    Layout.fillWidth: true
                    // 只报「还剩几条」不足以让人停下来；拖得最久的那条拖了多少天才是推力。
                    text: root.gapOverdue > 0
                          ? qsTr("有 %1 条待补到期，其中 %2 条已逾期，最久的拖了 %3 天")
                            .arg(root.gapDueToday + root.gapOverdue)
                            .arg(root.gapOverdue)
                            .arg(root.gapOldestOverdueDays)
                          : qsTr("有 %1 条待补今天到期").arg(root.gapDueToday)
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    color: Theme.inkStrong
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }

                Button {
                    id: gapConvertButton
                    objectName: "knowledgeGapBannerConvertButton"
                    text: qsTr("全部加到今天")
                    implicitHeight: Theme.controlHeightMd

                    onClicked: root.convertDueGapsToTasks()

                    background: Rectangle {
                        color: gapConvertButton.hovered ? Theme.accentFillStrong : Theme.accentFill
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: gapConvertButton.text
                        textFormat: Text.PlainText
                        color: Theme.accentFillInk
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: gapOpenButton
                    objectName: "knowledgeGapBannerOpenButton"
                    text: qsTr("去看看")
                    implicitHeight: Theme.controlHeightMd

                    onClicked: root.knowledgeGapsRequested()

                    background: Rectangle {
                        color: gapOpenButton.hovered ? Theme.surfaceSunken : "transparent"
                        border.color: Theme.border
                        border.width: 1
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: gapOpenButton.text
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
            textFormat: Text.PlainText
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
                                // 底是 accentSoft 暖罩：accent 压上去只有 1.80:1，暖罩上必须用 accentFillInk。
                                color: Theme.accentFillInk
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
                    }
                }

                Item {
                    Layout.fillHeight: true
                }
            }

            ListView {
                id: todayTaskList
                objectName: "todayTaskList"

                anchors.fill: parent
                clip: true
                visible: root.tasks.length > 0
                // 拖动期间也保持这个引用不变——换模型会让整片 delegate 重建。
                model: root.tasks
                spacing: Theme.space8
                boundsBehavior: Flickable.StopAtBounds

                delegate: TaskItem {
                            id: todayTaskRow

                            // pragma ComponentBehavior: Bound 之后 delegate 不再继承外层作用域，
                            // 必须显式声明它消费的模型角色。
                            required property var modelData
                            // 落点指示要知道自己排第几；index 是 ListView 提供的附加角色。
                            required property int index
                            readonly property int dropIndex: todayTaskRow.index

                            width: todayTaskList.width
                            height: implicitHeight
                            taskId: todayTaskRow.modelData.id
                            taskTitle: todayTaskRow.modelData.title
                            taskCategory: todayTaskRow.modelData.category && todayTaskRow.modelData.category.name ? todayTaskRow.modelData.category : (todayTaskRow.modelData.categoryData && todayTaskRow.modelData.categoryData.name ? todayTaskRow.modelData.categoryData : (todayTaskRow.modelData.categoryText || ""))
                            taskCompleted: todayTaskRow.modelData.completed
                            estimatedMinutes: Number(todayTaskRow.modelData.estimatedMinutes || 0)
                            taskNotes: String(todayTaskRow.modelData.notes || "")
                            focusedMinutes: Number(todayTaskRow.modelData.focusedMinutes || 0)
                            // 已完成的任务不参与排序：它们本来就被排到列表末尾，
                            // 允许拖动只会让用户以为能把它插回未完成那一段。
                            draggable: root.canReorderTasks && !todayTaskRow.modelData.completed
                            opacity: root.draggingTaskId === todayTaskRow.taskId ? 0.6 : 1

                            onDragStarted: root.beginReorder(todayTaskRow.taskId)
                            onDragMoved: function (sceneX, sceneY) {
                                root.updateReorder(todayTaskRow.taskId,
                                                   todayTaskList.mapFromItem(null, sceneX, sceneY).y
                                                   + todayTaskList.contentY)
                            }
                            onDragFinished: function (cancelled) {
                                root.commitReorder(cancelled)
                            }

                            onCompletionChanged: function (id, completed) {
                                root.setTaskCompletedWithAnimationDelay(id, completed);
                            }

                            onStartFocusClicked: function (id, title) {
                                root.startFocus(id, title);
                            }

                            onDeleteClicked: function (id, title) {
                                root.deleteRequested(id, title);
                            }

                            renameSubmitter: function (id, newTitle) {
                                var originalCategoryId = Number(todayTaskRow.modelData.categoryId || -1);
                                var originalDate = root.taskIsoDate(todayTaskRow.modelData.date);
                                var succeeded = Boolean(root.taskManagerRef.updateTask(
                                    id, newTitle, originalCategoryId, originalDate))
                                if (!succeeded) {
                                    root.loadError = "任务更新失败，请重试";
                                }
                                return succeeded
                            }

                            onEditClicked: function (id) {
                                editTaskDialog.openForTask(todayTaskRow.modelData);
                            }
                        }
            }

            // 指示线属于列表交互层，不属于任何带离屏阴影图层的 TaskItem。
            // 放在 ListView 的同级上层既不会被 delegate 图层裁掉，也避免每行复制一条线。
            Rectangle {
                objectName: "todayDropIndicator"
                x: 0
                y: root.dropIndicatorContentY - todayTaskList.contentY - height / 2
                width: parent.width
                height: 2
                radius: 1
                z: 2
                color: Theme.accent
                visible: todayTaskList.visible && root.dropIndicatorContentY >= 0
                Accessible.ignored: true
            }
        }

    }

    KnowledgeGapCapturePopup {
        id: gapCapturePopup

        // 挂在页头的「记一笔」钮下方靠右；非模态，不挡住列表。
        parent: gapCaptureButton
        x: gapCaptureButton.width - width
        y: gapCaptureButton.height + Theme.space8
        gapServiceRef: root.knowledgeGapServiceRef

        onCaptured: function (title) { root.knowledgeGapCaptured(title) }
    }

    TaskToolsDialog {
        id: taskTools
        parent: root
        taskManagerRef: root.taskManagerRef
        categoryManagerRef: root.categoryManagerRef
        todayIso: root.logicalTodayIso
        pendingDeleteTaskId: root.pendingDeleteTaskId
        onStartRequested: function(id, title) { root.startFocus(id, title) }
    }

    AddTaskDialog {
        id: addTaskDialog

        categoryManagerRef: root.categoryManagerRef
        selectedDateProvider: function () { return root.currentLogicalTodayDate() }
        taskSubmitter: function (title, date, categoryId, estimatedMinutes, notes) {
            return root.taskManagerRef.addTask(title, Qt.formatDate(date, "yyyy-MM-dd"), Number(categoryId), Number(estimatedMinutes), String(notes || ""));
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
                root.loadError = "任务更新失败，请重试";
            }
            return succeeded
        }
    }

    CountdownDialog {
        id: countdownDialog

        parent: root
        countdownServiceRef: root.countdownServiceRef
    }
}
