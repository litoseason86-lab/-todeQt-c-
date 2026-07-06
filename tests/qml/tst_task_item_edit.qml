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
}
