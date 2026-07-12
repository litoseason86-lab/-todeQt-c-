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

        function getTodayTasks() {
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

    function init() {
        taskManager.todayTasksData = []
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

}
