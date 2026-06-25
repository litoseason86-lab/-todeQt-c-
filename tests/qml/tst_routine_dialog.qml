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

    QtObject {
        id: fakeRoutineManager

        signal routinesChanged()

        function getRoutines() {
            return testCase.added
        }

        function addRoutine(title, categoryId) {
            testCase.added = testCase.added.concat([{
                id: testCase.added.length + 1,
                title: title,
                categoryId: categoryId,
                categoryName: "",
                categoryColor: "",
                active: true,
                displayOrder: 0
            }])
            routinesChanged()
            return true
        }

        function deleteRoutine(id) {
            return true
        }

        function setRoutineActive(id, active) {
            return true
        }
    }

    QtObject {
        id: fakeCategoryManager

        function getAllCategories() {
            return []
        }
    }

    RoutineDialog {
        id: dialog
        routineManagerRef: fakeRoutineManager
        categoryManagerRef: fakeCategoryManager
    }

    function test_addRoutineShowsInList() {
        testCase.added = []
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
        compare(list.count, 1)
        dialog.close()
    }
}
