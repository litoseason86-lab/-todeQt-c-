import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 仪表盘任务面板的「完成」弹窗接线：与今日任务页同一套——点「完成」→ 写下记录 → 一次写库完成，
// 与复选框共用完成动画的延迟刷新和撤销入口；「已完成」筛选下的只读行不出现这个按钮。
TestCase {
    id: testCase
    name: "DashboardCompleteWithNote"
    when: windowShown
    visible: true
    width: 900
    height: 720

    property int todayQueryCount: 0

    // 按登记对象逐条记账，行为贴近 C++ 协调器：谁登记的只能由谁（或它的销毁）释放。
    QtObject {
        id: coordinator

        property var owners: []
        readonly property bool refreshBlocked: owners.length > 0
        property string lastError: ""
        signal changed()

        function register(owner) {
            owners = owners.concat([owner])
            changed()
        }
        function beginEdit(owner, id, source) {
            for (var i = 0; i < taskManager.rows.length; ++i) {
                if (Number(taskManager.rows[i].id) === id) {
                    register(owner)
                    return taskManager.rows[i]
                }
            }
            lastError = "任务已不存在"
            return ({})
        }
        function beginDrag(owner, id, source) {
            register(owner)
            return true
        }
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

        readonly property int maxNotesLength: 2000
        property var rows: []
        property var completeCalls: []
        property bool completeResult: true

        function getTodayTasks() {
            testCase.todayQueryCount += 1
            return taskManager.rows
        }
        function getOverdueUncompletedTasks() { return [] }
        function setTaskCompleted(id, completed) { return true }
        function getTask(id) { return ({}) }
        function updateTask() { return true }

        // 与真实服务同一契约：写库成功后同步发 tasksChanged，失败不发、不改数据。
        function completeTaskWithNote(id, note) {
            taskManager.completeCalls = taskManager.completeCalls.concat([{ id: id, note: note }])
            if (!taskManager.completeResult)
                return false
            taskManager.rows = taskManager.rows.map(function (row) {
                return Number(row.id) === id
                        ? Object.assign({}, row, { completed: true, completionNote: note })
                        : row
            })
            taskManager.tasksChanged()
            return true
        }
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0,
                     sessionCount: 0, pomodoroCount: 0 }
        }
        function getStreakDays() { return 0 }
        function getTotalFocusDuration() { return 0 }
        function getTodayTaskStats() { return { tasks: [], totalDuration: 0, taskCount: 0 } }
    }

    QtObject {
        id: routineManager
        function materializeToday() { return true }
    }

    QtObject {
        id: categoryManager
        signal categoriesChanged()
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)

        property int phase: 0
        property int mode: 0
        property bool hasActiveSession: false
        property bool isRunning: false
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
        property string sessionLogicalDate: "2026-09-23"
        property int targetSeconds: 0
        property string currentTaskTitle: ""
    }

    QtObject {
        id: appSettings

        signal dailyFocusGoalChanged()

        property int dayStartHour: 4
        property bool reduceMotion: false
        property bool dashboardTimerVisible: true
        property int workMinutes: 25
        property int breakMinutes: 5
        property int lastMode: 0
        property string nickname: ""

        function dailyFocusGoalMinutesForDate(isoDate) { return 0 }
    }

    Component {
        id: viewComponent

        DashboardView {
            // 宽度低于 900 时专注面板收起，任务面板占满，行上按钮都能露出来。
            width: 860
            height: 680
            interactionCoordinatorRef: coordinator
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            routineManagerRef: routineManager
            focusTimerRef: focusTimer
            categoryManagerRef: categoryManager
            settingsRef: appSettings
            nowProvider: function () { return new Date(2026, 8, 23, 12, 0, 0) }
        }
    }

    Component {
        id: spyComponent
        SignalSpy { }
    }

    function makeTask(id, title, completed, completionNote) {
        return { id: id, title: title, completed: !!completed, date: "2026-09-23",
                 estimatedMinutes: 0, focusedMinutes: 0, notes: "",
                 completionNote: completionNote || "", categoryText: "", categoryId: -1 }
    }

    function init() {
        coordinator.owners = []
        coordinator.lastError = ""
        testCase.todayQueryCount = 0
        taskManager.completeCalls = []
        taskManager.completeResult = true
        taskManager.rows = [makeTask(51, "数据结构", false),
                            makeTask(52, "高等数学", true, "做完极限")]
    }

    // 任务行由 Repeater 生成，不在 ListView 里，只能沿可视子树按任务编号找。
    // 不借用视图自己的 taskRowById：那正是被测的查找逻辑之一。
    function rowFor(item, id) {
        if (!item)
            return null
        if (item.taskId === id && item.showCompleteWithNote !== undefined)
            return item
        const kids = item.children ? item.children.length : 0
        for (let i = 0; i < kids; ++i) {
            const found = testCase.rowFor(item.children[i], id)
            if (found)
                return found
        }
        return null
    }

    function createView() {
        const view = createTemporaryObject(viewComponent, testCase)
        verify(view !== null)
        tryVerify(function () { return testCase.rowFor(view, 51) !== null && testCase.rowFor(view, 52) !== null })
        // Repeater 行建好时列布局还没排完，行宽仍是隐式宽度，按钮挤在左侧；
        // 这时点击会落空。等行宽撑到面板可用宽度再交给用例操作。
        const scroll = findChild(view, "dashboardTaskScrollView")
        verify(scroll !== null)
        tryVerify(function () {
            return testCase.rowFor(view, 51).width === scroll.availableWidth && scroll.availableWidth > 300
        })
        return view
    }

    function test_submitCompletesWithNoteAndOffersUndo() {
        const view = testCase.createView()
        const undoSpy = createTemporaryObject(spyComponent, testCase,
                                              { target: view, signalName: "taskCompletionUndoable" })
        const row = testCase.rowFor(view, 51)
        const dialog = findChild(view, "dashboardCompleteTaskDialog")
        verify(dialog !== null)

        mouseClick(findChild(row, "taskCompleteButton"))
        tryCompare(dialog, "opened", true, 3000)
        compare(dialog.taskId, 51)
        compare(dialog.taskTitle, "数据结构")
        // 弹窗开着时登记在协调器上：用户打字期间任务面板不会被刷新重建。
        compare(coordinator.refreshBlocked, true)

        findChild(dialog, "completeNoteField").text = "做完第三章习题"
        const readsBefore = testCase.todayQueryCount
        mouseClick(findChild(dialog, "completeConfirmButton"))

        // 一次写库，完成与记录一起落地。
        compare(taskManager.completeCalls.length, 1)
        compare(taskManager.completeCalls[0].id, 51)
        compare(taskManager.completeCalls[0].note, "做完第三章习题")
        // 与复选框一样给撤销入口，标题取自这一行。
        compare(undoSpy.count, 1)
        compare(undoSpy.signalArguments[0][0], 51)
        compare(undoSpy.signalArguments[0][1], "数据结构")
        // 这一行当场进入完成态、放完成动画；服务同步发来的 tasksChanged 不能立刻重建面板，
        // 否则正在放动画的行会被销毁。
        compare(row.visualTaskCompleted, true)
        compare(view.completionRefreshDelayActive, true)
        compare(testCase.todayQueryCount, readsBefore)
        tryCompare(dialog, "opened", false, 3000)
        compare(coordinator.refreshBlocked, false)

        // 动画放完才重载，新的一行带出刚写下的记录。
        tryCompare(view, "completionRefreshDelayActive", false, 3000)
        verify(testCase.todayQueryCount > readsBefore)
        tryVerify(function () {
            const reloaded = testCase.rowFor(view, 51)
            return reloaded !== null && reloaded.taskCompleted && reloaded.completionNote === "做完第三章习题"
        })
        compare(testCase.rowFor(view, 51).showsCompletionNote, true)
    }

    // 完成正在计时的任务时，主窗口会在同一次点击里结束专注（MainWindow.handleTaskCompletedByUser），
    // 计时器随即同步发 focusCompleted。这条刷新也得等完成动画放完，否则正在放动画的行会被销毁。
    function test_focusEndedByTheSameClickWaitsForTheAnimation() {
        const view = testCase.createView()
        // 替主窗口接上：收到撤销信号就同步发 focusCompleted，与真实接线的时序一致。
        view.taskCompletionUndoable.connect(function () { focusTimer.focusCompleted(1500) })
        const row = testCase.rowFor(view, 51)
        const dialog = findChild(view, "dashboardCompleteTaskDialog")
        mouseClick(findChild(row, "taskCompleteButton"))
        tryCompare(dialog, "opened", true, 3000)
        const readsBefore = testCase.todayQueryCount
        mouseClick(findChild(dialog, "completeConfirmButton"))

        compare(view.completionRefreshDelayActive, true)
        // 排队刷新走 Qt.callLater，下一轮事件循环就会执行；等过这一轮再看。
        wait(60)
        compare(testCase.todayQueryCount, readsBefore)
        compare(row.visualTaskCompleted, true)
        // 动画放完后的整页刷新一并重读专注数据，所以跳过的那次刷新不会漏掉什么。
        tryCompare(view, "completionRefreshDelayActive", false, 3000)
        verify(testCase.todayQueryCount > readsBefore)
    }

    function test_failedCompletionKeepsRowAndDialog() {
        taskManager.completeResult = false
        const view = testCase.createView()
        const undoSpy = createTemporaryObject(spyComponent, testCase,
                                              { target: view, signalName: "taskCompletionUndoable" })
        const row = testCase.rowFor(view, 51)
        const dialog = findChild(view, "dashboardCompleteTaskDialog")

        mouseClick(findChild(row, "taskCompleteButton"))
        tryCompare(dialog, "opened", true, 3000)
        findChild(dialog, "completeNoteField").text = "做完第三章习题"
        mouseClick(findChild(dialog, "completeConfirmButton"))

        compare(taskManager.completeCalls.length, 1)
        // 写库失败：弹窗留着让用户重试；行不能先画成已完成，也不能给「撤销」。
        compare(dialog.opened, true)
        compare(dialog.errorText, "保存失败，请检查数据库后重试")
        compare(row.visualTaskCompleted, false)
        compare(undoSpy.count, 0)
        // 延迟刷新要跟着解除，否则之后别处的变更都进不来。
        compare(view.completionRefreshDelayActive, false)

        dialog.close()
        tryCompare(dialog, "visible", false, 3000)
        compare(coordinator.refreshBlocked, false)
    }

    function test_buttonFollowsFilterAndCompletion() {
        const view = testCase.createView()

        // 「全部」筛选：未完成的行给出「完成」；已完成的行不再露出按钮，改为显示记录。
        compare(testCase.rowFor(view, 51).showCompleteWithNote, true)
        const completedRow = testCase.rowFor(view, 52)
        compare(findChild(completedRow, "taskCompleteButton").visible, false)
        compare(completedRow.showsCompletionNote, true)
        compare(findChild(completedRow, "taskCompletionNoteLine").text, "完成：做完极限")

        // 「已完成」筛选是只读紧凑行，不需要再完成一次。
        view.filterMode = "done"
        tryVerify(function () {
            const row = testCase.rowFor(view, 52)
            return row !== null && row.compact
        })
        compare(testCase.rowFor(view, 52).showCompleteWithNote, false)
    }

    function test_leavingPageClosesDialogAndReleases() {
        const view = testCase.createView()
        const dialog = findChild(view, "dashboardCompleteTaskDialog")

        mouseClick(findChild(testCase.rowFor(view, 51), "taskCompleteButton"))
        tryCompare(dialog, "opened", true, 3000)
        compare(coordinator.refreshBlocked, true)

        // 切走页面时弹窗必须收起并释放登记，不能留一个看不见的弹窗挡住面板刷新。
        view.pageActive = false
        tryCompare(dialog, "visible", false, 3000)
        compare(coordinator.refreshBlocked, false)
        compare(taskManager.completeCalls.length, 0)
    }
}
