import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"

// 关闭动画期间的重复提交：8 个写入表单的统一门禁。
//
// Popup 的退出动画有 180~220ms，这段时间里弹窗还在响应键盘。用户按下回车（或 ⌘↩）
// 保存后，习惯性再按一次，第二次按键仍然打进同一个还没消失的表单里——没有门禁时
// submit() 会原样再跑一遍，于是多出一条任务 / 一条补录 / 一门课。
//
// 每个弹窗自己的用例只覆盖它自己的业务分支，这条把「开始关闭后不得再写入」
// 当成横向不变量集中放一处：新增写入表单时应当在这里补一行，
// 不然 8 个弹窗里漏掉的那个不会有任何测试发现。
//
// 写法统一为：打开 → 填合法数据 → close() → 再 submit()。
// 必须填合法数据，否则校验本身就会挡住第二次提交，门禁被摘掉也照样绿。
TestCase {
    id: testCase
    name: "DialogCloseGuard"
    when: windowShown
    width: 1024
    height: 768
    visible: true

    // ---- 共用替身 ----

    QtObject {
        id: categoryManager

        signal categoriesChanged()
        signal operationFailed(string message)

        function getAllCategories() {
            return [ { id: 1, name: "数学", color: "#d4a574" } ]
        }
        function addCategory(name, color) { return -1 }
    }

    property int writeCount: 0

    function countWrite() {
        testCase.writeCount += 1
        return true
    }

    // 打开 → 填表 → 关闭 → 再提交，断言第二次提交没有写入。
    // fill 负责填合法数据并确认第一次提交确实写成功了。
    function assertClosingBlocksSubmit(dialog, openIt, fill, submitAgain, afterBlocked) {
        testCase.writeCount = 0
        openIt()
        tryCompare(dialog, "opened", true, 3000)
        fill()

        // 先证明这套数据是能写进去的，否则后面的「没写」毫无意义。
        compare(testCase.writeCount, 1,
                "第一次提交没有写入，用例数据不合法：" + (dialog.errorText || ""))

        // close() 之后 submissionClosed 就该拦住后续提交：退出动画期间弹窗还在
        // 接键盘，用户补按的那次回车正是打在这里。
        submitAgain()
        compare(testCase.writeCount, 1, "关闭中的表单又写了一次")
        if (afterBlocked) {
            afterBlocked()
        }

        tryCompare(dialog, "visible", false, 3000)

        // 下次打开必须解除门禁，否则表单会永久失效。
        openIt()
        tryCompare(dialog, "opened", true, 3000)
        compare(dialog.submissionClosed, false, "重新打开后门禁没有解除")
        dialog.close()
        tryCompare(dialog, "visible", false, 3000)
    }

    // ---- 1. 新建任务 ----

    AddTaskDialog {
        id: addTaskDialog

        parent: testCase
        categoryManagerRef: categoryManager
        taskSubmitter: function(title, date, categoryId, estimatedMinutes, notes) {
            return testCase.countWrite()
        }
    }

    function test_addTaskDialogBlocksSubmitWhileClosing() {
        assertClosingBlocksSubmit(
            addTaskDialog,
            function() { addTaskDialog.open() },
            function() {
                findChild(addTaskDialog, "titleField").text = "写作业"
                findChild(addTaskDialog, "addEstimateHourField").text = "0"
                findChild(addTaskDialog, "addEstimateMinuteField").text = "30"
                addTaskDialog.submit()
            },
            function() { addTaskDialog.submit() },
            function() {
                // 新建任务弹窗还有第二层拦截：关闭前会 resetFields() 清空标题，
                // 所以第二次提交即使跑进去也写不成功。门禁在这里的可见价值是
                // 不要在一个正在消失的弹窗上闪一句「任务标题不能为空」。
                compare(findChild(addTaskDialog, "addTaskErrorLabel").text, "",
                        "关闭中的弹窗不该弹出校验错误")
            })
    }

    // ---- 2. 编辑任务 ----

    EditTaskDialog {
        id: editTaskDialog

        parent: testCase
        categoryManagerRef: categoryManager
        taskSubmitter: function(taskId, title, categoryId, isoDate, estimatedMinutes, notes) {
            return testCase.countWrite()
        }
    }

    function test_editTaskDialogBlocksSubmitWhileClosing() {
        assertClosingBlocksSubmit(
            editTaskDialog,
            function() {
                editTaskDialog.openForTask({ id: 5, title: "复习", categoryId: 1,
                                             date: "2026-09-16", estimatedMinutes: 30,
                                             notes: "" })
            },
            function() {
                findChild(editTaskDialog, "editTitleField").text = "复习线代"
                findChild(editTaskDialog, "editEstimateHourField").text = "0"
                findChild(editTaskDialog, "editEstimateMinuteField").text = "45"
                editTaskDialog.submit()
            },
            function() { editTaskDialog.submit() })
    }

    // ---- 3. 倒计时目标 ----

    QtObject {
        id: countdownService

        signal operationFailed(string message)

        function addGoal(name, targetDate) { return testCase.countWrite() }
        function updateGoal(goalId, name, targetDate) { return testCase.countWrite() }
    }

    CountdownDialog {
        id: countdownDialog

        parent: testCase
        countdownServiceRef: countdownService
    }

    function test_countdownDialogBlocksSubmitWhileClosing() {
        assertClosingBlocksSubmit(
            countdownDialog,
            function() { countdownDialog.openForAdd() },
            function() {
                findChild(countdownDialog, "countdownNameField").text = "考研"
                findChild(countdownDialog, "countdownDateField").text = "2026-12-20"
                countdownDialog.submit()
            },
            function() { countdownDialog.submit() })
    }

    // ---- 4. 知识缺口 ----

    QtObject {
        id: knowledgeGapService

        signal operationFailed(string message)

        readonly property int maxDetailLength: 2000

        function addGap(title, categoryId, detail, priority, due, taskId) {
            testCase.countWrite()
            return 42
        }
        function updateGap(id, title, categoryId, detail, priority, due) {
            return testCase.countWrite()
        }
    }

    KnowledgeGapDialog {
        id: knowledgeGapDialog

        parent: testCase
        gapServiceRef: knowledgeGapService
        categoryManagerRef: categoryManager
    }

    function test_knowledgeGapDialogBlocksSubmitWhileClosing() {
        assertClosingBlocksSubmit(
            knowledgeGapDialog,
            function() { knowledgeGapDialog.openForAdd() },
            function() {
                findChild(knowledgeGapDialog, "knowledgeGapTitleField").text = "矩阵秩没弄懂"
                knowledgeGapDialog.submit()
            },
            function() { knowledgeGapDialog.submit() })
    }

    // ---- 5. 手动补录 ----

    ManualSessionDialog {
        id: manualSessionDialog

        parent: testCase
        onSubmitted: function(sessionId, startDateTime, durationMinutes, taskId) {
            testCase.countWrite()
        }
    }

    function test_manualSessionDialogBlocksSubmitWhileClosing() {
        assertClosingBlocksSubmit(
            manualSessionDialog,
            function() { manualSessionDialog.openForAdd("2026-09-16", []) },
            function() {
                findChild(manualSessionDialog, "manualSessionDateField").text = "2026-09-16"
                findChild(manualSessionDialog, "manualSessionHourField").text = "09"
                findChild(manualSessionDialog, "manualSessionMinuteField").text = "30"
                findChild(manualSessionDialog, "manualSessionDurationHourField").text = "0"
                findChild(manualSessionDialog, "manualSessionDurationMinuteField").text = "25"
                manualSessionDialog.submit()
            },
            function() { manualSessionDialog.submit() })
    }

    // ---- 6. 课表条目 ----

    QtObject {
        id: scheduleService

        signal scheduleChanged()
        signal periodsChanged()
        signal operationFailed(string message)

        readonly property int maxTitleLength: 60
        readonly property int maxLocationLength: 60
        readonly property int maxWeekIndex: 60
        readonly property int maxPeriodCount: 24

        function getPeriods() {
            return [ { index: 1, startMinutes: 480, endMinutes: 525 } ]
        }
        function findConflicts() { return [] }
        function addEntry() { return testCase.countWrite() }
        function updateEntry() { return testCase.countWrite() }
        function setPeriods(periods) { return testCase.countWrite() }
    }

    ScheduleEntryDialog {
        id: scheduleEntryDialog

        parent: testCase
        scheduleServiceRef: scheduleService
        categoryManagerRef: categoryManager
        semesterWeeks: 16
        periods: scheduleService.getPeriods()
    }

    function test_scheduleEntryDialogBlocksSubmitWhileClosing() {
        assertClosingBlocksSubmit(
            scheduleEntryDialog,
            function() { scheduleEntryDialog.openForNew(1, 480) },
            function() {
                findChild(scheduleEntryDialog, "scheduleTitleField").text = "高等数学"
                findChild(scheduleEntryDialog, "scheduleStartField").text = "08:00"
                findChild(scheduleEntryDialog, "scheduleEndField").text = "09:45"
                scheduleEntryDialog.submit()
            },
            function() { scheduleEntryDialog.submit() })
    }

    // ---- 7. 课表设置 ----

    QtObject {
        id: appSettings

        signal settingsWriteFailed(string key, string message)

        property string semesterStartDate: "2026-08-31"
        property int semesterWeeks: 16
        property bool scheduleShowWeekend: true

        function saveScheduleSettings(startDate, weeks, showWeekend) {
            return testCase.countWrite()
        }
    }

    ScheduleSettingsDialog {
        id: scheduleSettingsDialog

        parent: testCase
        scheduleServiceRef: scheduleService
        settingsRef: appSettings
    }

    function test_scheduleSettingsDialogBlocksSaveWhileClosing() {
        // 这个弹窗的写入入口叫 save()，不是 submit()。
        assertClosingBlocksSubmit(
            scheduleSettingsDialog,
            // openDialog() 才会把学期设置和节次草稿读进来，直接 open() 是空表单。
            function() { scheduleSettingsDialog.openDialog() },
            function() { scheduleSettingsDialog.save() },
            function() { scheduleSettingsDialog.save() })
    }

    // ---- 8. 目标表单 ----

    QtObject {
        id: goalService

        signal operationFailed(string message)

        readonly property int maxTitleLength: 100
        readonly property int maxTargetMinutes: 60000

        function addGoal(title, categoryId, targetMinutes, startDate, deadline) {
            return testCase.countWrite()
        }
        function updateGoal(goalId, title, categoryId, targetMinutes, startDate, deadline) {
            return testCase.countWrite()
        }
    }

    GoalFormDialog {
        id: goalFormDialog

        parent: testCase
        categoryManagerRef: categoryManager
        goalServiceRef: goalService
    }

    function test_goalFormDialogBlocksSubmitWhileClosing() {
        assertClosingBlocksSubmit(
            goalFormDialog,
            function() { goalFormDialog.openForAdd() },
            function() {
                findChild(goalFormDialog, "goalTitleField").text = "刷完真题"
                goalFormDialog.submit()
            },
            function() { goalFormDialog.submit() })
    }
}
