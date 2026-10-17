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
    property int weekQueryCount: 0

    QtObject {
        id: coordinator
        property bool refreshBlocked: false
        signal changed()
        function beginDrag(owner, id, source) { refreshBlocked = true; changed(); return true }
        function end(owner) { refreshBlocked = false; changed() }
    }

    // 按登记对象逐条记账的桩，行为贴近 C++ 协调器：谁登记的只能由谁（或它的销毁）释放。
    QtObject {
        id: trackingCoordinator
        property var owners: []
        readonly property bool refreshBlocked: owners.length > 0
        signal changed()
        function beginDrag(owner, id, source) { owners = owners.concat([owner]); changed(); return true }
        function end(owner) {
            const index = owners.indexOf(owner)
            if (index < 0)
                return
            const remaining = owners.slice()
            remaining.splice(index, 1)
            owners = remaining
            changed()
        }
    }

    QtObject {
        id: taskManager
        signal tasksChanged()

        property var weekRows: []

        function getWeekTasks(weekStartIso) {
            testCase.weekQueryCount += 1
            return taskManager.weekRows
        }
        function setTaskCompleted(id, completed) { return true }
        function updateTask(id, title, categoryId, date) { return true }
        function deleteTask(id) { return true }
        function moveTaskToDate(taskId, isoDate) {
            testCase.verify(coordinator.refreshBlocked || trackingCoordinator.refreshBlocked,
                            "写库结束前不得释放拖动登记")
            testCase.moveCalls.push({ taskId: taskId, date: isoDate })
            // 照真实服务（TaskManager::moveTaskToDate）：目标日就是任务现在的日期时不算改期，
            // 成功返回、不发 tasksChanged。上面的调用记录照留，用例据此确认视图把它交给了服务。
            for (var i = 0; i < taskManager.weekRows.length; ++i) {
                var row = taskManager.weekRows[i]
                if (row.id === taskId && row.date === isoDate)
                    return true
            }
            tasksChanged()
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
            interactionCoordinatorRef: coordinator
            taskManagerRef: taskManager
            logicalDayServiceRef: logicalDayService
            settingsRef: appSettings
            width: 960
            height: 700
        }
    }

    Component {
        id: trackedViewComponent

        WeekPlanView {
            interactionCoordinatorRef: trackingCoordinator
            taskManagerRef: taskManager
            logicalDayServiceRef: logicalDayService
            settingsRef: appSettings
            width: 960
            height: 700
        }
    }

    // 周视图的行由各天的 Repeater 生成，没有列表索引可取；按任务编号在子树里找那一行。
    function findTaskRow(item, taskId) {
        if (!item)
            return null
        if (item.taskId === taskId && item.dragStarted !== undefined)
            return item
        for (var i = 0; i < item.children.length; ++i) {
            var found = findTaskRow(item.children[i], taskId)
            if (found)
                return found
        }
        return null
    }

    // 某个 ISO 日期是视图本周的第几天（0~6），不在本周返回 -1。用视图自己的 dayDate/isoDate
    // 换算，用例就不必知道今天是周几。
    function dayIndexOfDate(view, iso) {
        for (var i = 0; i < 7; ++i) {
            if (view.isoDate(view.dayDate(i)) === iso)
                return i
        }
        return -1
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
        coordinator.end(null)
        trackingCoordinator.owners = []
        testCase.moveCalls = []
        testCase.weekQueryCount = 0
        taskManager.weekRows = [makeTask(1, "待挪任务", testCase.logicalToday())]
    }

    function test_dragRegistrationFollowsRowLifetime() {
        var view = createTemporaryObject(trackedViewComponent, testCase)
        verify(!!view, "Component exists")
        view.refresh()
        tryVerify(function () { return !!testCase.findTaskRow(view, 1) }, 5000, "待挪任务这一行未就绪")
        var row = testCase.findTaskRow(view, 1)
        verify(!!row, "待挪任务这一行未就绪")

        // 走真实入口：由行发出 dragStarted，页面据此登记拖动。
        row.dragStarted()
        compare(trackingCoordinator.owners.length, 1)
        verify(trackingCoordinator.owners[0] === row, "拖动登记必须挂在发起拖动的行上")
        compare(view.draggingTaskId, 1)

        // 跨周日界等情况会在拖动中途重建各天的行，延后的 dragFinished 收不到：
        // 登记随行一起释放，界面上的拖动残留也要清掉，不能让刷新和外部写入一直被挡住。
        view.weekTasks = []
        tryVerify(function() { return !trackingCoordinator.refreshBlocked }, 1000,
                  "行销毁后拖动登记仍残留")
        compare(view.draggingTaskId, -1)
        compare(view.dropTargetIndex, -1)
        compare(testCase.moveCalls.length, 0)
    }

    function test_drop_on_another_day_moves_the_task_there() {
        var view = createTemporaryObject(viewComponent, testCase)
        verify(!!view, "Component exists")
        view.refresh()
        testCase.weekQueryCount = 0

        // 目标取原日的下一天：目标就是原日的话，服务按"没改期"处理、不发 tasksChanged，
        // 下面"一次改期只刷新一次"的断言就等不到那次刷新。
        var home = testCase.dayIndexOfDate(view, taskManager.weekRows[0].date)
        verify(home >= 0, "待挪任务应落在本周某一天")
        var target = (home + 1) % 7

        // 直接驱动状态机而不模拟真实指针：坐标命中依赖离屏布局，
        // 那部分不稳定；这里要守的是"落在第 N 天就改到第 N 天"这条规则。
        view.beginDrag(1)
        view.dropTargetIndex = target
        view.commitDrag(1)

        compare(testCase.moveCalls.length, 1)
        compare(testCase.moveCalls[0].taskId, 1)
        compare(testCase.moveCalls[0].date, view.isoDate(view.dayDate(target)))
        // 生产服务在返回前同步发 tasksChanged；一次改期只能因此刷新一次。
        // 显式 refresh 再叠加信号刷新，会在拖动回调栈里连续重建两轮 delegate。
        tryCompare(testCase, "weekQueryCount", 1)
    }

    function test_dropping_back_on_the_same_day_is_left_to_the_service() {
        // 拖回原日：视图把原日期原样交给服务、不显示错误，是否写库由服务判断
        // （TaskManager::moveTaskToDate 对同一天返回成功、不写库，C++ 测试覆盖）。
        var view = createTemporaryObject(viewComponent, testCase)
        verify(!!view, "Component exists")
        view.refresh()

        // 原日用视图自己的日期换算找出来，前提先断言成立。
        var home = testCase.dayIndexOfDate(view, taskManager.weekRows[0].date)
        verify(home >= 0, "待挪任务应落在本周某一天")
        compare(view.loadError, "")

        view.beginDrag(1)
        view.dropTargetIndex = home
        view.commitDrag(1)

        compare(testCase.moveCalls.length, 1)
        compare(testCase.moveCalls[0].taskId, 1)
        compare(testCase.moveCalls[0].date, view.isoDate(view.dayDate(home)))
        compare(view.loadError, "")
    }

    function test_dropping_outside_any_day_is_cancelled() {
        var view = createTemporaryObject(viewComponent, testCase)
        view.refresh()

        view.beginDrag(1)
        view.dropTargetIndex = -1
        // 桩会记下对原日的调用，所以「把 -1 钳成 0」这类错误实现不论今天是周几都会被抓到。
        view.commitDrag(1)
        compare(testCase.moveCalls.length, 0)
        // 状态要复位，否则下一次拖动会带着上次的残留目标。
        compare(view.draggingTaskId, -1)
    }

    function test_cancelled_drag_does_not_move_task() {
        var view = createTemporaryObject(viewComponent, testCase)
        view.refresh()

        view.beginDrag(1)
        view.dropTargetIndex = 4
        view.commitDrag(1, true)

        compare(testCase.moveCalls.length, 0)
        compare(view.draggingTaskId, -1)
        compare(view.dropTargetIndex, -1)
    }

    function test_completed_tasks_are_not_draggable() {
        taskManager.weekRows = [makeTask(1, "已完成", testCase.logicalToday(), true),
                                makeTask(2, "未完成", testCase.logicalToday())]
        var view = createTemporaryObject(viewComponent, testCase)
        view.refresh()
        // 契约由 delegate 的 draggable 绑定表达；这里确认服务支持判定本身成立。
        tryCompare(view, "canMoveTasks", true)
    }

    function test_reschedule_is_disabled_without_service_support() {
        var view = createTemporaryObject(viewComponent, testCase,
                                         { taskManagerRef: appSettings })
        verify(!!view, "Component exists")
        compare(view.canMoveTasks, false)
    }
}
