import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 今日页知识缺口提示条的「全部加到今天」。
// 守两件事：已经转成任务、还没做完的条目不能再转一次；
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
        signal operationFailed(string message)

        // 不能叫 gaps：属性自带 gapsChanged 信号，和上面声明的服务信号重名，整个文件编译失败。
        property var candidates: []
        property var failingIds: []
        property var convertedIds: []
        property var summary: ({})

        function getReminderSummary() { return gapService.summary }
        function listGaps(statusFilter, categoryId, searchText, limit) { return gapService.candidates }
        function convertToTask(gapId, dateValue) {
            if (gapService.failingIds.indexOf(gapId) >= 0) {
                // 与真服务一致：先同步播报原因，再返回 -1。
                gapService.operationFailed("创建任务失败：磁盘已满")
                return -1
            }
            gapService.convertedIds = gapService.convertedIds.concat([gapId])
            return 100 + gapId
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

    function makeGap(id, fields) {
        var row = { id: id, title: "条目 " + id, status: 1, scheduled: true, dueToday: false,
                    overdue: false, linkedTaskId: 0, linkedTaskOpen: false, linkedTaskCompleted: false }
        for (var key in fields) {
            row[key] = fields[key]
        }
        return row
    }

    function dueSummary() {
        return { valid: true, dueToday: 1, overdue: 1, unscheduled: 0, openTotal: 4, oldestOverdueDays: 4 }
    }

    function init() {
        gapService.candidates = [
            testCase.makeGap(1, { overdue: true, linkedTaskId: 51, linkedTaskOpen: true }),
            testCase.makeGap(2, { overdue: true }),
            testCase.makeGap(3, { dueToday: true }),
            testCase.makeGap(4, {})
        ]
        gapService.failingIds = []
        gapService.convertedIds = []
        gapService.summary = testCase.dueSummary()
        view.knowledgeGapConvertError = ""
        view.refresh()
        convertedSpy.clear()
    }

    function test_skipsGapsWhoseTaskIsStillOpen() {
        view.convertDueGapsToTasks()
        // 1 号已经有一条没做完的任务，再转只会建出重复任务；4 号没到期，本来就不该转。
        compare(gapService.convertedIds, [2, 3])
        compare(convertedSpy.count, 1)
        compare(convertedSpy.signalArguments[0][0], 2)
        compare(view.knowledgeGapConvertError, "")
    }

    function test_partialFailureNamesCountAndReason() {
        gapService.failingIds = [3]
        view.convertDueGapsToTasks()
        compare(gapService.convertedIds, [2])
        // 成功的照常报数，失败的必须单独说出来：只报「已加 1 条」会让人以为整批都加上了。
        compare(convertedSpy.count, 1)
        compare(convertedSpy.signalArguments[0][0], 1)
        verify(view.knowledgeGapConvertError.indexOf("1 条") >= 0, view.knowledgeGapConvertError)
        verify(view.knowledgeGapConvertError.indexOf("磁盘已满") >= 0, view.knowledgeGapConvertError)
    }

    function test_totalFailureIsNotSilent() {
        gapService.failingIds = [2, 3]
        view.convertDueGapsToTasks()
        compare(convertedSpy.count, 0)
        verify(view.knowledgeGapConvertError.indexOf("磁盘已满") >= 0, view.knowledgeGapConvertError)
    }

    function test_failureSurvivesTaskListRefresh() {
        gapService.failingIds = [3]
        view.convertDueGapsToTasks()
        // 部分成功会触发任务列表刷新，而刷新成功会清掉 loadError。
        // 失败提示若也挂在 loadError 上，就会一闪而过。
        view.refresh()
        verify(view.knowledgeGapConvertError.length > 0)
    }

    function test_failureClearsOnceNothingIsDue() {
        gapService.failingIds = [3]
        view.convertDueGapsToTasks()
        verify(view.knowledgeGapConvertError.length > 0)

        gapService.summary = { valid: true, dueToday: 0, overdue: 0, unscheduled: 0, openTotal: 0,
                               oldestOverdueDays: 0 }
        view.loadKnowledgeGapSummary()
        compare(view.knowledgeGapConvertError, "")
    }
}
