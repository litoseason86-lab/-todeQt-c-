import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "Phase3CategoryUi"
    when: windowShown
    width: 720
    height: 560

    QtObject {
        id: fakeCategoryManager

        signal categoriesChanged()

        // 假服务只保留界面测试需要的字段，避免测试依赖真实数据库。
        property var categoryItems: [
            { id: 1, name: "数学", color: "#d4a574", isPreset: true },
            { id: 6, name: "算法", color: "#6f91a6", isPreset: false }
        ]
        property int addedCount: 0
        property int deletedId: -1
        property int updatedId: -1
        property int updateCalls: 0
        property var lastUpdatedChanges: ({})
        property int nameExistsChecks: 0

        function reset() {
            categoryItems = [
                { id: 1, name: "数学", color: "#d4a574", isPreset: true },
                { id: 6, name: "算法", color: "#6f91a6", isPreset: false }
            ]
            addedCount = 0
            deletedId = -1
            updatedId = -1
            updateCalls = 0
            lastUpdatedChanges = ({})
            nameExistsChecks = 0
            categoriesChanged()
        }

        function readAllCategories() { return { ok: true, categories: getAllCategories() } }
        function getAllCategories() {
            return categoryItems
        }

        function addCategory(name, color) {
            addedCount += 1
            categoryItems = categoryItems.concat([{ id: 10 + addedCount, name: name, color: color, isPreset: false }])
            categoriesChanged()
            return 10 + addedCount
        }

        function canDeleteCategory(id) {
            return id === 6
        }

        function categoryNameExists(name, excludeId) {
            nameExistsChecks += 1
            for (var i = 0; i < categoryItems.length; ++i) {
                if (categoryItems[i].id !== excludeId && categoryItems[i].name === name)
                    return true
            }
            return false
        }

        function updateCategory(id, name, color) {
            return updateCategoryChanges(id, { name: name, color: color })
        }

        function updateCategoryChanges(id, changes) {
            updatedId = id
            updateCalls += 1
            lastUpdatedChanges = Object.assign({}, changes)
            categoryItems = categoryItems.map(function(item) {
                if (item.id === id) {
                    return {
                        id: id,
                        name: changes.name !== undefined ? changes.name : item.name,
                        color: changes.color !== undefined ? changes.color : item.color,
                        isPreset: item.isPreset
                    }
                }
                return item
            })
            categoriesChanged()
            return true
        }

        function deleteCategory(id) {
            deletedId = id
            categoryItems = categoryItems.filter(function(item) { return item.id !== id })
            categoriesChanged()
            return true
        }
    }

    ColorPicker {
        id: colorPicker
        selectedColor: "#d4a574"
    }

    CategoryDialog {
        id: categoryDialog
        manager: fakeCategoryManager
    }

    property int colorSignalCount: 0
    property string colorSignalValue: ""

    Connections {
        target: colorPicker

        function onColorSelected(color) {
            testCase.colorSignalCount += 1
            testCase.colorSignalValue = color
        }
    }

    function init() {
        fakeCategoryManager.reset()
        categoryDialog.close()
        colorPicker.selectedColor = "#d4a574"
        testCase.colorSignalCount = 0
        testCase.colorSignalValue = ""
    }

    function test_colorPickerSelectsColor() {
        var swatch = findChild(colorPicker, "colorSwatch-2")
        verify(swatch)
        testCase.visible = true
        colorPicker.visible = true
        try {
            waitForRendering(colorPicker)
            mouseClick(swatch)
            compare(colorPicker.selectedColor, "#be8568")
            compare(testCase.colorSignalCount, 1)
            compare(testCase.colorSignalValue, "#be8568")
        } finally {
            testCase.visible = false
        }
    }

    function test_categoryDialogLoadsInjectedManager() {
        categoryDialog.open()

        tryVerify(function () { return categoryDialog.categories.length === 2 }, 5000, "categoryDialog.categories.length 应为 2")
        compare(categoryDialog.categories[0].name, "数学")
        compare(categoryDialog.categories[1].name, "算法")
        categoryDialog.close()
    }

    function test_categoryDialogCanAddWithInjectedManager() {
        testCase.visible = true
        try {
            categoryDialog.open()
            tryCompare(categoryDialog, "opened", true)
            var addButton = findChild(categoryDialog, "addCategoryButton")
            verify(addButton)
            addButton.clicked()

            var input = findChild(categoryDialog, "categoryNameInput")
            verify(input)
            input.text = "写作"

            var swatch = null
            tryVerify(function () {
                swatch = findChild(categoryDialog.contentItem, "colorSwatch-4")
                return swatch !== null && swatch.width > 0
            }, 3000)
            waitForRendering(swatch)
            mouseClick(swatch)

            var saveButton = findChild(categoryDialog, "saveCategoryButton")
            verify(saveButton)
            saveButton.clicked()

            tryCompare(fakeCategoryManager, "addedCount", 1)
            compare(categoryDialog.categories.length, 3)
            compare(categoryDialog.categories[2].name, "写作")
            // ColorPicker.colors[4] 对应第六项 #a8655c（索引从 0 开始）
            compare(categoryDialog.categories[2].color, "#a8655c")
            categoryDialog.close()
        } finally {
            testCase.visible = false
        }
    }

    function test_categoryDialogCanEditCustomCategory() {
        categoryDialog.open()

        // 通过公开方法进入编辑态，验证弹窗不会直接依赖按钮点击顺序。
        categoryDialog.beginEdit(categoryDialog.categories[1])
        compare(categoryDialog.editingCategoryId, 6)
        categoryDialog.newCategoryColor = "#445566"
        categoryDialog.saveCategory()

        compare(fakeCategoryManager.updatedId, 6)
        compare(categoryDialog.categories[1].name, "算法")
        compare(categoryDialog.categories[1].color, "#445566")
        compare(categoryDialog.editingCategoryId, -1)
        categoryDialog.close()
    }

    function test_categoryDialogCanEditPresetCategory() {
        categoryDialog.open()

        const listView = findChild(categoryDialog, "categoryListView")
        verify(listView)
        const firstRow = listView.itemAtIndex(0)
        verify(firstRow)
        const editButton = findChild(firstRow, "editCategoryButton-1")
        verify(editButton)
        compare(editButton.visible, true)

        categoryDialog.beginEdit(categoryDialog.categories[0])
        compare(categoryDialog.editingCategoryId, 1)

        const input = findChild(categoryDialog, "categoryNameInput")
        verify(input)
        compare(input.text, "数学")
        input.text = "高等数学"
        categoryDialog.newCategoryColor = "#334455"
        categoryDialog.saveCategory()

        compare(fakeCategoryManager.updatedId, 1)
        compare(categoryDialog.categories[0].name, "高等数学")
        compare(categoryDialog.categories[0].color, "#334455")
        compare(categoryDialog.categories[0].isPreset, true)
        compare(categoryDialog.editingCategoryId, -1)
        categoryDialog.close()
    }

    function test_categoryDeletionRequiresConfirmation() {
        categoryDialog.open()
        tryCompare(categoryDialog, "opened", true)
        categoryDialog.deleteCategory(6)
        var confirmation = findChild(categoryDialog, "categoryDeleteConfirmation")
        verify(confirmation)
        tryCompare(confirmation, "opened", true)
        compare(fakeCategoryManager.deletedId, -1)
        confirmation.close()
        compare(fakeCategoryManager.deletedId, -1)
        categoryDialog.deleteCategory(6)
        tryCompare(confirmation, "opened", true)
        findChild(categoryDialog, "confirmCategoryDeleteButton").clicked()
        compare(fakeCategoryManager.deletedId, 6)
    }

    function test_editorShowsServiceFailureAboveItsPanel() {
        categoryDialog.open()
        tryCompare(categoryDialog, "opened", true)
        categoryDialog.beginEdit(categoryDialog.categories[1])
        categoryDialog.errorText = "科目名称已存在"
        var error = findChild(categoryDialog, "categoryEditorError")
        verify(error)
        compare(error.text, "科目名称已存在")
        verify(error.parent.parent.visible)
    }

    // 产品保证：编辑科目只改颜色时仅提交 color 字段、跳过重名校验，不把弹窗打开期间远端已同步改掉的科目名覆盖回旧值；未改动任何字段时不写库。
    function test_categoryDialogColorOnlyEditPreservesRemoteRenameAndNoOpSkipsWrite() {
        categoryDialog.open()
        tryCompare(categoryDialog, "opened", true)

        // 1. 打开编辑「算法」，期间远端同步把库中该科目改名为「数据结构与算法」。
        categoryDialog.beginEdit(categoryDialog.categories[1])
        compare(categoryDialog.editingCategoryId, 6)
        fakeCategoryManager.categoryItems = [
            { id: 1, name: "数学", color: "#d4a574", isPreset: true },
            { id: 6, name: "数据结构与算法", color: "#6f91a6", isPreset: false }
        ]

        // 只改颜色并保存：changes 只能含 color，不能含 name，且不触发重名查询。
        categoryDialog.newCategoryColor = "#7a5544"
        categoryDialog.saveCategory()

        compare(fakeCategoryManager.updateCalls, 1)
        compare(fakeCategoryManager.nameExistsChecks, 0)
        compare(fakeCategoryManager.lastUpdatedChanges.name, undefined)
        compare(fakeCategoryManager.lastUpdatedChanges.color, "#7a5544")
        compare(categoryDialog.categories[1].name, "数据结构与算法")
        compare(categoryDialog.categories[1].color, "#7a5544")

        // 2. 重新打开编辑但什么都不改直接保存：不调写库接口，直接退出编辑态。
        categoryDialog.beginEdit(categoryDialog.categories[1])
        compare(categoryDialog.editingCategoryId, 6)
        categoryDialog.saveCategory()
        compare(fakeCategoryManager.updateCalls, 1)
        compare(categoryDialog.editingCategoryId, -1)
        categoryDialog.close()
    }

}
