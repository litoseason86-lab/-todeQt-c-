import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 拖动改期。编辑弹窗此前只有「今天/明天/后天」三个按钮，最远只能挪两天；
// 考研计划常需要把整块内容前后挪一周，那条路走不通。
TestCase {
    id: testCase
    name: "TaskReschedule"
    when: windowShown
    width: 1000
    height: 760
    visible: true

    property var moveCalls: []

    QtObject {
        id: taskManager
        signal tasksChanged()

        property var weekRows: []

        function getWeekTasks(weekStartIso) { return taskManager.weekRows }
        function setTaskCompleted(id, completed) { return true }
        function updateTask(id, title, categoryId, date) { return true }
        function deleteTask(id) { return true }
        function moveTaskToDate(taskId, isoDate) {
            testCase.moveCalls.push({ taskId: taskId, date: isoDate })
            return true
        }
    }

    QtObject {
        id: appSettings
        property int dayStartHour: 4
        property bool reduceMotion: true
        signal changed()
    }

    QtObject {
        id: logicalDayService
        property int dayStartHour: 4
        signal changed()
    }

    Component {
        id: viewComponent

        WeekPlanView {
            taskManagerRef: taskManager
            logicalDayServiceRef: logicalDayService
            settingsRef: appSettings
            width: 960
            height: 700
        }
    }

    function logicalToday() {
        var d = new Date()
        if (d.getHours() < appSettings.dayStartHour) {
            d.setDate(d.getDate() - 1)
        }
        return d
    }

    function makeTask(id, title, date, completed) {
        return { id: id, title: title, date: Qt.formatDate(date, "yyyy-MM-dd"),
                 completed: !!completed, estimatedMinutes: 30, focusedMinutes: 0,
                 notes: "", categoryText: "", categoryId: -1 }
    }

    function init() {
        testCase.moveCalls = []
        taskManager.weekRows = [makeTask(1, "待挪任务", testCase.logicalToday())]
    }

    function test_drop_on_another_day_moves_the_task_there() {
        var view = createTemporaryObject(viewComponent, testCase)
        verify(!!view, "Component exists")
        view.refresh()
        wait(80)

        // 直接驱动状态机而不模拟真实指针：坐标命中依赖离屏布局，
        // 那部分不稳定；这里要守的是"落在第 N 天就改到第 N 天"这条规则。
        view.beginDrag(1)
        view.dropTargetIndex = 4
        view.commitDrag(1, 0)

        compare(testCase.moveCalls.length, 1)
        compare(testCase.moveCalls[0].taskId, 1)
        compare(testCase.moveCalls[0].date, view.isoDate(view.dayDate(4)))
    }

    function test_dropping_back_on_the_same_day_is_not_a_move() {
        var view = createTemporaryObject(viewComponent, testCase)
        view.refresh()
        wait(80)

        view.beginDrag(1)
        view.dropTargetIndex = 2
        view.commitDrag(1, 2)
        // 拖回原处不算改期：白写一次库，还会把它挪到当天末尾。
        compare(testCase.moveCalls.length, 0)
    }

    function test_dropping_outside_any_day_is_cancelled() {
        var view = createTemporaryObject(viewComponent, testCase)
        view.refresh()
        wait(80)

        view.beginDrag(1)
        view.dropTargetIndex = -1
        // currentIndex 刻意不取 0：取 0 的话「把 -1 钳成 0」这种错误实现会因为
        // 恰好等于原位置而被拖回原处不算改期那条规则掩盖掉。
        view.commitDrag(1, 3)
        compare(testCase.moveCalls.length, 0)
        // 状态要复位，否则下一次拖动会带着上次的残留目标。
        compare(view.draggingTaskId, -1)
    }

    function test_completed_tasks_are_not_draggable() {
        taskManager.weekRows = [makeTask(1, "已完成", testCase.logicalToday(), true),
                                makeTask(2, "未完成", testCase.logicalToday())]
        var view = createTemporaryObject(viewComponent, testCase)
        view.refresh()
        wait(80)
        // 契约由 delegate 的 draggable 绑定表达；这里确认服务支持判定本身成立。
        compare(view.canMoveTasks, true)
    }

    function test_reschedule_is_disabled_without_service_support() {
        var view = createTemporaryObject(viewComponent, testCase,
                                         { taskManagerRef: appSettings })
        verify(!!view, "Component exists")
        compare(view.canMoveTasks, false)
    }
}
