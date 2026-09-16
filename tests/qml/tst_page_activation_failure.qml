import QtQuick
import QtTest
import "../../qml/views"

// 切进页面的那一次查询失败，必须变成可见的错误，不能被显示成空页面（2026-09-15 审查修复）。
//
// 常驻页面（StackLayout 的子页）用 pageActive 给失败信号做门禁，曾写成
// `Connections { enabled: root.pageActive }`。enabled 是绑定，重算晚于 onPageActiveChanged：
// 页面在处理函数里同步查询，服务又是在这次调用过程中同步发 operationFailed 的——
// 那一刻绑定还是旧值 false，信号被整个丢掉。KnowledgeGapView 在 81bdb74 修过，
// 另外几页原样保留：目标页因此显示「没有进行中的目标」并引导重复新建。
//
// 替身一律在查询函数「内部」同步发失败；改成异步发就暴露不出这个问题。
// 断言用替身给出的原文：页面对替身缺方法抛出的异常会兜成通用文案，只断言「非空」会误判通过。
TestCase {
    id: testCase
    name: "PageActivationFailure"
    when: windowShown
    width: 1100
    height: 760

    property var fixedNow: new Date(2026, 6, 15, 12, 0, 0)

    QtObject {
        id: taskManager

        signal tasksChanged()
        signal operationFailed(string message)

        property bool failTodayTasks: false
        property bool failOverdue: false
        property bool failWeekTasks: false

        function getTodayTasks() {
            if (failTodayTasks) {
                operationFailed("今日任务查询失败")
                return []
            }
            return []
        }
        function getOverdueUncompletedTasks() {
            if (failOverdue) {
                operationFailed("逾期任务查询失败")
                return []
            }
            return []
        }
        function getWeekTasks(weekStartIso) {
            if (failWeekTasks) {
                operationFailed("本周任务查询失败")
                return []
            }
            return []
        }
        function getTasksByDate(date) { return [] }
        function getMonthTasks(year, month) { return [] }
        function moveTasksToToday(ids) { return true }
        function addTask(title, date, categoryId) { return true }
        function setTaskCompleted(id, completed) { return true }
        function deleteTask(id) { return true }
        function updateTask(id, title, categoryId, date) { return true }
        function isRoutineGeneratedTask(id) { return false }
    }

    QtObject {
        id: statisticsService

        signal operationFailed(string message)

        property bool failStats: false

        function getTodayStats() {
            if (failStats) {
                operationFailed("统计查询失败")
            }
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0,
                     sessionCount: 0, pomodoroCount: 0 }
        }
        function getStreakDays() { return 0 }
        function getTotalFocusDuration() { return 0 }
        function getTodayTaskStats() { return { tasks: [], totalDuration: 0, taskCount: 0 } }
        function getDayStats(day) {
            if (failStats) {
                operationFailed("统计查询失败")
            }
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0,
                     sessionCount: 0 }
        }
        function getDayComparison(day) { return {} }
        function getWeekStats(start) { return [] }
        function getCategoryStats(startIso, endIso) { return { categories: [], totalDuration: 0 } }
    }

    QtObject {
        id: routineManager

        signal routinesChanged()
        signal operationFailed(string message)

        property bool failMaterialize: false

        function materializeToday() {
            if (failMaterialize) {
                operationFailed("每日例行生成失败：数据库被锁")
            }
        }
    }

    QtObject {
        id: goalService

        signal goalsChanged()
        signal operationFailed(string message)

        property bool failGoals: false
        property var goalsData: []

        function getGoals() {
            if (failGoals) {
                operationFailed("目标列表查询失败")
                return []
            }
            return goalsData
        }
        function getGoal(goalId) { return ({}) }
    }

    QtObject {
        id: scheduleService

        signal scheduleChanged()
        signal periodsChanged()
        signal operationFailed(string message)

        property bool failEntries: false

        function getEntriesForWeek(weekIndex) {
            if (failEntries) {
                operationFailed("课表查询失败")
                return []
            }
            return []
        }
        function getPeriods() { return [] }
        function findConflicts() { return [] }
    }

    QtObject {
        id: gapService

        signal gapsChanged()
        signal operationFailed(string message)

        function getReminderSummary() { return ({}) }
        function listGaps(statusFilter, categoryId, searchText, limit) { return [] }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged()

        function getAllCategories() { return [] }
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)
        signal restCompleted(int duration)

        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int elapsedSeconds: 0
        property int remainingSeconds: 0
        property int targetSeconds: 0
        property int mode: 0
        property int phase: 0
        property string sessionLogicalDate: ""
    }

    QtObject {
        id: settings

        signal dailyFocusGoalChanged()

        property int dayStartHour: 4
        property bool reduceMotion: true
        property bool dashboardTimerVisible: true
        property int workMinutes: 25
        property int breakMinutes: 5
        property int lastMode: 0
        property string nickname: ""
        property string rolloverIgnoredDate: ""
        property string goalViewMode: "list"
        property string semesterStartDate: ""
        property int semesterWeeks: 16
        property string scheduleDisplayMode: "time"
        property bool scheduleShowWeekend: true

        function dailyFocusGoalMinutesForDate(isoDate) { return 0 }
    }

    Component {
        id: goalsComponent

        GoalsView {
            width: 900
            height: 660
            pageActive: false
            goalServiceRef: goalService
            categoryManagerRef: categoryManager
            settingsRef: settings
            logicalDayServiceRef: logicalDayService
        }
    }

    Component {
        id: dashboardComponent

        DashboardView {
            width: 1000
            height: 680
            pageActive: false
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            routineManagerRef: routineManager
            focusTimerRef: focusTimer
            categoryManagerRef: categoryManager
            settingsRef: settings
            nowProvider: function() { return testCase.fixedNow }
        }
    }

    Component {
        id: statisticsComponent

        StatisticsView {
            width: 900
            height: 700
            pageActive: false
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            focusTimerRef: focusTimer
            logicalDayServiceRef: logicalDayService
            appSettingsRef: settings
            categoryManagerRef: categoryManager
            currentDateOverride: testCase.fixedNow
        }
    }

    Component {
        id: weekComponent

        WeekPlanView {
            width: 1000
            height: 700
            pageActive: false
            taskManagerRef: taskManager
            logicalDayServiceRef: logicalDayService
            settingsRef: settings
            categoryManagerRef: categoryManager
            logicalNowProvider: function() { return testCase.fixedNow }
        }
    }

    Component {
        id: scheduleComponent

        SchedulePlanView {
            width: 1100
            height: 760
            pageActive: false
            scheduleServiceRef: scheduleService
            settingsRef: settings
            categoryManagerRef: categoryManager
            logicalDayServiceRef: logicalDayService
            logicalNowProvider: function() { return testCase.fixedNow }
        }
    }

    Component {
        id: todayComponent

        TodayTaskView {
            width: 860
            height: 620
            pageActive: false
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            routineManagerRef: routineManager
            focusTimerRef: focusTimer
            logicalDayServiceRef: logicalDayService
            categoryManagerRef: categoryManager
            knowledgeGapServiceRef: gapService
            settingsRef: settings
        }
    }

    function init() {
        taskManager.failTodayTasks = false
        taskManager.failOverdue = false
        taskManager.failWeekTasks = false
        statisticsService.failStats = false
        routineManager.failMaterialize = false
        goalService.failGoals = false
        goalService.goalsData = []
        scheduleService.failEntries = false
    }

    function test_goalsActivationFailureKeepsGoalsAndShowsError() {
        goalService.goalsData = [{ id: 1, title: "完成课程", categoryId: 7, targetMinutes: 100,
                                   doneMinutes: 62, percent: 62, achieved: false, forecastDays: 21 }]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view)
        view.pageActive = true
        compare(view.goals.length, 1)
        view.pageActive = false

        goalService.failGoals = true
        view.pageActive = true
        compare(view.errorText, "目标列表查询失败")
        // 查询失败不能伪装成「用户没有目标」，否则空状态会引导他重复新建。
        compare(view.goals.length, 1)
    }

    function test_dashboardActivationTaskFailureIsShown() {
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        taskManager.failTodayTasks = true
        view.pageActive = true
        compare(view.loadError, "今日任务查询失败")
    }

    function test_dashboardRoutineFailureSurvivesTheTaskReload() {
        // 刷新先补齐例行任务再读任务列表。读任务前曾先清错，于是刚报出的例行生成失败被自己抹掉。
        var view = createTemporaryObject(dashboardComponent, testCase)
        verify(view)
        routineManager.failMaterialize = true
        view.pageActive = true
        compare(view.loadError, "每日例行生成失败：数据库被锁")
    }

    function test_statisticsActivationFailureIsShown() {
        var view = createTemporaryObject(statisticsComponent, testCase)
        verify(view)
        statisticsService.failStats = true
        view.pageActive = true
        compare(view.loadError, "统计查询失败")
    }

    function test_weekPlanActivationFailureIsShown() {
        var view = createTemporaryObject(weekComponent, testCase)
        verify(view)
        taskManager.failWeekTasks = true
        view.pageActive = true
        compare(view.loadError, "本周任务查询失败")
    }

    function test_scheduleActivationFailureIsShown() {
        var view = createTemporaryObject(scheduleComponent, testCase)
        verify(view)
        scheduleService.failEntries = true
        view.pageActive = true
        compare(view.loadError, "课表查询失败")
    }

    function test_todayActivationTaskFailureIsShown() {
        var view = createTemporaryObject(todayComponent, testCase)
        verify(view)
        taskManager.failTodayTasks = true
        view.pageActive = true
        compare(view.loadError, "今日任务查询失败")
    }

    function test_todayOverdueFailureSurvivesTheTaskReload() {
        var view = createTemporaryObject(todayComponent, testCase)
        verify(view)
        taskManager.failOverdue = true
        view.pageActive = true
        compare(view.loadError, "逾期任务查询失败")
    }

    function test_hiddenPagesStillIgnoreFailuresFromOtherPages() {
        // 门禁本身的理由不变：别的页面吞掉的失败不能在隐藏的常驻页上留下过期红条。
        var view = createTemporaryObject(weekComponent, testCase)
        verify(view)
        taskManager.operationFailed("别处的失败")
        compare(view.loadError, "")
        var dashboard = createTemporaryObject(dashboardComponent, testCase)
        routineManager.operationFailed("别处的失败")
        compare(dashboard.loadError, "")
    }
}
