import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "RoutineDialogUi"
    when: windowShown
    width: 1024
    height: 768

    property var added: []
    property int addCalls: 0
    property int lastCategoryId: -999
    property int updateCalls: 0
    property int updatedRoutineId: -1
    property string updatedTitle: ""
    property int updatedCategoryId: -999
    property int deletedId: -1
    property bool addResult: true
    property bool updateResult: true

    QtObject {
        id: fakeRoutineManager

        signal routinesChanged()
        signal operationFailed(string message)
        property bool failLoad: false

        function getRoutines() {
            if (failLoad) {
                operationFailed("例行数据库故障")
                return []
            }
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

        function updateRoutine(id, title, categoryId) {
            testCase.updateCalls += 1
            testCase.updatedRoutineId = id
            testCase.updatedTitle = title
            testCase.updatedCategoryId = categoryId
            if (!testCase.updateResult) {
                return false
            }

            testCase.added = testCase.added.map(function(item) {
                if (item.id !== id) {
                    return item
                }
                return {
                    id: item.id,
                    title: title,
                    categoryId: categoryId,
                    categoryName: categoryId === 7 ? "数学" : "",
                    categoryColor: categoryId === 7 ? "#d4a574" : "",
                    active: item.active,
                    displayOrder: item.displayOrder
                }
            })
            routinesChanged()
            return true
        }

        function setRoutineActive(id, active) {
            return true
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
        testCase.updateCalls = 0
        testCase.updatedRoutineId = -1
        testCase.updatedTitle = ""
        testCase.updatedCategoryId = -999
        testCase.deletedId = -1
        testCase.addResult = true
        testCase.updateResult = true
        fakeRoutineManager.failLoad = false
        fakeCategoryManager.failLoad = false
        dialog.routineManagerRef = fakeRoutineManager
        dialog.categoryManagerRef = fakeCategoryManager
        dialog.close()
        // Popup 有退出过渡；等真正关闭后再开启，避免下个用例沿用上次列表模型。
        tryCompare(dialog, "opened", false, 3000)
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

    function test_refreshFailureIsNotClearedWhenDialogOpens() {
        fakeRoutineManager.failLoad = true
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        compare(dialog.errorText, "例行数据库故障")

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

    function test_titleFieldUsesReadableSurface() {
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var input = findChild(dialog, "routineTitleField")
        verify(input !== null)
        verify(Qt.colorEqual(input.background.color, Theme.surfaceSunken))
        verify(Qt.colorEqual(input.color, Theme.ink))
        verify(Qt.colorEqual(input.placeholderTextColor, Theme.inkMuted))
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

    function test_editRoutineLoadsValuesAndSavesChanges() {
        testCase.added = [{
            id: 42,
            title: "复习英语",
            categoryId: -1,
            categoryName: "",
            categoryColor: "",
            active: true,
            displayOrder: 1
        }]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var input = findChild(dialog, "routineTitleField")
        var categoryCombo = findChild(dialog, "routineCategoryCombo")
        var saveButton = findChild(dialog, "routineAddButton")
        verify(input !== null)
        verify(categoryCombo !== null)
        verify(saveButton !== null)

        compare(dialog.routines.length, 1)
        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 42)
        compare(input.text, "复习英语")
        tryCompare(saveButton, "text", "保存")

        input.focus = true
        input.text = "复习 2026 & 英语"
        categoryCombo.currentIndex = 1
        mouseClick(saveButton)
        tryCompare(testCase, "updateCalls", 1)
        compare(testCase.updatedRoutineId, 42)
        compare(testCase.updatedTitle, "复习 2026 & 英语")
        compare(testCase.updatedCategoryId, 7)
        compare(testCase.added[0].title, "复习 2026 & 英语")
        compare(testCase.added[0].categoryId, 7)
        tryCompare(dialog, "editingRoutineId", -1)
        compare(input.text, "")
        dialog.close()
    }

    function test_editFailureKeepsValuesForCorrection() {
        testCase.added = [{
            id: 24,
            title: "错题复盘",
            categoryId: -1,
            categoryName: "",
            categoryColor: "",
            active: true,
            displayOrder: 1
        }]
        testCase.updateResult = false
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var input = findChild(dialog, "routineTitleField")
        verify(input !== null)

        compare(dialog.routines.length, 1)
        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 24)
        input.focus = true
        input.text = "错题复盘 2"
        dialog.submit()

        compare(testCase.updateCalls, 1)
        compare(dialog.editingRoutineId, 24)
        compare(input.text, "错题复盘 2")
        compare(dialog.errorText, "例行任务保存失败，请检查名称后重试")
        dialog.close()
    }

    function test_cancelEditingRestoresAddMode() {
        testCase.added = [{
            id: 75,
            title: "晨间计划",
            categoryId: -1,
            categoryName: "",
            categoryColor: "",
            active: true,
            displayOrder: 1
        }]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var input = findChild(dialog, "routineTitleField")
        var submitButton = findChild(dialog, "routineAddButton")
        verify(input !== null)
        verify(submitButton !== null)

        compare(dialog.routines.length, 1)
        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 75)
        var cancelButton = findChild(dialog, "routineCancelEditButton")
        verify(cancelButton !== null)
        mouseClick(cancelButton)
        tryCompare(dialog, "editingRoutineId", -1)
        compare(input.text, "")
        tryCompare(submitButton, "text", "添加")
        dialog.close()
    }

    function test_deletingEditedRoutineLeavesAddMode() {
        testCase.added = [{
            id: 89,
            title: "晚间复盘",
            categoryId: -1,
            categoryName: "",
            categoryColor: "",
            active: true,
            displayOrder: 1
        }]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var input = findChild(dialog, "routineTitleField")
        verify(input !== null)
        compare(dialog.routines.length, 1)
        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 89)

        dialog.deleteRoutine(89)
        compare(testCase.deletedId, 89)
        compare(dialog.editingRoutineId, -1)
        compare(input.text, "")
        compare(testCase.added.length, 0)
        dialog.close()
    }
}
