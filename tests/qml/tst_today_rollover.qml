import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

TestCase {
    id: testCase
    name: "TodayRollover"
    when: windowShown
    width: 860
    height: 620

    QtObject {
        id: taskManager

        signal tasksChanged

        property var todayTasksData: []
        property var overdueData: []
        property var movedIds: []
        property int moveCalls: 0
        property int todayCalls: 0

        function getTodayTasks() {
            todayCalls += 1
            return todayTasksData
        }

        function getOverdueUncompletedTasks() {
            return overdueData
        }

        function moveTasksToToday(ids) {
            moveCalls += 1
            movedIds = ids
            overdueData = []
            return true
        }

        function getTasksByDate(date) {
            return []
        }

        function getWeekTasks(weekStart) {
            return []
        }

        function getMonthTasks(year, month) {
            return []
        }

        function addTask(title, date, categoryId) {
            return true
        }

        function setTaskCompleted(id, completed) {
            return true
        }

        function deleteTask(id) {
            return true
        }

        function updateTask(id, title, categoryId, date) {
            return true
        }
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return {
                totalDuration: 0,
                completedTasks: 0,
                totalTasks: 0,
                completionRate: 0
            }
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
        property int mode: 0
        property int phase: 0
    }

    QtObject {
        id: settingsMock

        property string rolloverIgnoredDate: ""
    }

    TodayTaskView {
        id: view
        width: testCase.width
        height: testCase.height
        settingsRef: settingsMock
    }

    function init() {
        taskManager.todayTasksData = []
        taskManager.overdueData = []
        taskManager.movedIds = []
        taskManager.moveCalls = 0
        taskManager.todayCalls = 0
        settingsMock.rolloverIgnoredDate = ""
        view.pendingDeleteTaskId = -1
        view.refresh()
        wait(20)
    }

    function makeOverdue(id, title) {
        return {
            id: id,
            title: title,
            completed: false,
            date: "2026-07-01",
            categoryId: -1
        }
    }

    function test_bannerActiveWhenOverdueExists() {
        compare(view.rolloverBannerActive, false)

        taskManager.overdueData = [makeOverdue(11, "上周残留"), makeOverdue(12, "昨天残留")]
        view.refresh()
        wait(20)

        compare(view.rolloverBannerActive, true)
        const text = findChild(view, "rolloverBannerText")
        verify(text)
        verify(text.text.indexOf("2") !== -1)
    }

    function test_moveAllSendsIdsAndHidesBanner() {
        taskManager.overdueData = [makeOverdue(11, "上周残留"), makeOverdue(12, "昨天残留")]
        view.refresh()
        wait(20)

        view.moveOverdueToToday()
        wait(20)

        compare(taskManager.moveCalls, 1)
        compare(taskManager.movedIds.length, 2)
        compare(Number(taskManager.movedIds[0]), 11)
        compare(Number(taskManager.movedIds[1]), 12)
        compare(view.rolloverBannerActive, false)
    }

    function test_ignoreHidesForTodayAndPersistsDate() {
        taskManager.overdueData = [makeOverdue(11, "上周残留")]
        view.refresh()
        wait(20)
        compare(view.rolloverBannerActive, true)

        view.ignoreOverdueForToday()
        wait(20)

        compare(settingsMock.rolloverIgnoredDate, view.todayIsoDate())
        compare(view.rolloverBannerActive, false)

        view.refresh()
        wait(20)
        compare(view.rolloverBannerActive, false)
    }

    function test_pendingDeleteFiltersRow() {
        taskManager.todayTasksData = [
            { id: 31, title: "留下", completed: false, date: "2026-07-06", categoryId: -1 },
            { id: 32, title: "待删", completed: false, date: "2026-07-06", categoryId: -1 }
        ]
        view.refresh()
        wait(20)
        compare(view.tasks.length, 2)

        view.pendingDeleteTaskId = 32
        wait(20)
        compare(view.tasks.length, 1)
        compare(Number(view.tasks[0].id), 31)

        view.pendingDeleteTaskId = -1
        wait(20)
        compare(view.tasks.length, 2)
    }

    function test_taskListContainerIsGlass() {
        var container = findChild(view, "todayTaskListContainer")
        verify(container)
        verify(Qt.colorEqual(container.color, Theme.glassCard))
        verify(Qt.colorEqual(container.border.color, Theme.glassBorder))
    }

    function test_logicalDayChangedTriggersRefresh() {
        var before = taskManager.todayCalls

        logicalDayService.changed()

        verify(taskManager.todayCalls > before)
    }
}
