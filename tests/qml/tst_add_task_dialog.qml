import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"
import "../../qml"

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

        signal operationFailed(string message)
        property bool failLoad: false

        function getAllCategories() {
            if (failLoad) {
                operationFailed("科目数据库故障")
                return []
            }
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

    AddTaskDialog {
        id: failingDialog
        taskSubmitter: function(title, date, categoryId) { return false }
    }

    property int submittedMinutes: -1

    AddTaskDialog {
        id: estimateDialog
        taskSubmitter: function(title, date, categoryId, estimatedMinutes) {
            testCase.submittedMinutes = Number(estimatedMinutes)
            return true
        }
    }

    property date providedDate: new Date(2026, 6, 25, 12, 0, 0)

    AddTaskDialog {
        id: refreshedDateDialog
        selectedDateProvider: function() { return testCase.providedDate }
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

    function test_panelIsGlassDialog() {
        dialog.open()
        wait(20)
        var panel = findChild(dialog, "dialogPanel")
        verify(panel)
        verify(Qt.colorEqual(panel.color, Theme.glassDialog))
        dialog.close()
    }

    function test_failedSubmitKeepsInputAndDialogOpen() {
        wait(260)
        failingDialog.open()
        tryCompare(failingDialog, "opened", true, 500)
        var titleField = findChild(failingDialog, "titleField")
        var errorLabel = findChild(failingDialog, "addTaskErrorLabel")
        verify(titleField)
        verify(errorLabel)

        titleField.text = "不能丢失的输入"
        failingDialog.submit()

        compare(failingDialog.opened, true)
        compare(titleField.text, "不能丢失的输入")
        verify(errorLabel.text.length > 0)
        failingDialog.close()
    }

    function test_categoryFailureSurvivesOpenRefresh() {
        fakeCategoryManager.failLoad = true
        categoryDialog.open()
        tryCompare(categoryDialog, "opened", true, 500)

        var errorLabel = findChild(categoryDialog, "addTaskErrorLabel")
        verify(errorLabel)
        compare(errorLabel.text, "科目数据库故障")

        categoryDialog.close()
        fakeCategoryManager.failLoad = false
    }

    function estimateFieldsOf(popup) {
        var hour = findChild(popup, "addEstimateHourField")
        var minute = findChild(popup, "addEstimateMinuteField")
        verify(hour)
        verify(minute)
        return { hour: hour, minute: minute }
    }

    function test_estimateIsSubmittedAsMinutes() {
        testCase.submittedMinutes = -1
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 500)
        findChild(estimateDialog, "titleField").text = "高数复习"

        var fields = estimateFieldsOf(estimateDialog)
        // 小时和分钟必须合成一个分钟数交给服务层，而不是各传各的。
        fields.hour.text = "1"
        fields.minute.text = "45"
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 105)
        tryCompare(estimateDialog, "opened", false, 500)
    }

    function test_estimateDefaultsToUnsetAndResetsBetweenOpens() {
        testCase.submittedMinutes = -1
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 500)
        findChild(estimateDialog, "titleField").text = "留空预计"

        var fields = estimateFieldsOf(estimateDialog)
        // 不填等于「未设置」，要老老实实传 0，而不是替用户猜一个默认时长。
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "0")
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 0)

        // 上一次填过的值不能留到下一次打开——那会让用户在不知情下重复套用旧预估。
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 500)
        findChild(estimateDialog, "titleField").text = "第二次"
        fields = estimateFieldsOf(estimateDialog)
        fields.hour.text = "2"
        fields.minute.text = "0"
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 120)

        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 500)
        fields = estimateFieldsOf(estimateDialog)
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "0")

        // 填了但没提交：estimatedMinutes 从没被改过，绑定不会发出变化信号，
        // 只有 resetFields 里那句显式重灌能把输入框清干净。关闭走的就是这条路。
        fields.hour.text = "3"
        fields.minute.text = "30"
        compare(estimateDialog.estimatedMinutes, 0)
        estimateDialog.resetFields()
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "0")
        estimateDialog.close()
    }

    function test_incompleteEstimateBlocksSubmit() {
        testCase.submittedMinutes = -1
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 500)
        findChild(estimateDialog, "titleField").text = "清空分钟"

        var fields = estimateFieldsOf(estimateDialog)
        fields.minute.text = ""
        estimateDialog.submit()
        // 清空后提交曾会静默存成 0；必须挡住并把弹窗留在原地让用户看见报错。
        compare(testCase.submittedMinutes, -1)
        compare(estimateDialog.opened, true)
        verify(findChild(estimateDialog, "addTaskErrorLabel").text.length > 0)
        estimateDialog.close()
    }

    function test_selectedDateRefreshesEveryTimeDialogOpens() {
        testCase.providedDate = new Date(2026, 6, 25, 12, 0, 0)
        refreshedDateDialog.open()
        tryCompare(refreshedDateDialog, "opened", true, 500)
        compare(Qt.formatDate(refreshedDateDialog.selectedDate, "yyyy-MM-dd"), "2026-07-25")
        refreshedDateDialog.close()
        tryCompare(refreshedDateDialog, "opened", false, 500)

        // 模拟弹窗长时间未用后跨过逻辑日边界；再打开不得沿用上次日期。
        testCase.providedDate = new Date(2026, 6, 26, 12, 0, 0)
        refreshedDateDialog.open()
        tryCompare(refreshedDateDialog, "opened", true, 500)
        compare(Qt.formatDate(refreshedDateDialog.selectedDate, "yyyy-MM-dd"), "2026-07-26")
        refreshedDateDialog.close()
    }
}
