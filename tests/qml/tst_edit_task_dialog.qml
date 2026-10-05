import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"
import "../../qml/LogicalDay.js" as LogicalDay

TestCase {
    id: testCase
    name: "EditTaskDialog"
    when: windowShown
    width: 700
    height: 500

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: categoryManagerMock

        // 必须与 CategoryManager 的真实接口同名（getAllCategories）：此前 mock 提供了
        // 不存在的 getActiveCategories，测试全绿但真机下拉是空的——mock 名称错配会骗过测试。
        property var categories: [
            { id: 3, name: "数学", color: "#d4a574" },
            { id: 5, name: "英语", color: "#8b7355" }
        ]

        function getAllCategories() {
            return categories
        }
    }

    EditTaskDialog {
        id: dialog
        categoryManagerRef: categoryManagerMock
    }

    EditTaskDialog {
        id: failingDialog
        categoryManagerRef: categoryManagerMock
        taskSubmitter: function(taskId, changes) {
            return false
        }
    }

    property int submittedMinutes: -1

    EditTaskDialog {
        id: estimateDialog
        categoryManagerRef: categoryManagerMock
        taskSubmitter: function(taskId, changes) {
            testCase.submittedMinutes = changes.estimatedMinutes === undefined ? -1 : Number(changes.estimatedMinutes)
            return true
        }
    }

    // 完成记录用例的提交记录：弹窗交出的改动表原样留着，断言看有哪些键。
    property var lastSubmission: null

    EditTaskDialog {
        id: completionDialog
        categoryManagerRef: categoryManagerMock
        taskSubmitter: function(taskId, changes) {
            testCase.lastSubmission = { taskId: taskId, changes: changes }
            return true
        }
    }

    QtObject {
        id: coordinator
        property bool refreshBlocked: false
        property bool failRead: false
        property string lastError: "任务已不存在"
        signal changed()
        function beginEdit(owner, id, source) {
            refreshBlocked = !failRead
            changed()
            return failRead ? ({}) : ({id: id, title: "最新数据", categoryId: 3, date: "2026-09-18", notes: "最新备注", estimatedMinutes: 60})
        }
        function end(owner) { refreshBlocked = false; changed() }
    }

    SignalSpy {
        id: editedSpy
        target: dialog
        signalName: "taskEdited"
    }

    function init() {
        dialog.finishEditing()
        dialog.interactionCoordinatorRef = null
        coordinator.failRead = false
        editedSpy.clear()
        dialog.close()
        failingDialog.close()
        estimateDialog.close()
        testCase.submittedMinutes = -1
        completionDialog.close()
        completionDialog.maxNotesLength = 2000
        testCase.lastSubmission = null
        wait(20)
    }

    function isoWithOffset(offset) {
        // 测试必须与组件使用同一逻辑日，否则凌晨 0~4 点会把“今天”错当成物理新日。
        var d = LogicalDay.todayDate(appSettings.dayStartHour, new Date())
        d.setDate(d.getDate() + offset)
        return Qt.formatDate(d, "yyyy-MM-dd")
    }

    function test_registrationRereadsAndExplicitlyReleases() {
        dialog.interactionCoordinatorRef = coordinator
        dialog.openForTask({id: 7, title: "旧缓存", categoryId: 5, date: "2026-09-17"})
        compare(findChild(dialog, "editTitleField").text, "最新数据")
        compare(coordinator.refreshBlocked, true)
        // 离屏环境不依赖 Popup 关闭信号，直接验证公共结束入口。
        dialog.finishEditing()
        dialog.finishEditing()
        compare(coordinator.refreshBlocked, false)
        coordinator.failRead = true
        compare(dialog.openForTask({id: 7}), false)
        compare(coordinator.refreshBlocked, false)
    }

    function test_openPrefillsFields() {
        dialog.openForTask({ id: 7, title: "高数例题", categoryId: 5, date: isoWithOffset(0) })
        wait(20)

        const titleField = findChild(dialog, "editTitleField")
        verify(titleField)
        compare(titleField.text, "高数例题")

        const combo = findChild(dialog, "editCategoryCombo")
        verify(combo)
        compare(combo.currentIndex, 2)

        compare(dialog.dateOffsetSelection, 0)
    }

    function test_offPresetDateKeepsOriginal() {
        dialog.openForTask({ id: 8, title: "旧任务", categoryId: -1, date: "2026-06-30" })
        wait(20)

        compare(dialog.dateOffsetSelection, -1)
        compare(dialog.resultIsoDate(), "2026-06-30")

        const originalText = findChild(dialog, "editCustomDate")
        verify(originalText)
        verify(originalText.text.indexOf("2026-06-30") !== -1)
    }

    function test_arbitraryDateRejectsRollover() {
        dialog.openForTask({ id: 8, title: "日期测试", date: "2026-06-30" })
        var field = findChild(dialog, "editCustomDate")
        field.text = "2026-02-31"
        field.edited()
        dialog.submit()
        verify(dialog.visible)
        verify(dialog.errorText.length > 0)
        field.text = "2026-12-25"
        field.edited()
        compare(dialog.resultIsoDate(), "2026-12-25")
        verify(field.valid)
    }

    function test_submitEmitsEditedValues() {
        dialog.openForTask({ id: 9, title: "旧标题", categoryId: -1, date: isoWithOffset(0) })
        wait(20)

        const titleField = findChild(dialog, "editTitleField")
        titleField.text = "  新标题  "
        const tomorrowChip = findChild(dialog, "editDateTomorrow")
        verify(tomorrowChip)
        tomorrowChip.clicked()
        compare(dialog.dateOffsetSelection, 1)

        dialog.submit()
        compare(editedSpy.count, 1)
        compare(editedSpy.signalArguments[0][0], 9)
        const changes = editedSpy.signalArguments[0][1]
        compare(Object.keys(changes).sort().join(","), "date,title", "只交改过的两项，科目没动不交")
        compare(changes.title, "新标题")
        compare(changes.date, isoWithOffset(1))
    }

    // 产品保证：保存只交出用户改过的字段。弹窗开着时另一台改了别的字段，同步写进来的新值不会被这里打开时的旧值盖掉。
    // 抓住的错误实现：按打开时的快照整条交回（标题、科目、日期、预计用时、备注全带上）。
    function test_submitSendsOnlyChangedFields() {
        dialog.openForTask({ id: 21, title: "整理错题", categoryId: 3, date: "2026-06-30",
                             estimatedMinutes: 60, notes: "原备注" })
        wait(20)
        compare(dialog.dateOffsetSelection, -1, "前置：日期不在快捷项里，走日期框")
        findChild(dialog, "editNotesField").text = "  新备注  "
        dialog.submit()
        compare(editedSpy.count, 1)
        compare(editedSpy.signalArguments[0][0], 21)
        const changes = editedSpy.signalArguments[0][1]
        compare(Object.keys(changes).join(","), "notes", "只交备注：日期框、标题、科目、预计用时都没动")
        compare(changes.notes, "新备注")
    }

    // 产品保证：什么都没改就点保存，不写库，弹窗直接收起。
    // 抓住的错误实现：照样整条写回一次（另一台刚改的字段被打开时的旧值盖掉）。
    function test_unchangedSubmitWritesNothing() {
        dialog.openForTask({ id: 22, title: "背单词", categoryId: 5, date: isoWithOffset(0),
                             estimatedMinutes: 30, notes: "List 3" })
        tryCompare(dialog, "opened", true, 3000)
        compare(dialog.dateOffsetSelection, 0, "前置：日期选的是「今天」快捷项")
        dialog.submit()
        compare(editedSpy.count, 0)
        tryVerify(function () { return !dialog.visible }, 3000, "弹窗收起")
        compare(dialog.errorText, "")
    }

    // 产品保证：只改科目时只交科目。
    // 抓住的错误实现：比较科目时拿任务数据里的编号而不是打开时选中的那一项，或者没改也交。
    function test_categoryChangeSendsOnlyCategory() {
        dialog.openForTask({ id: 23, title: "阅读", categoryId: 3, date: isoWithOffset(0),
                             estimatedMinutes: 0, notes: "" })
        wait(20)
        verify(dialog.selectCategoryById(5))
        dialog.submit()
        compare(editedSpy.count, 1)
        const changes = editedSpy.signalArguments[0][1]
        compare(Object.keys(changes).join(","), "categoryId")
        compare(changes.categoryId, 5)
    }

    // 产品保证：任务的科目已经不在下拉里（科目被删了），没碰科目就保存，不会把它写成「不设置科目」。
    // 抓住的错误实现：拿任务数据里的科目编号当基准——打开时下拉落在「不设置科目」，两者不等就被当成改了。
    function test_missingCategoryIsNotRewritten() {
        dialog.openForTask({ id: 24, title: "旧科目的任务", categoryId: 99, date: isoWithOffset(0),
                             estimatedMinutes: 0, notes: "" })
        wait(20)
        compare(Number(dialog.categoryOptions[findChild(dialog, "editCategoryCombo").currentIndex].id), -1,
                "前置：下拉里没有科目 99，落在「不设置科目」")
        findChild(dialog, "editTitleField").text = "改个名"
        dialog.submit()
        compare(editedSpy.count, 1)
        compare(Object.keys(editedSpy.signalArguments[0][1]).join(","), "title")
    }

    function test_blankTitleBlocksSubmit() {
        dialog.openForTask({ id: 10, title: "有内容", categoryId: -1, date: isoWithOffset(0) })
        wait(20)

        const titleField = findChild(dialog, "editTitleField")
        titleField.text = "   "
        dialog.submit()

        compare(editedSpy.count, 0)
        verify(dialog.errorText.length > 0)
    }

    function test_failedSubmitKeepsDraftAndDialogOpen() {
        failingDialog.openForTask({
            id: 11, title: "旧标题", categoryId: -1, date: isoWithOffset(0)
        })
        tryCompare(failingDialog, "opened", true, 3000)

        const titleField = findChild(failingDialog, "editTitleField")
        verify(titleField)
        titleField.text = "不能丢的修改"
        failingDialog.submit()

        compare(failingDialog.opened, true)
        compare(titleField.text, "不能丢的修改")
        verify(failingDialog.errorText.length > 0)
    }

    function test_panelIsGlassDialog() {
        dialog.openForTask({ id: 1, title: "任意", categoryId: -1, date: isoWithOffset(0) })
        wait(20)
        var panel = findChild(dialog, "editDialogPanel")
        verify(panel)
        verify(Qt.colorEqual(panel.color, Theme.glassDialog))
        dialog.close()
    }

    function estimateFieldsOf(popup) {
        var hour = findChild(popup, "editEstimateHourField")
        var minute = findChild(popup, "editEstimateMinuteField")
        verify(hour)
        verify(minute)
        return { hour: hour, minute: minute }
    }

    function test_openPrefillsEstimateAsHoursAndMinutes() {
        estimateDialog.openForTask({ id: 11, title: "线代", categoryId: 3,
                                     date: isoWithOffset(0), estimatedMinutes: 150 })
        wait(20)

        var fields = estimateFieldsOf(estimateDialog)
        compare(fields.hour.text, "2")
        compare(fields.minute.text, "30")

        // 换一个任务：上一次的预估不能残留。数据库里存的是分钟，回填也必须按分钟拆。
        estimateDialog.close()
        estimateDialog.openForTask({ id: 12, title: "英语", categoryId: 5,
                                     date: isoWithOffset(0), estimatedMinutes: 45 })
        wait(20)
        fields = estimateFieldsOf(estimateDialog)
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "45")

        // 改了输入但没保存就关掉，再打开同一个任务：预估值没变，绑定不会发出变化信号，
        // 只有 openForTask 里那句显式重灌能把上次的残留冲掉。
        fields.hour.text = "3"
        fields.minute.text = "30"
        estimateDialog.close()
        estimateDialog.openForTask({ id: 12, title: "英语", categoryId: 5,
                                     date: isoWithOffset(0), estimatedMinutes: 45 })
        wait(20)
        fields = estimateFieldsOf(estimateDialog)
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "45")
        estimateDialog.close()
    }

    function test_overlongNotesBlockEditSubmit() {
        testCase.submittedMinutes = -1
        estimateDialog.openForTask({ id: 14, title: "高数", categoryId: 3,
                                     date: isoWithOffset(0), estimatedMinutes: 60,
                                     notes: "原备注" })
        wait(20)

        var notes = findChild(estimateDialog, "editNotesField")
        var longNotes = new Array(estimateDialog.maxNotesLength + 2).join("y")
        notes.text = longNotes
        estimateDialog.submit()

        compare(testCase.submittedMinutes, -1)
        compare(notes.text, longNotes)
        verify(estimateDialog.errorText.indexOf("备注") >= 0, estimateDialog.errorText)
    }

    function test_editedEstimateIsSubmittedAsMinutes() {
        estimateDialog.openForTask({ id: 13, title: "高数", categoryId: 3,
                                     date: isoWithOffset(0), estimatedMinutes: 60 })
        wait(20)

        var fields = estimateFieldsOf(estimateDialog)
        fields.hour.text = "1"
        fields.minute.text = "30"
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 90)
    }

    function test_incompleteEstimateBlocksEditSubmit() {
        estimateDialog.openForTask({ id: 14, title: "政治", categoryId: 3,
                                     date: isoWithOffset(0), estimatedMinutes: 60 })
        wait(20)

        var fields = estimateFieldsOf(estimateDialog)
        fields.hour.text = ""
        estimateDialog.submit()
        // 清空后不能静默存 0，否则用户看不出预估被抹掉了。
        compare(testCase.submittedMinutes, -1)
        verify(estimateDialog.errorText.length > 0)
        estimateDialog.close()
    }

    // —— 审查修复：取消新建科目按编号恢复（2026-09-14）——

    function test_cancelNewCategoryRestoresSameCategoryAfterReorder() {
        categoryManagerMock.categories = [
            { id: 3, name: "数学", color: "#d4a574" },
            { id: 5, name: "英语", color: "#8b7355" }
        ]
        dialog.openForTask({ id: 9, title: "单词", categoryId: 5, date: new Date(),
                             estimatedMinutes: 0, notes: "" })
        var combo = findChild(dialog, "editCategoryCombo")
        verify(combo)
        compare(dialog.lastRealCategoryId, 5)

        // 列表重排：「英语」从下标 2 挪到下标 1，原位置换成别的科目。
        // 这个弹窗目前只在打开和建完科目时刷新列表，重排本身在界面上走不到；
        // 这条守的是「恢复点是科目编号」这个约定，防止将来加了刷新时又退回按下标。
        categoryManagerMock.categories = [
            { id: 5, name: "英语", color: "#8b7355" },
            { id: 7, name: "政治", color: "#aaaaaa" },
            { id: 3, name: "数学", color: "#d4a574" }
        ]
        dialog.refreshCategories()
        dialog.selectCategoryById(5)
        compare(combo.currentIndex, 1)

        var sentinelIndex = dialog.categoryOptions.length - 1
        dialog.handleCategoryActivated(sentinelIndex)
        findChild(dialog, "editTaskNewCategoryPrompt").close()

        compare(Number(dialog.categoryOptions[combo.currentIndex].id), 5)
        dialog.close()
        categoryManagerMock.categories = [
            { id: 3, name: "数学", color: "#d4a574" },
            { id: 5, name: "英语", color: "#8b7355" }
        ]
    }

    // —— 完成记录 ——

    function test_completedTaskEditsCompletionNote() {
        completionDialog.openForTask({ id: 8, title: "数据结构", categoryId: -1, date: isoWithOffset(0),
                                       completed: true, notes: "第三章", completionNote: "做完 1–10 题" })
        wait(20)
        compare(completionDialog.editingCompleted, true)
        const field = findChild(completionDialog, "editCompletionNoteField")
        verify(field)
        compare(field.text, "做完 1–10 题")

        field.text = "  做完 1–15 题  "
        completionDialog.submit()
        verify(testCase.lastSubmission !== null, completionDialog.errorText)
        compare(testCase.lastSubmission.taskId, 8)
        compare(testCase.lastSubmission.changes.completionNote, "做完 1–15 题")
        // 两栏分开：只改了完成记录，计划备注没动就不交，更不会被完成记录顶掉。
        compare(Object.keys(testCase.lastSubmission.changes).join(","), "completionNote")
    }

    function test_uncompletedTaskLeavesCompletionNoteUntouched() {
        // 未完成任务不显示完成记录栏，提交的改动表里不能有完成记录：
        // 若带上空串，取消完成前写的记录就会被悄悄清空。改一下标题，确保这次确实提交了。
        completionDialog.openForTask({ id: 9, title: "高等数学", categoryId: -1, date: isoWithOffset(0),
                                       completed: false, completionNote: "取消完成前写的" })
        wait(20)
        compare(completionDialog.editingCompleted, false)
        findChild(completionDialog, "editTitleField").text = "高等数学（下）"
        completionDialog.submit()
        verify(testCase.lastSubmission !== null, completionDialog.errorText)
        compare(Object.keys(testCase.lastSubmission.changes).join(","), "title")
    }

    function test_completionNoteLengthBoundary() {
        completionDialog.maxNotesLength = 10
        completionDialog.openForTask({ id: 8, title: "数据结构", categoryId: -1, date: isoWithOffset(0),
                                       completed: true, completionNote: "" })
        wait(20)
        const field = findChild(completionDialog, "editCompletionNoteField")

        // 超一个字：拦下、指明是完成记录，草稿原样保留。
        field.text = "一二三四五六七八九十十"
        completionDialog.submit()
        compare(testCase.lastSubmission, null)
        verify(completionDialog.errorText.indexOf("完成记录太长了") === 0, completionDialog.errorText)
        compare(field.text, "一二三四五六七八九十十")

        // 正好在上限：放行。
        field.text = "一二三四五六七八九十"
        completionDialog.submit()
        verify(testCase.lastSubmission !== null, completionDialog.errorText)
        compare(testCase.lastSubmission.changes.completionNote, "一二三四五六七八九十")
    }
}

