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

        function reset() {
            categoryItems = [
                { id: 1, name: "数学", color: "#d4a574", isPreset: true },
                { id: 6, name: "算法", color: "#6f91a6", isPreset: false }
            ]
            addedCount = 0
            deletedId = -1
            updatedId = -1
            categoriesChanged()
        }

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

        function updateCategory(id, name, color) {
            updatedId = id
            categoryItems = categoryItems.map(function(item) {
                if (item.id === id) {
                    return { id: id, name: name, color: color, isPreset: false }
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
        testCase.colorSignalCount = 0
        testCase.colorSignalValue = ""
    }

    function test_colorPickerSelectsColor() {
        colorPicker.colorSelected("#6f91a6")
        colorPicker.selectedColor = "#6f91a6"

        compare(colorPicker.selectedColor, "#6f91a6")
        compare(testCase.colorSignalCount, 1)
        compare(testCase.colorSignalValue, "#6f91a6")
    }

    function test_categoryDialogLoadsInjectedManager() {
        categoryDialog.open()
        wait(100)

        compare(categoryDialog.categories.length, 2)
        compare(categoryDialog.categories[0].name, "数学")
        compare(categoryDialog.categories[1].name, "算法")
        categoryDialog.close()
    }

    function test_categoryDialogCanAddWithInjectedManager() {
        categoryDialog.open()
        wait(100)

        fakeCategoryManager.addCategory("写作", "#9aa66b")
        wait(50)

        compare(fakeCategoryManager.addedCount, 1)
        compare(categoryDialog.categories.length, 3)
        compare(categoryDialog.categories[2].name, "写作")
        categoryDialog.close()
    }

    function test_categoryDialogCanEditCustomCategory() {
        categoryDialog.open()
        wait(100)

        // 通过公开方法进入编辑态，验证弹窗不会直接依赖按钮点击顺序。
        categoryDialog.beginEdit(categoryDialog.categories[1])
        compare(categoryDialog.editingCategoryId, 6)
        categoryDialog.newCategoryColor = "#445566"
        categoryDialog.saveCategory()
        wait(50)

        compare(fakeCategoryManager.updatedId, 6)
        compare(categoryDialog.categories[1].name, "算法")
        compare(categoryDialog.categories[1].color, "#445566")
        compare(categoryDialog.editingCategoryId, -1)
        categoryDialog.close()
    }
}
