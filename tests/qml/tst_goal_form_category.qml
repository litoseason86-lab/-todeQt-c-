import QtQuick
import QtTest
import "../../qml/components"

// 目标表单的科目下拉：取消「+ 新建科目…」后按科目编号恢复（2026-09-14 审查修复，规则见 docs/业务规则.md「科目下拉的内联新建」）。
//
// 这个弹窗在打开期间会随 categoriesChanged 重建列表，科目按 display_order、name 排序，
// 别处新建或改名都可能让已选科目换位置——下标在这里是真会漂的。
TestCase {
    id: testCase
    name: "GoalFormCategoryRestore"
    when: windowShown
    width: 800
    height: 700

    QtObject {
        id: categoryManager

        signal categoriesChanged()
        signal operationFailed(string message)

        // 不能叫 categories：属性自带 categoriesChanged，会和上面显式声明的信号重名。
        property var rows: [
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]

        function getAllCategories() { return rows }
        function addCategory(name, color) { return 0 }
    }

    GoalFormDialog {
        id: form
        categoryManagerRef: categoryManager
    }

    function init() {
        categoryManager.rows = [
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]
        if (form.visible) {
            form.close()
            tryCompare(form, "visible", false, 2000)
        }
    }

    function indexOf(id) {
        for (var i = 0; i < form.categories.length; ++i) {
            if (Number(form.categories[i].id) === id)
                return i
        }
        return -1
    }

    function test_cancelNewCategoryRestoresSameCategoryAfterListReorders() {
        form.openForAdd()
        tryCompare(form, "opened", true, 2000)
        var combo = findChild(form, "goalCategoryCombo")
        verify(combo)

        combo.currentIndex = indexOf(2)
        form.handleCategoryActivated(combo.currentIndex)
        compare(form.lastRealCategoryId, 2)

        // 打开期间别处插进一条排在前面的科目：「英语」换了下标。
        categoryManager.rows = [
            { id: 3, name: "高数", color: "#aaaaaa" },
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]
        categoryManager.categoriesChanged()
        compare(combo.currentIndex, indexOf(2))

        form.handleCategoryActivated(form.categories.length - 1)
        findChild(form, "goalNewCategoryPrompt").close()

        compare(Number(form.categories[combo.currentIndex].id), 2)
    }

    function test_cancelNeverLandsOnSentinelWhenRestorePointWasRemoved() {
        form.openForAdd()
        tryCompare(form, "opened", true, 2000)
        var combo = findChild(form, "goalCategoryCombo")
        combo.currentIndex = indexOf(2)
        form.handleCategoryActivated(combo.currentIndex)

        // 恢复点那个科目被删掉了。
        categoryManager.rows = [ { id: 1, name: "数学", color: "#d4a574" } ]
        categoryManager.categoriesChanged()

        form.handleCategoryActivated(form.categories.length - 1)
        findChild(form, "goalNewCategoryPrompt").close()

        verify(combo.currentIndex < form.realCategoryCount,
               "取消后下拉停在了「+ 新建科目…」上：" + combo.currentIndex)
    }
}
