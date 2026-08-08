import QtQuick
import QtTest
import "../../qml/views"
import "../../qml/components"
import "../../qml"
import "../../qml/views/DashboardFormat.js" as DashboardFormat

TestCase {
    id: testCase
    name: "DashboardView"
    when: windowShown
    width: 1100
    height: 720
    property var logicalNow: new Date(2026, 6, 12, 12, 0, 0)

    // —— 服务桩：由下面的 DashboardView 显式注入，不再依赖同名 id 的动态作用域 ——
    QtObject {
        id: taskManager

        signal tasksChanged
        signal operationFailed(string message)

        property var todayTasksData: []
        property int todayTasksCalls: 0

        function getTodayTasks() {
            todayTasksCalls += 1
            return todayTasksData
        }

        function setTaskCompleted(id, completed) {
            return true
        }

        function updateTask(id, title, categoryId, date) {
            return true
        }

        function getOverdueUncompletedTasks() {
            return []
        }
    }

    QtObject {
        id: statisticsService

        signal operationFailed(string message)

        property var todayStatsData: ({
            totalDuration: 9180,
            completedTasks: 7,
            totalTasks: 10,
            completionRate: 0.7,
            sessionCount: 5,
            pomodoroCount: 2
        })
        property int streakData: 16
        property int totalData: 124 * 3600
        property var todayTaskStatsData: ({ tasks: [], totalDuration: 0, taskCount: 0 })

        function getTodayStats() {
            return todayStatsData
        }

        function getStreakDays() {
            return streakData
        }

        function getTotalFocusDuration() {
            return totalData
        }

        function getTodayTaskStats() {
            return todayTaskStatsData
        }
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)

        property int phase: 0
        property bool hasActiveSession: false
        property bool isRunning: false
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
        property string sessionLogicalDate: "2026-07-12"
        property int targetSeconds: 0
        property string currentTaskTitle: ""
        property int pauseCalls: 0
        property int resumeCalls: 0
        property int stopCalls: 0
        property int resetCountCalls: 0

        function pauseFocus() {
            pauseCalls += 1
        }

        function resumeFocus() {
            resumeCalls += 1
            return true
        }

        function stopFocus() {
            stopCalls += 1
            return true
        }

        function resetPomodoroCount() {
            resetCountCalls += 1
        }
    }

    QtObject {
        id: routineManager

        signal routinesChanged
        signal operationFailed(string message)

        function materializeToday() {
        }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged
    }

    QtObject {
        id: logicalDayService

        signal changed
    }

    QtObject {
        id: appSettings

        signal dailyFocusGoalChanged

        property int dayStartHour: 4
        property bool reduceMotion: true
        property bool dashboardTimerVisible: true
        property int workMinutes: 25
        property int breakMinutes: 5
        property int lastMode: 0
        property string nickname: ""
        property string focusGoalDate: ""
        property int focusGoalMinutes: 0
        property bool focusGoalSaveSucceeds: true

        function dailyFocusGoalMinutesForDate(isoDate) {
            return isoDate === focusGoalDate ? focusGoalMinutes : 0
        }

        function setDailyFocusGoal(isoDate, minutes) {
            if (!focusGoalSaveSucceeds)
                return false
            focusGoalDate = isoDate
            focusGoalMinutes = minutes
            dailyFocusGoalChanged()
            return true
        }
    }

    Component {
        id: dashboardComponent

        DashboardView {
            width: 1000
            height: 680
            // 此前这些桩是靠「同名 id 撞上视图里的非限定引用」被解析到的，
            // 也就是说测试在替视图验证一条动态作用域链，而不是验证它声明的依赖。
            // 现在显式注入，视图对外部的依赖在两侧都写得出来。
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            routineManagerRef: routineManager
            focusTimerRef: focusTimer
            categoryManagerRef: categoryManager
            settingsRef: appSettings
            nowProvider: function() { return testCase.logicalNow }
        }
    }

    Component {
        id: timerPanelComponent

        DashboardTimerPanel {
            width: 300
            height: 560
            timerRef: focusTimer
            settingsRef: appSettings
            logicalDate: "2026-07-12"
        }
    }

    Rectangle {
        id: wallpaperSample

        width: 320
        height: 580
        z: -1
        color: "#d9b38c"
    }

    Component {
        id: liquidGlassComponent

        LiquidGlassBackdrop {
            width: 300
            height: 560
            sourceItem: wallpaperSample
            sourceRect: Qt.rect(0, 0, 300, 560)
            refractionShader: Qt.resolvedUrl("../../resources/shaders/liquid_glass.frag.qsb")
        }
    }

    function init() {
        taskManager.todayTasksData = []
        taskManager.todayTasksCalls = 0
        focusTimer.phase = 0
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
        focusTimer.sessionLogicalDate = "2026-07-12"
        focusTimer.pauseCalls = 0
        focusTimer.resumeCalls = 0
        focusTimer.stopCalls = 0
        focusTimer.resetCountCalls = 0
        appSettings.nickname = ""
        appSettings.focusGoalDate = ""
        appSettings.focusGoalMinutes = 0
        appSettings.focusGoalSaveSucceeds = true
        statisticsService.todayTaskStatsData = { tasks: [], totalDuration: 0, taskCount: 0 }
        testCase.logicalNow = new Date(2026, 6, 12, 12, 0, 0)
        Theme.glassBlurAllowed = true
    }

    // 递归统计某 objectName 的节点数（Repeater 生成的行也在可视子树里）。
    function countObjects(item, name) {
        if (!item)
            return 0
        var n = (item.objectName === name) ? 1 : 0
        var kids = item.children ? item.children.length : 0
        for (var i = 0; i < kids; i++)
            n += countObjects(item.children[i], name)
        return n
    }

    // —— DashboardFormat 纯函数 ——

    function test_greeting_boundaries() {
        compare(DashboardFormat.greetingFor(4), "夜深了")
        compare(DashboardFormat.greetingFor(5), "早上好")
        compare(DashboardFormat.greetingFor(11), "中午好")
        compare(DashboardFormat.greetingFor(13), "下午好")
        compare(DashboardFormat.greetingFor(18), "晚上好")
        compare(DashboardFormat.greetingFor(23), "夜深了")
    }

    function test_number_formats() {
        compare(DashboardFormat.totalHoursText(7200), "2")
        compare(DashboardFormat.totalHoursText(9000), "2.5")
        compare(DashboardFormat.totalHoursText(124 * 3600), "124")
        compare(DashboardFormat.equivalentDaysText(Math.round(86400 * 5.1)), "5.1")
    }

    function test_daily_pick_rotates_by_day() {
        var items = ["a", "b", "c"]
        compare(DashboardFormat.dailyPick(items, new Date(2026, 0, 1)), "a")
        compare(DashboardFormat.dailyPick(items, new Date(2026, 0, 2)), "b")
        compare(DashboardFormat.dailyPick([], new Date()), "")
    }

    // —— DashboardView 行为 ——

    function test_stats_flow_into_cards() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        compare(Number(view.todayStats.sessionCount), 5)
        compare(Number(view.todayStats.pomodoroCount), 2)
        compare(view.streakDays, 16)
        compare(view.totalFocusSeconds, 124 * 3600)

        var totalCard = findChild(view, "dashboardTotalCard")
        verify(totalCard)
        compare(totalCard.value, "124")
        compare(totalCard.subtitle, "相当于 5.2 天")

        var streakCard = findChild(view, "dashboardStreakCard")
        verify(streakCard)
        compare(streakCard.value, "16")

        const focusDurationCard = findChild(view, "todayFocusDurationCard")
        const timerPomodoroText = findChild(view, "dashboardTimerSessionCount")
        verify(focusDurationCard)
        verify(timerPomodoroText)
        compare(focusDurationCard.title, "今日专注时长")
        compare(focusDurationCard.value, "2.6")
        compare(focusDurationCard.unit, "小时")
        compare(focusDurationCard.subtitle, "共 5 次专注")
        compare(timerPomodoroText.text, "今日已专注 2 个番茄")
    }

    // 星期名必须是中文。Qt.formatDate 传格式字符串时不查区域设置，"dddd" 恒定输出
    // "Sunday"，会拼出「2026年7月12日 Sunday」；这条用例把中文星期钉死。
    function test_dateTextUsesChineseWeekday() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        var dateText = findChild(view, "dashboardDateText")
        verify(dateText)
        // logicalNow 固定为 2026-07-12（星期日），不依赖运行日期。
        compare(dateText.text, "2026年7月12日 星期日")
    }

    // 任务列表横向不许溢出：内容宽度绑 availableWidth 而不是 parent.width，
    // 否则内容项会被自身内容撑宽，任务行伸到纵向滚动条底下被裁掉。
    function test_taskListDoesNotOverflowHorizontally() {
        taskManager.todayTasksData = [
            { id: 1, title: "一个标题很长很长很长很长很长很长很长很长的任务", completed: false },
            { id: 2, title: "另一个任务", completed: true }
        ]

        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        var scrollView = findChild(view, "dashboardTaskScrollView")
        verify(scrollView)
        verify(scrollView.availableWidth > 0)
        compare(scrollView.contentWidth, scrollView.availableWidth)
    }

    function test_serviceFailuresAreShownInsteadOfEmptyState() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        taskManager.operationFailed("任务数据库故障")
        compare(view.loadError, "任务数据库故障")

        statisticsService.operationFailed("统计数据库故障")
        compare(view.loadError, "统计数据库故障")

        routineManager.operationFailed("例行生成故障")
        compare(view.loadError, "例行生成故障")
    }

    function test_synchronous_data_invalidations_share_one_refresh() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        var callsBefore = taskManager.todayTasksCalls

        taskManager.tasksChanged()
        focusTimer.focusCompleted(1500)
        categoryManager.categoriesChanged()
        routineManager.routinesChanged()
        logicalDayService.changed()

        // 同一事件循环内的多条失效链只做一次整页查询。
        tryCompare(taskManager, "todayTasksCalls", callsBefore + 1, 1000)
    }

    function test_cross_event_loop_invalidations_are_not_swallowed() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        var callsBefore = taskManager.todayTasksCalls

        taskManager.tasksChanged()
        tryCompare(taskManager, "todayTasksCalls", callsBefore + 1, 1000)

        focusTimer.focusCompleted(1500)
        tryCompare(taskManager, "todayTasksCalls", callsBefore + 2, 1000)
    }

    function test_page_activation_keeps_the_first_refresh_immediate() {
        var view = createTemporaryObject(dashboardComponent, testCase, { pageActive: false })
        verify(view)
        compare(taskManager.todayTasksCalls, 0)

        view.pageActive = true
        tryCompare(taskManager, "todayTasksCalls", 1, 1000)
    }

    function test_completion_animation_still_defers_task_refresh() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        var callsBefore = taskManager.todayTasksCalls

        view.completionRefreshDelayActive = true
        taskManager.tasksChanged()
        wait(40)
        compare(taskManager.todayTasksCalls, callsBefore)
        view.completionRefreshDelayActive = false
    }

    function test_greeting_includes_nickname_when_set() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        var greeting = findChild(view, "dashboardGreeting")
        verify(greeting)
        // 空昵称：只有问候语，不能出现悬空逗号。
        verify(greeting.text.indexOf("，") === -1)

        appSettings.nickname = "zjk"
        verify(greeting.text.indexOf("，zjk") > 0)
    }

    function test_filter_modes() {
        taskManager.todayTasksData = [
            { id: 1, title: "未完成任务", completed: false, categoryText: "学习" },
            { id: 2, title: "已完成任务", completed: true, categoryText: "工作" },
            { id: 3, title: "另一件完成", completed: true, categoryText: "" }
        ]

        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        compare(view.filteredTasks.length, 3)
        compare(view.completedTaskCount, 2)
        compare(view.panelTaskCount, 3)

        var countBadge = findChild(view, "dashboardTaskCount")
        verify(countBadge)
        compare(countBadge.text, "3")

        view.filterMode = "done"
        compare(view.doneFilter, true)
        compare(view.filteredTasks.length, 2)
        compare(Number(view.filteredTasks[0].id), 2)
        compare(view.panelTaskCount, 2)
        compare(countBadge.text, "2")

        // 已完成摘要：完成数 / 总数 · 完成率。
        // 注意：createTemporaryObject 的可见树可能整树 visible=false，
        // 所以只断言文案与业务属性，不读子项 .visible。
        var summary = findChild(view, "dashboardDoneSummary")
        verify(summary)
        verify(summary.text.indexOf("已完成 2 / 3") >= 0)
        verify(summary.text.indexOf("67%") >= 0)

        // 紧凑只读：应有完成徽章节点；列表项 compact + 关闭编辑/开始专注。
        verify(findChild(view, "taskCompletedBadge") !== null)
        function findFirstTaskItem(item) {
            if (!item)
                return null
            if (item.taskId !== undefined && item.compact !== undefined
                    && item.showEditDelete !== undefined && item.taskTitle !== undefined
                    && item.taskId > 0)
                return item
            var kids = item.children ? item.children.length : 0
            for (var i = 0; i < kids; i++) {
                var found = findFirstTaskItem(item.children[i])
                if (found)
                    return found
            }
            return null
        }
        var taskItem = findFirstTaskItem(view)
        verify(taskItem !== null, "应能找到仪表盘任务行")
        compare(taskItem.compact, true)
        compare(taskItem.showEditDelete, false)
        compare(taskItem.showStartFocus, false)
        compare(taskItem.taskCompleted, true)

        // 仪表盘只读面板：不提供快速添加入口。
        compare(findChild(view, "dashboardQuickAddField"), null)

        // 切回全部：角标恢复总数，行回到可编辑规格。
        view.filterMode = "all"
        compare(view.doneFilter, false)
        compare(countBadge.text, "3")
        wait(40)
        taskItem = findFirstTaskItem(view)
        verify(taskItem !== null)
        compare(taskItem.compact, false)
        compare(taskItem.showEditDelete, true)
        compare(taskItem.showStartFocus, true)
    }

    function test_learning_segment_lists_today_focus() {
        statisticsService.todayTaskStatsData = {
            totalDuration: 9000,
            taskCount: 2,
            tasks: [
                { taskId: 1, title: "高数第七章", color: "#C08457", focusedSeconds: 5400, pomodoros: 3, completed: false, unassigned: false },
                { taskId: -1, title: "", color: "", focusedSeconds: 3600, pomodoros: 0, completed: false, unassigned: true }
            ]
        }

        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        // 第三个筛选胶囊存在。
        var chip = findChild(view, "dashboardFilter-learning")
        verify(chip)

        view.filterMode = "learning"

        var list = findChild(view, "dashboardTodayLearningList")
        verify(list)
        compare(Number(list.stats.taskCount), 2)
        compare(Number(list.stats.totalDuration), 9000)

        // 角标跟随学习统计的任务数。
        compare(view.panelTaskCount, 2)
        var countBadge = findChild(view, "dashboardTaskCount")
        verify(countBadge)
        compare(countBadge.text, "2")

        // 摘要文案：项数 + 今日总时长。
        var summary = findChild(view, "todayLearningSummary")
        verify(summary)
        verify(summary.text.indexOf("共 2 项") >= 0)
        verify(summary.text.indexOf("2小时30分钟") >= 0)

        // 两行任务(含未关联专注)。
        compare(countObjects(view, "todayLearningRow"), 2)

        // 行要铺满面板宽度：时长列靠右对齐才读得出「任务 —— 时长」的对应关系。
        // 绑错成 parent.width 时行会缩到内容自然宽，时长列悬在面板中间。
        var learningScroll = findChild(list, "todayLearningScrollView")
        verify(learningScroll)
        verify(learningScroll.availableWidth > 0)
        compare(learningScroll.contentWidth, learningScroll.availableWidth)

        // 行宽由布局 polish 阶段算出，创建后不是立刻就位，所以用 tryCompare 轮询。
        var row = findChild(list, "todayLearningRow")
        verify(row)
        tryCompare(row, "width", learningScroll.availableWidth)
    }

    function test_learning_segment_empty_state() {
        statisticsService.todayTaskStatsData = { tasks: [], totalDuration: 0, taskCount: 0 }

        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        view.filterMode = "learning"

        compare(view.panelTaskCount, 0)
        var empty = findChild(view, "todayLearningEmptyText")
        verify(empty)
        verify(empty.text.indexOf("还没有专注记录") >= 0)
        compare(countObjects(view, "todayLearningRow"), 0)
    }

    function test_start_first_pending_task() {
        taskManager.todayTasksData = [
            { id: 9, title: "已完成任务", completed: true },
            { id: 3, title: "该开始的任务", completed: false }
        ]

        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        var startSpy = createTemporaryObject(spyComponent, testCase,
                                             { target: view, signalName: "startFocus" })
        view.startFirstPendingTask()
        compare(startSpy.count, 1)
        compare(Number(startSpy.signalArguments[0][0]), 3)

        // 没有待办任务时改为带用户去专注页，而不是静默失败。
        taskManager.todayTasksData = []
        taskManager.tasksChanged()
        tryCompare(view, "tasks", taskManager.todayTasksData, 1000)
        var focusSpy = createTemporaryObject(spyComponent, testCase,
                                             { target: view, signalName: "focusPageRequested" })
        view.startFirstPendingTask()
        compare(focusSpy.count, 1)
    }

    Component {
        id: spyComponent

        SignalSpy {
        }
    }

    // —— FocusGoalCard 目标进度 ——

    Component {
        id: goalCardComponent

        FocusGoalCard {
            width: 260
        }
    }

    function test_goal_card_clock_and_percent() {
        var card = createTemporaryObject(goalCardComponent, testCase,
                                         { totalSeconds: 2 * 3600 + 35 * 60 + 45,
                                           goalMinutes: 180 })
        verify(card)

        compare(card.clockText, "02:35:45")
        // 9345 / 10800 = 86.5% 向下取整。
        compare(card.percent, 86)
        compare(card.goalReached, false)

        card.totalSeconds = 3 * 3600 + 1
        compare(card.percent, 100)
        compare(card.goalReached, true)

        var pctText = findChild(card, "focusGoalPercent")
        verify(pctText)
        compare(pctText.text, "100%")
        var reachedText = findChild(card, "focusGoalReachedLabel")
        verify(reachedText)
        compare(reachedText.text, "目标达成")

        // 负数与零目标都不能出 NaN/越界。
        card.totalSeconds = -5
        compare(card.clockText, "00:00:00")
        compare(card.percent, 0)
    }

    function test_goal_card_unset_and_arbitrary_duration_editor() {
        var card = createTemporaryObject(goalCardComponent, testCase, { goalMinutes: 0 })
        verify(card)
        compare(card.hasGoal, false)
        compare(card.percent, 0)
        compare(card.editing, false)
        var unsetLabel = findChild(card, "focusGoalUnsetLabel")
        verify(unsetLabel)
        compare(unsetLabel.text, "尚未设置")

        var submitSpy = createTemporaryObject(spyComponent, testCase,
                                              { target: card, signalName: "goalSubmitted" })
        card.beginEditing()
        compare(card.editing, true)
        var loader = findChild(card, "focusGoalEditorLoader")
        verify(loader)
        tryCompare(loader, "status", Loader.Ready, 300)
        verify(loader.item)

        var hourField = findChild(loader.item, "focusGoalHourField")
        var minuteField = findChild(loader.item, "focusGoalMinuteField")
        var errorLabel = findChild(loader.item, "focusGoalValidationError")
        verify(hourField)
        verify(minuteField)
        verify(errorLabel)

        hourField.text = "0"
        minuteField.text = "0"
        loader.item.submit()
        compare(submitSpy.count, 0)
        verify(loader.item.validationError.indexOf("至少") >= 0)

        hourField.text = "24"
        minuteField.text = "1"
        loader.item.submit()
        compare(submitSpy.count, 0)
        verify(loader.item.validationError.indexOf("分钟必须为 0") >= 0)

        hourField.text = "2"
        minuteField.text = "20"
        loader.item.submit()
        compare(submitSpy.count, 1)
        compare(Number(submitSpy.signalArguments[0][0]), 140)

        card.handleSaveResult(false)
        compare(card.editing, true)
        verify(card.saveError.length > 0)
        card.handleSaveResult(true)
        compare(card.editing, false)
    }

    function test_dashboard_goal_is_bound_to_logical_day() {
        appSettings.focusGoalDate = "2026-07-12"
        appSettings.focusGoalMinutes = 140
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        compare(view.logicalTodayIso, "2026-07-12")
        compare(view.dailyFocusGoalMinutes, 140)

        // 跨到下一个逻辑日后，昨天目标不继承。
        testCase.logicalNow = new Date(2026, 6, 13, 12, 0, 0)
        logicalDayService.changed()
        tryCompare(view, "logicalTodayIso", "2026-07-13", 1000)
        tryCompare(view, "dailyFocusGoalMinutes", 0, 1000)

        // 保存动作已移交今日任务页；仪表盘上的目标卡是只读实例。
        var card = findChild(view, "dashboardGoalCard")
        verify(card)
        compare(card.editable, false)
        card.beginEditing()
        compare(card.editing, false)
    }

    function test_timer_panel_live_focus_seconds() {
        var panel = createTemporaryObject(timerPanelComponent, testCase,
                                          { todayFocusSeconds: 600 })
        verify(panel)

        // 待机：只有落库累计。
        compare(panel.liveFocusSeconds, 600)

        // 番茄工作阶段：叠加进行中秒数。
        focusTimer.phase = 1
        focusTimer.elapsedSeconds = 300
        compare(panel.liveFocusSeconds, 900)

        // 跨逻辑日后，旧会话仍在运行也不得叠加到新一天的已落库统计上。
        focusTimer.sessionLogicalDate = "2026-07-11"
        compare(panel.liveFocusSeconds, 600)
        focusTimer.sessionLogicalDate = "2026-07-12"

        // 休息阶段不累计。
        focusTimer.phase = 2
        compare(panel.liveFocusSeconds, 600)

        // 只读目标卡：引导链接向上请求跳到今日任务页，面板不碰设置存储。
        var setupSpy = createTemporaryObject(spyComponent, testCase,
                                             { target: panel, signalName: "goalSetupRequested" })
        var card = findChild(panel, "dashboardGoalCard")
        verify(card)
        compare(card.editable, false)
        card.setupRequested()
        compare(setupSpy.count, 1)
        focusTimer.elapsedSeconds = 0
    }

    // —— DashboardTimerPanel 状态机 ——

    function test_timer_panel_hide_and_reveal() {
        appSettings.dashboardTimerVisible = true
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        var shell = findChild(view, "dashboardTimerShell")
        var reveal = findChild(view, "dashboardTimerRevealButton")
        var panel = findChild(view, "dashboardTimerPanel")
        var hideLink = findChild(view, "dashboardTimerHideLink")
        verify(shell)
        verify(reveal)
        verify(panel)
        verify(hideLink)

        // 展开态：壳全宽，恢复把手不可交互。
        // 宽度现在由布局协商产出（Layout.preferredWidth 驱动），需要一次布局 pass；
        // 此前是直接写 item 的 width 才能紧跟创建就读到值，但那种写法是
        // qmllint 判定的 undefined behavior。同用例后面几处本来就用 tryCompare。
        tryCompare(shell, "width", 300)
        compare(reveal.enabled, false)

        // 「隐藏」链接向上发信号：写回设置并收起（mock 关了动效，宽度立即归零）。
        panel.hideRequested()
        compare(appSettings.dashboardTimerVisible, false)
        tryCompare(shell, "width", 0)
        tryCompare(reveal, "enabled", true)

        // 收起后右侧留出把手通道：行距16+通道16+页边距24 与左侧 32+24 对齐。
        var gutter = findChild(view, "dashboardTimerRevealGutter")
        verify(gutter)
        tryCompare(gutter, "width", 16)

        // 恢复把手的无障碍动作与点击共用同一入口：重新展开。
        view.setTimerPanelVisible(true)
        compare(appSettings.dashboardTimerVisible, true)
        tryCompare(shell, "width", 300)
        appSettings.dashboardTimerVisible = true
    }

    function test_timer_panel_idle_preview() {
        var panel = createTemporaryObject(timerPanelComponent, testCase)
        verify(panel)

        compare(panel.statusText, "待机")
        compare(panel.timeText, "25:00")
        compare(panel.ringProgress, 1)
    }

    function test_timer_panel_pomodoro_states() {
        var panel = createTemporaryObject(timerPanelComponent, testCase)
        verify(panel)

        focusTimer.phase = 1
        focusTimer.targetSeconds = 1500
        focusTimer.remainingSeconds = 750
        focusTimer.isRunning = true
        compare(panel.statusText, "专注中")
        compare(panel.timeText, "12:30")
        compare(panel.ringProgress, 0.5)

        focusTimer.isRunning = false
        compare(panel.statusText, "已暂停")

        focusTimer.phase = 2
        focusTimer.isRunning = true
        compare(panel.statusText, "休息中")
    }

    function test_timer_panel_primary_action_routes() {
        var panel = createTemporaryObject(timerPanelComponent, testCase)
        verify(panel)

        var startSpy = createTemporaryObject(spyComponent, testCase,
                                             { target: panel, signalName: "startRequested" })
        panel.primaryAction()
        compare(startSpy.count, 1)
        compare(focusTimer.pauseCalls, 0)

        focusTimer.phase = 1
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        panel.primaryAction()
        compare(focusTimer.pauseCalls, 1)

        focusTimer.isRunning = false
        panel.primaryAction()
        compare(focusTimer.resumeCalls, 1)
        // 待机分支只发信号，不该误触暂停/继续。
        compare(startSpy.count, 1)
    }

    function test_timer_panel_stop_resets_pomodoro_cycle() {
        var panel = createTemporaryObject(timerPanelComponent, testCase)
        verify(panel)
        var stopButton = findChild(panel, "dashboardTimerStopButton")
        verify(stopButton)

        // 番茄阶段的「结束」= 结束整轮循环：连续计数必须归零，与专注页同语义。
        focusTimer.phase = 1
        focusTimer.hasActiveSession = true
        stopButton.clicked()
        compare(focusTimer.stopCalls, 1)
        compare(focusTimer.resetCountCalls, 1)

        // 自由专注不涉及番茄计数，结束时不应触碰。
        focusTimer.phase = 0
        stopButton.clicked()
        compare(focusTimer.stopCalls, 2)
        compare(focusTimer.resetCountCalls, 1)
    }

    function test_liquid_glass_effect_and_solid_fallback() {
        Theme.glassBlurAllowed = false
        var backdrop = createTemporaryObject(liquidGlassComponent, testCase)
        verify(backdrop)
        compare(backdrop.effectActive, false)

        var loader = findChild(backdrop, "liquidGlassEffectLoader")
        var fallback = findChild(backdrop, "liquidGlassFallback")
        verify(loader)
        verify(fallback)
        compare(loader.active, false)
        verify(Qt.colorEqual(fallback.color, Theme.glassSolidCard))

        Theme.glassBlurAllowed = true
        tryCompare(loader, "active", true, 300)
        tryCompare(loader, "status", Loader.Ready, 500)
        var refraction = findChild(backdrop, "liquidGlassRefraction")
        verify(refraction)
        verify(String(refraction.fragmentShader).indexOf("liquid_glass.frag.qsb") >= 0)
        // CI 的软件渲染后端不支持 ShaderEffect；GPU 后端则应进入有效态。
        // 两者都必须在有限时间内给出明确结果，不能永久停在伪加载态。
        tryVerify(function() { return backdrop.effectActive || backdrop.shaderFailed }, 1200)
        if (backdrop.shaderFailed) {
            compare(backdrop.effectActive, false)
            compare(backdrop.fallbackActive, true)
        }

        backdrop.refractionShader = Qt.resolvedUrl("missing-liquid-glass.frag.qsb")
        tryCompare(backdrop, "shaderFailed", true, 1200)
        compare(backdrop.effectActive, false)
        tryCompare(loader, "active", false, 100)
        compare(backdrop.fallbackActive, true)
        verify(backdrop.shaderError.length > 0)
    }

}
