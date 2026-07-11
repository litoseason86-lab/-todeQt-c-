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

    // —— 上下文对象桩：同名 id 让视图的非限定引用解析到这里 ——
    QtObject {
        id: taskManager

        signal tasksChanged

        property var todayTasksData: []
        property var addedTitles: []
        property var addedDates: []

        function getTodayTasks() {
            return todayTasksData
        }

        function addTask(title, date, categoryId) {
            addedTitles.push(title)
            addedDates.push(date)
            return true
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

        property var todayStatsData: ({
            totalDuration: 9180,
            completedTasks: 7,
            totalTasks: 10,
            completionRate: 0.7,
            sessionCount: 5
        })
        property int streakData: 16
        property int totalData: 124 * 3600

        function getTodayStats() {
            return todayStatsData
        }

        function getStreakDays() {
            return streakData
        }

        function getTotalFocusDuration() {
            return totalData
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
        property int targetSeconds: 0
        property string currentTaskTitle: ""
        property int pauseCalls: 0
        property int resumeCalls: 0
        property int stopCalls: 0

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
    }

    QtObject {
        id: routineManager

        signal routinesChanged

        function materializeToday() {
        }
    }

    QtObject {
        id: logicalDayService

        signal changed
    }

    QtObject {
        id: appSettings

        property int dayStartHour: 4
        property bool reduceMotion: true
        property int workMinutes: 25
        property int breakMinutes: 5
        property int lastMode: 0
        property string nickname: ""
    }

    Component {
        id: dashboardComponent

        DashboardView {
            width: 1000
            height: 680
            settingsRef: appSettings
        }
    }

    Component {
        id: timerPanelComponent

        DashboardTimerPanel {
            width: 300
            height: 560
            timerRef: focusTimer
            settingsRef: appSettings
        }
    }

    Component {
        id: heroComponent

        DashboardCountdownHero {
            width: 600
        }
    }

    function init() {
        taskManager.todayTasksData = []
        taskManager.addedTitles = []
        taskManager.addedDates = []
        focusTimer.phase = 0
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
        focusTimer.pauseCalls = 0
        focusTimer.resumeCalls = 0
        focusTimer.stopCalls = 0
        appSettings.nickname = ""
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

    function test_countdown_segments() {
        var seg = DashboardFormat.countdownSegments("2026-07-22", new Date(2026, 6, 12, 0, 0, 0))
        compare(seg.expired, false)
        compare(seg.days, 10)
        compare(seg.hours, 0)
        compare(seg.minutes, 0)
        compare(seg.seconds, 0)

        seg = DashboardFormat.countdownSegments("2099-01-01", new Date(2098, 11, 31, 23, 59, 30))
        compare(seg.days, 0)
        compare(seg.seconds, 30)

        seg = DashboardFormat.countdownSegments("2026-07-10", new Date(2026, 6, 12, 12, 0, 0))
        compare(seg.expired, true)
        compare(seg.expiredDays, 2)

        compare(DashboardFormat.countdownSegments("", new Date()), null)
    }

    function test_number_formats() {
        compare(DashboardFormat.two(5), "05")
        compare(DashboardFormat.two(59), "59")
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
        compare(view.streakDays, 16)
        compare(view.totalFocusSeconds, 124 * 3600)

        var totalCard = findChild(view, "dashboardTotalCard")
        verify(totalCard)
        compare(totalCard.value, "124")
        compare(totalCard.subtitle, "相当于 5.2 天")

        var streakCard = findChild(view, "dashboardStreakCard")
        verify(streakCard)
        compare(streakCard.value, "16")
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
            { id: 1, title: "未完成任务", completed: false },
            { id: 2, title: "已完成任务", completed: true }
        ]

        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        compare(view.filteredTasks.length, 2)

        view.filterMode = "active"
        compare(view.filteredTasks.length, 1)
        compare(Number(view.filteredTasks[0].id), 1)

        view.filterMode = "done"
        compare(view.filteredTasks.length, 1)
        compare(Number(view.filteredTasks[0].id), 2)
    }

    function test_quick_add_submits_trimmed_title() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)

        var field = findChild(view, "dashboardQuickAddField")
        verify(field)
        field.text = "  背单词 50 个  "
        view.submitQuickAdd()

        compare(taskManager.addedTitles.length, 1)
        compare(taskManager.addedTitles[0], "背单词 50 个")
        // 快速添加必须落在逻辑今天，且提交后清空输入框。
        compare(taskManager.addedDates[0], view.todayIsoDate())
        compare(field.text, "")

        field.text = "   "
        view.submitQuickAdd()
        compare(taskManager.addedTitles.length, 1)
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

    // —— DashboardTimerPanel 状态机 ——

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

    // —— DashboardCountdownHero 路由 ——

    function test_hero_activate_routes_by_goal() {
        var hero = createTemporaryObject(heroComponent, testCase)
        verify(hero)

        var addSpy = createTemporaryObject(spyComponent, testCase,
                                           { target: hero, signalName: "addRequested" })
        hero.activate()
        compare(addSpy.count, 1)

        hero.primaryGoal = { name: "考研", targetDate: new Date(2099, 0, 1) }
        verify(hero.hasGoal)
        hero.updateSegments()
        verify(hero.segments !== null)
        compare(hero.segments.expired, false)
        verify(hero.segments.days > 0)

        var clickSpy = createTemporaryObject(spyComponent, testCase,
                                             { target: hero, signalName: "clicked" })
        hero.activate()
        compare(clickSpy.count, 1)
        compare(addSpy.count, 1)
    }
}
