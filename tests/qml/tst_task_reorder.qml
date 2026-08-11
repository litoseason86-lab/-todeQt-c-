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
        compare(view.dropTargetIndex, 0)
        // 拖动期间模型引用必须原样不动——换模型会让整片 delegate 连同阴影层重建。
        compare(Number(view.tasks[0].id), 1)
        // 关键：拖动过程中一次都不写库。每次移动都落库会在一次拖动里产生几十次
        // 事务，中途松不开手还回不去。
        compare(testCase.reorderCalls.length, 0)

        view.commitReorder()
        compare(testCase.reorderCalls.length, 1)
        compare(testCase.reorderCalls[0].ids, [3, 1, 2])
        // 落点状态必须复位，否则下一次拖动会带着上次的残留目标。
        compare(view.dropTargetIndex, -1)
        compare(view.draggingTaskId, -1)
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

    function test_drop_index_is_correct_after_scrolling_a_long_list() {
        // 长列表会虚拟化：屏幕外的 delegate 根本没被创建。若按"逐个问 delegate 要高度"
        // 累加位置，未创建的行会被当成高度 0，滚动之后算出的落点整体偏上。
        var many = []
        for (var i = 1; i <= 60; ++i) {
            many.push(makeTask(i, "任务" + i))
        }
        taskManager.rows = many

        var view = createTemporaryObject(viewComponent, testCase)
        verify(!!view, "Component exists")
        view.refresh()
        wait(80)

        var list = findChild(view, "todayTaskList")
        verify(!!list, "Object exists")
        list.contentY = list.contentHeight - list.height
        wait(60)
        verify(list.contentY > 0, "列表没有滚动，用例失去意义")

        // 把第 1 条拖到当前可见区域的中间位置。用 indexAt 独立求出那里到底是第几条，
        // 作为不依赖被测实现的参照。
        var probeY = list.contentY + list.height / 2
        var expected = list.indexAt(list.width / 2, probeY)
        verify(expected >= 0, "参照点没有命中任何行")

        view.beginReorder(1)
        view.updateReorder(1, probeY)
        compare(view.dropTargetIndex, expected, "滚动后落点算错")
    }
}
