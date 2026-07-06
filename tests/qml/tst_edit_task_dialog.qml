import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "EditTaskDialog"
    when: windowShown
    width: 700
    height: 500

    QtObject {
        id: categoryManagerMock

        // 必须与 CategoryManager 的真实接口同名（getAllCategories）：此前 mock 提供了
        // 不存在的 getActiveCategories，测试全绿但真机下拉是空的——mock 名称错配会骗过测试。
        function getAllCategories() {
            return [
                { id: 3, name: "数学", color: "#d4a574" },
                { id: 5, name: "英语", color: "#8b7355" }
            ]
        }
    }

    EditTaskDialog {
        id: dialog
        categoryManagerRef: categoryManagerMock
    }

    SignalSpy {
        id: editedSpy
        target: dialog
        signalName: "taskEdited"
    }

    function init() {
        editedSpy.clear()
        dialog.close()
        wait(20)
    }

    function isoWithOffset(offset) {
        var d = new Date()
        d.setDate(d.getDate() + offset)
        return Qt.formatDate(d, "yyyy-MM-dd")
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

        const originalText = findChild(dialog, "editOriginalDateText")
        verify(originalText)
        verify(originalText.text.indexOf("2026-06-30") !== -1)
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
        compare(editedSpy.signalArguments[0][1], "新标题")
        compare(editedSpy.signalArguments[0][2], -1)
        compare(editedSpy.signalArguments[0][3], isoWithOffset(1))
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

    function test_panelIsGlassDialog() {
        dialog.openForTask({ id: 1, title: "任意", categoryId: -1, date: isoWithOffset(0) })
        wait(20)
        var panel = findChild(dialog, "editDialogPanel")
        verify(panel)
        verify(Qt.colorEqual(panel.color, Theme.glassDialog))
        dialog.close()
    }
}
