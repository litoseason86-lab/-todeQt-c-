import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 今日任务页的「完成」弹窗接线：点卡片上的「完成」→ 写下记录 → 一次写库完成，
// 与复选框共用完成动画的延迟刷新和撤销入口；以及编辑弹窗把完成记录原样转交给服务。
TestCase {
    id: testCase
    name: "TodayCompleteWithNote"
    when: windowShown
    visible: true
    width: 900
    height: 700

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
        property var updateCalls: []

        function getTodayTasks() {
            testCase.todayQueryCount += 1
            return taskManager.rows
        }
        function getOverdueUncompletedTasks() { return [] }
        function setTaskCompleted(id, completed) { return true }
        function deleteTask(id) { return true }
        function getTask(id) { return ({}) }

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

        // 记下实参个数：第 7 个参数「没传」和「传了 undefined」对服务来说都是保持不变，
        // 但宿主必须真的把它转交过来，而不是在中间丢掉或包成字符串。
        function updateTask(id, title, categoryId, date, estimatedMinutes, notes, completionNote) {
            taskManager.updateCalls = taskManager.updateCalls.concat([{
                id: id, argCount: arguments.length, completionNote: completionNote
            }])
            taskManager.tasksChanged()
            return true
        }
    }

    QtObject {
        id: statisticsService
        function getTodayStats() { return {} }
    }

    QtObject {
        id: routineManager
        function materializeToday() { return true }
    }

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
        property bool reduceMotion: false
        signal changed()
        function dailyFocusGoalMinutesForDate(iso) { return 0 }
    }

    Component {
        id: viewComponent

        TodayTaskView {
            interactionCoordinatorRef: coordinator
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
        taskManager.updateCalls = []
        taskManager.rows = [makeTask(51, "数据结构", false),
                            makeTask(52, "高等数学", true, "做完极限")]
    }

    function createView() {
        const view = createTemporaryObject(viewComponent, testCase)
        verify(view !== null)
        tryCompare(findChild(view, "todayTaskList"), "count", 2)
        return view
    }

    function rowAt(view, index) {
        const row = findChild(view, "todayTaskList").itemAtIndex(index)
        verify(row !== null)
        return row
    }

    function test_submitCompletesWithNoteAndOffersUndo() {
        const view = testCase.createView()
        const undoSpy = createTemporaryObject(spyComponent, testCase,
                                              { target: view, signalName: "taskCompletionUndoable" })
        const row = testCase.rowAt(view, 0)
        const dialog = findChild(view, "todayCompleteTaskDialog")
        verify(dialog !== null)

        mouseClick(findChild(row, "taskCompleteButton"))
        tryCompare(dialog, "opened", true, 3000)
        compare(dialog.taskId, 51)
        compare(dialog.taskTitle, "数据结构")
        // 弹窗开着时登记在协调器上：用户打字期间列表不会被刷新重建。
        compare(coordinator.refreshBlocked, true)

        findChild(dialog, "completeNoteField").text = "做完第三章习题"
        const readsBefore = testCase.todayQueryCount
        mouseClick(findChild(dialog, "completeConfirmButton"))

        // 一次写库，完成与记录一起落地。
        compare(taskManager.completeCalls.length, 1)
        compare(taskManager.completeCalls[0].id, 51)
        compare(taskManager.completeCalls[0].note, "做完第三章习题")
        // 与复选框一样给撤销入口。
        compare(undoSpy.count, 1)
        compare(undoSpy.signalArguments[0][0], 51)
        compare(undoSpy.signalArguments[0][1], "数据结构")
        // 这一行当场进入完成态、放完成动画；服务同步发来的 tasksChanged 不能立刻重建列表，
        // 否则正在放动画的行会被销毁。
        compare(row.visualTaskCompleted, true)
        compare(view.completionRefreshDelayActive, true)
        compare(testCase.todayQueryCount, readsBefore)
        tryCompare(dialog, "opened", false, 3000)
        compare(coordinator.refreshBlocked, false)

        // 动画放完才重载，新的一行带出刚写下的记录。
        tryCompare(view, "completionRefreshDelayActive", false, 3000)
        verify(testCase.todayQueryCount > readsBefore)
        const reloaded = testCase.rowAt(view, 0)
        compare(reloaded.taskCompleted, true)
        compare(reloaded.completionNote, "做完第三章习题")
        compare(reloaded.showsCompletionNote, true)
    }

    // 完成正在计时的任务时，主窗口会在同一次点击里结束专注（MainWindow.handleTaskCompletedByUser），
    // 计时器随即同步发 focusCompleted。这条刷新也得等完成动画放完，否则正在放动画的行会被销毁。
    function test_focusEndedByTheSameClickWaitsForTheAnimation() {
        const view = testCase.createView()
        // 替主窗口接上：收到撤销信号就同步发 focusCompleted，与真实接线的时序一致。
        view.taskCompletionUndoable.connect(function () { focusTimer.focusCompleted(1500) })
        const row = testCase.rowAt(view, 0)
        const dialog = findChild(view, "todayCompleteTaskDialog")
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
        const row = testCase.rowAt(view, 0)
        const dialog = findChild(view, "todayCompleteTaskDialog")

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

    function test_completedRowShowsRecordInsteadOfButton() {
        const view = testCase.createView()
        const pendingRow = testCase.rowAt(view, 0)
        const completedRow = testCase.rowAt(view, 1)

        // 按钮由今日页打开（其它页面默认关着）；已完成的行不再露出。
        compare(pendingRow.showCompleteWithNote, true)
        compare(findChild(completedRow, "taskCompleteButton").visible, false)
        compare(completedRow.showsCompletionNote, true)
        compare(findChild(completedRow, "taskCompletionNoteLine").text, "完成：做完极限")
    }

    function test_leavingPageClosesDialogAndReleases() {
        const view = testCase.createView()
        const dialog = findChild(view, "todayCompleteTaskDialog")

        mouseClick(findChild(testCase.rowAt(view, 0), "taskCompleteButton"))
        tryCompare(dialog, "opened", true, 3000)
        compare(coordinator.refreshBlocked, true)

        // 切走页面时弹窗必须收起并释放登记，不能留一个看不见的弹窗挡住列表刷新。
        view.pageActive = false
        tryCompare(dialog, "visible", false, 3000)
        compare(coordinator.refreshBlocked, false)
        compare(taskManager.completeCalls.length, 0)
    }

    function test_editDialogPassesCompletionNoteThrough() {
        const view = testCase.createView()
        const editDialog = findChild(view, "todayEditTaskDialog")
        verify(editDialog !== null)

        // 已完成：记录栏改过的内容作为第 7 个参数交给 TaskManager。
        mouseClick(findChild(testCase.rowAt(view, 1), "taskEditButton"))
        tryCompare(editDialog, "opened", true, 3000)
        compare(editDialog.editingCompleted, true)
        compare(findChild(editDialog, "editCompletionNoteField").text, "做完极限")
        findChild(editDialog, "editCompletionNoteField").text = "做完极限和导数"
        mouseClick(findChild(editDialog, "editConfirmButton"))
        compare(taskManager.updateCalls.length, 1)
        compare(taskManager.updateCalls[0].id, 52)
        compare(taskManager.updateCalls[0].argCount, 7)
        compare(taskManager.updateCalls[0].completionNote, "做完极限和导数")
        tryCompare(editDialog, "visible", false, 3000)
        tryCompare(coordinator, "refreshBlocked", false, 3000)

        // 未完成：第 7 个参数必须原样是 undefined（= 保持不变），不能被包成字符串 "undefined"。
        tryCompare(findChild(view, "todayTaskList"), "count", 2)
        mouseClick(findChild(testCase.rowAt(view, 0), "taskEditButton"))
        tryCompare(editDialog, "opened", true, 3000)
        compare(editDialog.editingCompleted, false)
        mouseClick(findChild(editDialog, "editConfirmButton"))
        compare(taskManager.updateCalls.length, 2)
        compare(taskManager.updateCalls[1].id, 51)
        compare(taskManager.updateCalls[1].argCount, 7)
        compare(typeof taskManager.updateCalls[1].completionNote, "undefined")
    }
}
