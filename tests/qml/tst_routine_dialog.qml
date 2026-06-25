import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "RoutineDialogUi"
    when: windowShown
    width: 1024
    height: 768

    property var added: []
    property int addCalls: 0
    property int lastCategoryId: -999
    property int deletedId: -1
    property bool addResult: true

    QtObject {
        id: fakeRoutineManager

        signal routinesChanged()

        function getRoutines() {
            return testCase.added
        }

        function addRoutine(title, categoryId) {
            testCase.addCalls += 1
            testCase.lastCategoryId = categoryId
            if (!testCase.addResult) {
                return false
            }
            testCase.added = testCase.added.concat([{
                id: testCase.added.length + 1,
                title: title,
                categoryId: categoryId,
                categoryName: categoryId === 7 ? "数学" : "",
                categoryColor: categoryId === 7 ? "#d4a574" : "",
                active: true,
                displayOrder: 0
            }])
            routinesChanged()
            return true
        }

        function deleteRoutine(id) {
            testCase.deletedId = id
            testCase.added = testCase.added.filter(function(item) { return item.id !== id })
            routinesChanged()
            return true
        }

        function setRoutineActive(id, active) {
            return true
        }
    }

    QtObject {
        id: fakeCategoryManager

        function getAllCategories() {
            return [
                { id: 7, name: "数学", color: "#d4a574" }
            ]
        }
    }

    RoutineDialog {
        id: dialog
        routineManagerRef: fakeRoutineManager
        categoryManagerRef: fakeCategoryManager
    }

    function init() {
        testCase.added = []
        testCase.addCalls = 0
        testCase.lastCategoryId = -999
        testCase.deletedId = -1
        testCase.addResult = true
        dialog.routineManagerRef = fakeRoutineManager
        dialog.categoryManagerRef = fakeCategoryManager
        dialog.close()
        wait(20)
    }

    function test_addRoutineShowsInList() {
        dialog.open()
        wait(120)

        var input = findChild(dialog, "routineTitleField")
        var addBtn = findChild(dialog, "routineAddButton")
        var list = findChild(dialog, "routineListView")
        verify(input !== null)
        verify(addBtn !== null)
        verify(list !== null)

        input.text = "背单词 list"
        dialog.submit()
        wait(120)

        compare(testCase.added.length, 1)
        compare(testCase.added[0].title, "背单词 list")
        compare(testCase.lastCategoryId, -1)
        compare(list.count, 1)
        dialog.close()
    }

    function test_emptyTitleDoesNotCallService() {
        dialog.open()
        wait(120)

        var input = findChild(dialog, "routineTitleField")
        verify(input !== null)
        input.text = "   "
        dialog.submit()

        compare(testCase.addCalls, 0)
        verify(dialog.errorText.length > 0)
        dialog.close()
    }

    function test_serviceUnavailableShowsInlineError() {
        dialog.routineManagerRef = null
        dialog.open()
        wait(120)

        var input = findChild(dialog, "routineTitleField")
        verify(input !== null)
        input.text = "背单词"
        dialog.submit()

        compare(testCase.addCalls, 0)
        compare(dialog.errorText, "每日例行服务不可用")
        dialog.close()
    }

    function test_categorySelectionPassesCategoryId() {
        dialog.open()
        wait(120)

        var combo = findChild(dialog, "routineCategoryCombo")
        verify(combo !== null)
        compare(combo.count, 2)
        combo.currentIndex = 1

        var input = findChild(dialog, "routineTitleField")
        input.text = "数学错题"
        dialog.submit()

        compare(testCase.lastCategoryId, 7)
        compare(testCase.added[0].categoryName, "数学")
        dialog.close()
    }

    function test_routinesChangedRefreshesListAndDeleteRemovesItem() {
        dialog.open()
        wait(120)

        var list = findChild(dialog, "routineListView")
        verify(list !== null)
        testCase.added = [{ id: 42, title: "政治选择题", categoryId: -1, categoryName: "", categoryColor: "", active: true, displayOrder: 0 }]
        fakeRoutineManager.routinesChanged()
        wait(120)
        compare(list.count, 1)

        dialog.deleteRoutine(42)
        wait(120)
        compare(testCase.deletedId, 42)
        compare(list.count, 0)
        dialog.close()
    }
}
