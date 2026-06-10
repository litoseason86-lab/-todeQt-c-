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

    QtObject {
        id: fakeCategoryManager

        function getAllCategories() {
            return [
                { id: 1, name: "数学", color: "#d4a574" },
                { id: 2, name: "英语", color: "#c9956e" }
            ]
        }
    }

    property int lastCategoryId: -999

    AddTaskDialog {
        id: categoryDialog
        categoryManagerRef: fakeCategoryManager

        onTaskAdded: function(title, date, categoryId) {
            testCase.lastCategoryId = Number(categoryId)
        }
    }

    function verifyInsidePanel(popup: Popup, item: Item) {
        // 把控件坐标换算到弹窗面板内部，用来确认控件没有伸出边界。
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
        var categoryComboBox = findChild(popup, "categoryComboBox")
        var cancelButton = findChild(popup, "cancelButton")
        var submitButton = findChild(popup, "submitButton")

        verify(titleField !== null)
        verify(categoryComboBox !== null)
        verify(cancelButton !== null)
        verify(submitButton !== null)

        compare(popup.contentItem.width, popup.width)
        compare(popup.background.width, popup.width)
        verifyInsidePanel(popup, titleField)
        verifyInsidePanel(popup, categoryComboBox)
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

    function test_categorySelectionCanRemainEmpty() {
        // -1 是“未选择科目”的约定值，服务层会把它写成空科目。
        testCase.lastCategoryId = -999
        categoryDialog.open()
        wait(100)

        var titleField = findChild(categoryDialog, "titleField")
        var categoryComboBox = findChild(categoryDialog, "categoryComboBox")
        verify(titleField !== null)
        verify(categoryComboBox !== null)
        compare(categoryComboBox.currentIndex, 0)
        compare(categoryComboBox.displayText, "不设置科目")

        titleField.text = "无科目任务"
        categoryDialog.submit()

        compare(testCase.lastCategoryId, -1)
        categoryDialog.close()
    }
}
