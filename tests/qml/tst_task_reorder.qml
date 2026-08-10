import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 同一天里的任务此前只能按创建时间排，十几条并列时无法表达「先做哪个」。
// 拖动排序的界面契约：拖动期间只在本地换位，松手才落库；已完成的不参与。
TestCase {
    id: testCase
    name: "TaskReorder"
    when: windowShown
    width: 900
    height: 700
    visible: true

    property var reorderCalls: []

    QtObject {
        id: taskManager
        signal tasksChanged()

        property var rows: []

        function getTodayTasks() { return taskManager.rows }
        function getOverdueUncompletedTasks() { return [] }
        function setTaskCompleted(id, completed) { return true }
        function updateTask(id, title, categoryId, date) { return true }
        function deleteTask(id) { return true }
        function reorderTasks(isoDate, ids) {
            testCase.reorderCalls.push({ date: isoDate, ids: ids })
            return true
        }
    }

    QtObject {
        id: statisticsService
        function getTodayTaskStats() { return { completedTasks: 0, totalTasks: 0 } }
        function getTodayStats() { return {} }
    }

    QtObject { id: routineManager; function materializeToday() { return true } }
    QtObject {
        id: focusTimer
        property int phase: 0
        property bool hasActiveSession: false
        property int elapsedSeconds: 0
        property int currentTaskId: -1
        signal focusCompleted(int duration)
    }
    QtObject {
        id: logicalDayService
        property int dayStartHour: 4
        signal changed()
    }
    QtObject {
        id: appSettings
        property int dayStartHour: 4
        property bool reduceMotion: true
        property string focusGoalDate: ""
        property int focusGoalMinutes: 0
        signal changed()
        function dailyFocusGoalMinutesForDate(iso) { return 0 }
    }

    Component {
        id: viewComponent

        TodayTaskView {
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            routineManagerRef: routineManager
            focusTimerRef: focusTimer
            logicalDayServiceRef: logicalDayService
            settingsRef: appSettings
            width: 860
            height: 640
        }
    }

    function makeTask(id, title, completed) {
        return { id: id, title: title, completed: !!completed, date: new Date(),
                 estimatedMinutes: 30, focusedMinutes: 0, notes: "",
                 categoryText: "", categoryId: -1 }
    }

    function init() {
        testCase.reorderCalls = []
        taskManager.rows = [makeTask(1, "甲"), makeTask(2, "乙"), makeTask(3, "丙")]
    }

    function test_drag_only_reorders_locally_until_released() {
        var view = createTemporaryObject(viewComponent, testCase)
        verify(!!view, "Component exists")
        view.refresh()
        wait(60)

        view.beginReorder(3)
        // 把丙拖到最上面。
        view.updateReorder(3, 0)
        compare(view.pendingOrder.length, 3)
        compare(Number(view.pendingOrder[0].id), 3)
        // 关键：拖动过程中一次都不写库。每次移动都落库会在一次拖动里产生几十次
        // 事务，中途松不开手还回不去。
        compare(testCase.reorderCalls.length, 0)

        view.commitReorder()
        compare(testCase.reorderCalls.length, 1)
        compare(testCase.reorderCalls[0].ids, [3, 1, 2])
        // 提交后本地覆盖数组必须清空，否则列表会一直显示拖动期间的快照，
        // 服务端的新顺序反而进不来。
        compare(view.pendingOrder.length, 0)
    }

    function test_completed_tasks_do_not_participate() {
        taskManager.rows = [makeTask(1, "甲"), makeTask(2, "已完成", true)]
        var view = createTemporaryObject(viewComponent, testCase)
        view.refresh()
        wait(60)

        var rows = findChild(view, "todayTaskList")
        verify(!!rows, "Object exists")
        // 已完成的任务本来就被排到末尾，允许拖动只会让用户以为能插回未完成那段。
        var first = rows.itemAtIndex(0)
        var second = rows.itemAtIndex(1)
        verify(!!first && !!second, "delegate 未就绪")
        compare(first.draggable, true)
        compare(second.draggable, false)
    }

    function test_reorder_is_disabled_without_service_support() {
        // 服务端没有 reorderTasks 时不该露出可拖动的行为。
        var view = createTemporaryObject(viewComponent, testCase, { taskManagerRef: statisticsService })
        verify(!!view, "Component exists")
        compare(view.canReorderTasks, false)
    }
}
