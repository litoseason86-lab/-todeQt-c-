import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 今日页知识缺口提示条的「全部加到今天」。
// 挑哪些条目、逐条转任务、汇总失败与原因的规则都在服务里（KnowledgeGapServiceTests 负责），
// 这里只守接线：点一次调一次服务，成功数原样发出，
// 转失败的条目必须明确报出来，不能只报成功的数量，让用户以为整批都加上了。
TestCase {
    id: testCase
    name: "TodayKnowledgeGapBanner"
    when: windowShown
    width: 860
    height: 620

    // 以下几个替身照搬 tst_today_rollover：今日页挂载时会逐个调用它们。
    QtObject {
        id: taskManager

        signal tasksChanged

        function getTodayTasks() { return [] }
        function getOverdueUncompletedTasks() { return [] }
        function moveTasksToToday(ids) { return true }
        function getTasksByDate(date) { return [] }
        function getWeekTasks(weekStart) { return [] }
        function getMonthTasks(year, month) { return [] }
        function addTask(title, date, categoryId) { return true }
        function setTaskCompleted(id, completed) { return true }
        function deleteTask(id) { return true }
        function updateTask(id, title, categoryId, date) { return true }
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged()
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 }
        }
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)

        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int elapsedSeconds: 0
        property int mode: 0
        property int phase: 0
    }

    QtObject {
        id: routineManager

        signal routinesChanged()

        function materializeToday() {
        }
    }

    QtObject {
        id: settingsMock

        property string rolloverIgnoredDate: ""
        property int dayStartHour: 4
    }

    QtObject {
        id: gapService

        signal gapsChanged()

        property var summary: ({})
        // 批量转换的返回值由用例设置；替身不重写服务的筛选规则，那是 C++ 测试的事。
        property var batchResult: ({ converted: 0, failed: 0, reason: "" })
        property int batchCalls: 0

        function getReminderSummary() { return gapService.summary }
        function convertDueGapsToTasks() {
            gapService.batchCalls += 1
            return gapService.batchResult
        }
    }

    TodayTaskView {
        id: view

        width: testCase.width
        height: testCase.height
        taskManagerRef: taskManager
        statisticsServiceRef: statisticsService
        routineManagerRef: routineManager
        focusTimerRef: focusTimer
        logicalDayServiceRef: logicalDayService
        categoryManagerRef: categoryManager
        knowledgeGapServiceRef: gapService
        settingsRef: settingsMock
    }

    SignalSpy {
        id: convertedSpy

        target: view
        signalName: "knowledgeGapsConverted"
    }

    function dueSummary() {
        return { valid: true, dueToday: 1, overdue: 1, unscheduled: 0, openTotal: 4, oldestOverdueDays: 4 }
    }

    function init() {
        gapService.batchResult = { converted: 0, failed: 0, reason: "" }
        gapService.batchCalls = 0
        gapService.summary = testCase.dueSummary()
        view.knowledgeGapConvertError = ""
        view.refresh()
        convertedSpy.clear()
    }

    function test_convertCallsServiceOnceAndReportsCount() {
        gapService.batchResult = { converted: 2, failed: 0, reason: "" }
        view.convertDueGapsToTasks()
        // 点一次只调一次服务；成功数原样发出，没有失败就不出现失败提示。
        compare(gapService.batchCalls, 1)
        compare(convertedSpy.count, 1)
        compare(convertedSpy.signalArguments[0][0], 2)
        compare(view.knowledgeGapConvertError, "")
    }

    function test_partialFailureNamesCountAndReason() {
        gapService.batchResult = { converted: 1, failed: 1, reason: "创建任务失败：磁盘已满" }
        view.convertDueGapsToTasks()
        // 成功的照常报数，失败的必须单独说出来：只报「已加 1 条」会让人以为整批都加上了。
        compare(convertedSpy.count, 1)
        compare(convertedSpy.signalArguments[0][0], 1)
        verify(view.knowledgeGapConvertError.indexOf("1 条") >= 0, view.knowledgeGapConvertError)
        verify(view.knowledgeGapConvertError.indexOf("磁盘已满") >= 0, view.knowledgeGapConvertError)
    }

    function test_totalFailureIsNotSilent() {
        gapService.batchResult = { converted: 0, failed: 2, reason: "创建任务失败：磁盘已满" }
        view.convertDueGapsToTasks()
        compare(convertedSpy.count, 0)
        verify(view.knowledgeGapConvertError.indexOf("2 条") >= 0, view.knowledgeGapConvertError)
        verify(view.knowledgeGapConvertError.indexOf("磁盘已满") >= 0, view.knowledgeGapConvertError)
    }

    function test_failureWithoutReasonSaysUnknown() {
        // 服务没给出原因时也不能留一句空话：提示里要明说「未知原因」。
        gapService.batchResult = { converted: 0, failed: 1, reason: "" }
        view.convertDueGapsToTasks()
        compare(convertedSpy.count, 0)
        verify(view.knowledgeGapConvertError.indexOf("1 条") >= 0, view.knowledgeGapConvertError)
        verify(view.knowledgeGapConvertError.indexOf("未知原因") >= 0, view.knowledgeGapConvertError)
    }

    function test_failureSurvivesTaskListRefresh() {
        gapService.batchResult = { converted: 1, failed: 1, reason: "创建任务失败：磁盘已满" }
        view.convertDueGapsToTasks()
        // 部分成功会触发任务列表刷新，而刷新成功会清掉 loadError。
        // 失败提示若也挂在 loadError 上，就会一闪而过。
        view.refresh()
        verify(view.knowledgeGapConvertError.length > 0)
    }

    function test_failureClearsOnceNothingIsDue() {
        gapService.batchResult = { converted: 1, failed: 1, reason: "创建任务失败：磁盘已满" }
        view.convertDueGapsToTasks()
        verify(view.knowledgeGapConvertError.length > 0)

        gapService.summary = { valid: true, dueToday: 0, overdue: 0, unscheduled: 0, openTotal: 0,
                               oldestOverdueDays: 0 }
        view.loadKnowledgeGapSummary()
        compare(view.knowledgeGapConvertError, "")
    }
}
