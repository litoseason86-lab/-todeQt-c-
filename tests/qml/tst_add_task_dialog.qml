import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "AddTaskDialogLayout"
    when: windowShown
    width: 1024
    height: 768

    AddTaskDialog {
        id: dialog
    }

    Item {
        id: contentArea

        x: 208
        y: 0
        width: 816
        height: 768

        AddTaskDialog {
            id: embeddedDialog
        }
    }

    function verifyInsidePanel(popup: Popup, item: Item) {
        var local = popup.background.mapFromItem(item, 0, 0)
        verify(item.width > 0, item + " has no width")
        verify(item.height > 0, item + " has no height")
        verify(local.x >= 0, item + " starts before dialog panel")
        verify(local.y >= 0, item + " starts above dialog panel")
        verify(local.x + item.width <= popup.background.width,
               item + " overflows dialog panel horizontally")
        verify(local.y + item.height <= popup.background.height,
               item + " overflows dialog panel vertically")
    }

    function verifyDialogLayout(popup: Popup) {
        popup.open()
        wait(100)

        var titleField = findChild(popup, "titleField")
        var categoryField = findChild(popup, "categoryField")
        var cancelButton = findChild(popup, "cancelButton")
        var submitButton = findChild(popup, "submitButton")

        verify(titleField !== null)
        verify(categoryField !== null)
        verify(cancelButton !== null)
        verify(submitButton !== null)

        compare(popup.contentItem.width, popup.width)
        compare(popup.background.width, popup.width)
        verifyInsidePanel(popup, titleField)
        verifyInsidePanel(popup, categoryField)
        verifyInsidePanel(popup, cancelButton)
        verifyInsidePanel(popup, submitButton)
        popup.close()
    }

    function test_controlsStayInsidePanel() {
        verifyDialogLayout(dialog)
    }

    function test_controlsStayInsidePanelWhenEmbeddedInContentArea() {
        verifyDialogLayout(embeddedDialog)
    }
}
