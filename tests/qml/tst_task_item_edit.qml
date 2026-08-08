import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "TaskItemEdit"
    when: windowShown
    width: 600
    height: 200

    TaskItem {
        id: item
        width: testCase.width
        taskId: 42
        taskTitle: "原始标题"
        taskCompleted: false
    }

    SignalSpy {
        id: renameSpy
        target: item
        signalName: "renameSubmitted"
    }

    SignalSpy {
        id: editSpy
        target: item
        signalName: "editClicked"
    }

    function init() {
        item.taskTitle = "原始标题"
        item.taskCompleted = false
        item.titleEditing = false
        item.renameSubmitter = null
        item.estimatedMinutes = 0
        item.focusedMinutes = 0
        item.setPointerInside(false)
        renameSpy.clear()
        editSpy.clear()
        wait(20)
    }

    function test_beginEditPrefillsAndCommitEmits() {
        item.beginTitleEdit()
        compare(item.titleEditing, true)

        const field = findChild(item, "taskTitleEditField")
        verify(field)
        compare(field.text, "原始标题")

        field.text = "改好的标题"
        item.commitTitleEdit()

        compare(item.titleEditing, false)
        compare(renameSpy.count, 1)
        compare(renameSpy.signalArguments[0][0], 42)
        compare(renameSpy.signalArguments[0][1], "改好的标题")
    }

    function test_blankOrUnchangedTitleIsCancel() {
        item.beginTitleEdit()
        const field = findChild(item, "taskTitleEditField")
        field.text = "   "
        item.commitTitleEdit()
        compare(renameSpy.count, 0)
        compare(item.titleEditing, false)

        item.beginTitleEdit()
        field.text = "原始标题"
        item.commitTitleEdit()
        compare(renameSpy.count, 0)
    }

    function test_cancelRestoresWithoutSignal() {
        item.beginTitleEdit()
        const field = findChild(item, "taskTitleEditField")
        field.text = "不该生效"
        item.cancelTitleEdit()

        compare(item.titleEditing, false)
        compare(renameSpy.count, 0)
    }

    function test_failedRenameKeepsDraftAndEditingState() {
        item.renameSubmitter = function(taskId, title) { return false }
        item.beginTitleEdit()
        const field = findChild(item, "taskTitleEditField")
        verify(field)
        field.text = "保留的行内草稿"

        item.commitTitleEdit()

        compare(item.titleEditing, true)
        compare(field.text, "保留的行内草稿")
        compare(renameSpy.count, 0)
    }

    function test_editAndDeleteButtonsAreAlwaysAvailable() {
        const editButton = findChild(item, "taskEditButton")
        const deleteButton = findChild(item, "taskDeleteButton")
        verify(editButton)
        verify(deleteButton)

        compare(editButton.enabled, true)
        compare(deleteButton.enabled, true)
        compare(editButton.opacity, 1)
        compare(deleteButton.opacity, 1)

        item.setPointerInside(true)
        wait(20)
        compare(editButton.enabled, true)
        compare(deleteButton.enabled, true)
        compare(editButton.opacity, 1)
        compare(deleteButton.opacity, 1)

        editButton.clicked()
        compare(editSpy.count, 1)
        compare(editSpy.signalArguments[0][0], 42)
    }

    function test_completedTaskHidesFocusButton() {
        const focusButton = findChild(item, "focusButton")
        verify(focusButton)

        item.taskCompleted = true
        wait(260)
        compare(focusButton.visible, false)
    }

    function test_focusSummaryReadsAsDurationNotPomodoroCount() {
        // 未设预计：只报已投入，不能凭空造出一个「/ 0」的分母。
        item.focusedMinutes = 40
        compare(item.focusSummary, "已专注 40 分钟")
        compare(item.estimateOverflow, false)

        // 设了预计：左右都按时长展示，超过一小时要进位成「N 小时 M 分」。
        item.estimatedMinutes = 150
        item.focusedMinutes = 75
        compare(item.focusSummary, "1 小时 15 分 / 2 小时 30 分")
        compare(item.estimateOverflow, false)

        // 超出预计要能被看出来，这是任务行上唯一的超时信号。
        item.focusedMinutes = 200
        compare(item.estimateOverflow, true)

        // 都是 0 时不占版面。
        item.estimatedMinutes = 0
        item.focusedMinutes = 0
        compare(item.focusSummary, "")
    }
}
