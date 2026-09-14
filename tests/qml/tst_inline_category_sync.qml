import QtQuick
import QtTest
import "../../qml/components"

// 科目下拉内联新建的两条验收（2026-09-14 统一验收补测，规则见 docs/业务规则.md「科目下拉的内联新建」）：
// 1. 新建任务、编辑任务弹窗与目标表单里就地建完科目，下拉自动选中新科目；
// 2. 新建后 categoriesChanged 到达，其它开着的弹窗下拉同步刷新——四个带科目下拉的弹窗
//    （新建任务、编辑任务、目标表单、知识缺口）都订阅，并按科目编号保住原选中。
//
// 替身按 CategoryManager::addCategory 的真实时序写：先发 categoriesChanged，再返回新编号。
// 顺序反过来的替身会让「收到信号时新科目还查不到」这类问题在测试里消失。
TestCase {
    id: testCase
    name: "InlineCategorySync"
    when: windowShown
    width: 900
    height: 760

    QtObject {
        id: categoryManager

        signal categoriesChanged()
        signal operationFailed(string message)

        // 不能叫 categories：属性自带 categoriesChanged，会和上面显式声明的信号重名。
        property var rows: []
        property int nextId: 30

        function getAllCategories() { return rows }
        function addCategory(name, color) {
            var id = nextId
            nextId += 1
            rows = rows.concat([{ id: id, name: String(name), color: String(color) }])
            categoriesChanged()
            return id
        }
    }

    AddTaskDialog {
        id: addDialog
        categoryManagerRef: categoryManager
    }

    EditTaskDialog {
        id: editDialog
        categoryManagerRef: categoryManager
    }

    GoalFormDialog {
        id: goalForm
        categoryManagerRef: categoryManager
    }

    KnowledgeGapDialog {
        id: gapDialog
        categoryManagerRef: categoryManager
    }

    function init() {
        categoryManager.rows = [
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]
        categoryManager.nextId = 30
        var dialogs = [addDialog, editDialog, goalForm, gapDialog]
        for (var i = 0; i < dialogs.length; ++i) {
            if (dialogs[i].visible) {
                dialogs[i].close()
                tryCompare(dialogs[i], "visible", false, 2000)
            }
        }
    }

    function createThroughPrompt(host, promptName, name) {
        var prompt = findChild(host, promptName)
        verify(prompt !== null, "找不到 " + promptName)
        prompt.openPrompt()
        var field = findChild(prompt, "newCategoryPromptField")
        verify(field !== null)
        field.text = name
        prompt.submit()
        return prompt
    }

    function test_editTaskDialogSelectsTheCategoryItJustCreated() {
        editDialog.openForTask({ id: 9, title: "单词", categoryId: 2, date: new Date(),
                                 estimatedMinutes: 0, notes: "" })
        tryCompare(editDialog, "opened", true, 2000)
        var combo = findChild(editDialog, "editCategoryCombo")
        verify(combo !== null)

        createThroughPrompt(editDialog, "editTaskNewCategoryPrompt", "政治")

        compare(Number(editDialog.categoryOptions[combo.currentIndex].id), 30)
        compare(String(editDialog.categoryOptions[combo.currentIndex].name), "政治")
    }

    function test_addTaskDialogSelectsTheCategoryItJustCreated() {
        // 服务先发 categoriesChanged 再返回编号：开着时的刷新先跑一遍（保住当前选中），
        // 之后 onCreated 才选中新科目。两段的先后不能让新科目被刷新冲掉。
        addDialog.open()
        tryCompare(addDialog, "opened", true, 2000)
        verify(addDialog.selectCategoryById(2))
        var combo = findChild(addDialog, "categoryComboBox")

        createThroughPrompt(addDialog, "addTaskNewCategoryPrompt", "政治")

        compare(Number(addDialog.categoryOptions[combo.currentIndex].id), 30)
        compare(addDialog.lastRealCategoryId, 30)
    }

    function test_goalFormSelectsTheCategoryItJustCreated() {
        goalForm.openForAdd()
        tryCompare(goalForm, "opened", true, 2000)
        var combo = findChild(goalForm, "goalCategoryCombo")
        verify(combo !== null)

        createThroughPrompt(goalForm, "goalNewCategoryPrompt", "专业课")

        compare(goalForm.selectedCategoryId, 30)
        compare(Number(goalForm.categories[combo.currentIndex].id), 30)
    }

    function test_openKnowledgeGapDialogPicksUpCategoryCreatedElsewhere() {
        gapDialog.openForAdd()
        tryCompare(gapDialog, "opened", true, 2000)
        gapDialog.selectedCategoryId = 2
        gapDialog.syncCategoryBox()

        goalForm.openForAdd()
        tryCompare(goalForm, "opened", true, 2000)
        createThroughPrompt(goalForm, "goalNewCategoryPrompt", "政治")

        var ids = gapDialog.categoryChoices.map(function (c) { return Number(c.id) })
        verify(ids.indexOf(30) >= 0, "开着的知识缺口弹窗没刷出新科目：" + JSON.stringify(ids))
        // 刷新不能把它原来选中的科目冲掉。
        compare(gapDialog.selectedCategoryId, 2)
    }

    // —— 新建任务、编辑任务弹窗开着时科目在别处变了（2026-09-14 补齐原验收项）——
    // 此前这两个弹窗只在打开时和自己建完科目后刷新，别处的增删改都看不到：
    // 新科目选不到，被删的科目还挂在下拉里、照样能提交出去。

    function selectedId(dialog, comboName) {
        var combo = findChild(dialog, comboName)
        verify(combo !== null, "找不到 " + comboName)
        verify(combo.currentIndex >= 0 && combo.currentIndex < dialog.categoryOptions.length,
               comboName + " 的下标越界：" + combo.currentIndex)
        return Number(dialog.categoryOptions[combo.currentIndex].id)
    }

    function optionIds(dialog) {
        return dialog.categoryOptions.map(function (c) { return Number(c.id) })
    }

    function openAddDialogOnEnglish() {
        addDialog.open()
        tryCompare(addDialog, "opened", true, 2000)
        verify(addDialog.selectCategoryById(2))
        compare(selectedId(addDialog, "categoryComboBox"), 2)
    }

    function openEditDialogOnEnglish() {
        editDialog.openForTask({ id: 9, title: "单词", categoryId: 2, date: new Date(),
                                 estimatedMinutes: 0, notes: "" })
        tryCompare(editDialog, "opened", true, 2000)
        compare(selectedId(editDialog, "editCategoryCombo"), 2)
    }

    function test_openAddTaskDialogPicksUpCategoryCreatedElsewhere() {
        openAddDialogOnEnglish()

        goalForm.openForAdd()
        tryCompare(goalForm, "opened", true, 2000)
        createThroughPrompt(goalForm, "goalNewCategoryPrompt", "政治")

        verify(optionIds(addDialog).indexOf(30) >= 0,
               "开着的新建任务弹窗没刷出新科目：" + JSON.stringify(optionIds(addDialog)))
        compare(selectedId(addDialog, "categoryComboBox"), 2)
        // 哨兵仍在末尾。
        compare(optionIds(addDialog)[addDialog.categoryOptions.length - 1], addDialog.newCategorySentinelId)
    }

    function test_openAddTaskDialogKeepsSelectionByIdWhenListReorders() {
        openAddDialogOnEnglish()

        // 别处插进一条排在前面的科目：「英语」换了下标。
        categoryManager.rows = [
            { id: 9, name: "高数", color: "#aaaaaa" },
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]
        categoryManager.categoriesChanged()

        verify(optionIds(addDialog).indexOf(9) >= 0, JSON.stringify(optionIds(addDialog)))
        compare(selectedId(addDialog, "categoryComboBox"), 2)
        compare(addDialog.lastRealCategoryId, 2)
    }

    function test_openAddTaskDialogFallsBackWhenSelectedCategoryIsRemoved() {
        openAddDialogOnEnglish()

        categoryManager.rows = [ { id: 1, name: "数学", color: "#d4a574" } ]
        categoryManager.categoriesChanged()

        verify(optionIds(addDialog).indexOf(2) < 0,
               "被删的科目还挂在下拉里：" + JSON.stringify(optionIds(addDialog)))
        // 回到「不设置科目」，不能停在别的科目或哨兵上。
        compare(selectedId(addDialog, "categoryComboBox"), -1)
        compare(addDialog.lastRealCategoryId, -1)
    }

    function test_openEditTaskDialogPicksUpCategoryCreatedElsewhere() {
        openEditDialogOnEnglish()

        goalForm.openForAdd()
        tryCompare(goalForm, "opened", true, 2000)
        createThroughPrompt(goalForm, "goalNewCategoryPrompt", "政治")

        verify(optionIds(editDialog).indexOf(30) >= 0,
               "开着的编辑任务弹窗没刷出新科目：" + JSON.stringify(optionIds(editDialog)))
        compare(selectedId(editDialog, "editCategoryCombo"), 2)
        compare(optionIds(editDialog)[editDialog.categoryOptions.length - 1], editDialog.newCategorySentinelId)
    }

    function test_openEditTaskDialogKeepsSelectionByIdWhenListReorders() {
        openEditDialogOnEnglish()

        categoryManager.rows = [
            { id: 9, name: "高数", color: "#aaaaaa" },
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]
        categoryManager.categoriesChanged()

        verify(optionIds(editDialog).indexOf(9) >= 0, JSON.stringify(optionIds(editDialog)))
        compare(selectedId(editDialog, "editCategoryCombo"), 2)
        compare(editDialog.lastRealCategoryId, 2)
    }

    function test_openEditTaskDialogFallsBackWhenSelectedCategoryIsRemoved() {
        openEditDialogOnEnglish()

        categoryManager.rows = [ { id: 1, name: "数学", color: "#d4a574" } ]
        categoryManager.categoriesChanged()

        verify(optionIds(editDialog).indexOf(2) < 0,
               "被删的科目还挂在下拉里：" + JSON.stringify(optionIds(editDialog)))
        compare(selectedId(editDialog, "editCategoryCombo"), -1)
        compare(editDialog.lastRealCategoryId, -1)
    }

    function test_openGoalFormPicksUpCategoryCreatedElsewhereAndKeepsSelection() {
        goalForm.openForAdd()
        tryCompare(goalForm, "opened", true, 2000)
        var combo = findChild(goalForm, "goalCategoryCombo")
        combo.currentIndex = 1
        goalForm.handleCategoryActivated(1)
        var chosen = Number(goalForm.categories[1].id)

        editDialog.openForTask({ id: 9, title: "单词", categoryId: 1, date: new Date(),
                                 estimatedMinutes: 0, notes: "" })
        tryCompare(editDialog, "opened", true, 2000)
        createThroughPrompt(editDialog, "editTaskNewCategoryPrompt", "政治")

        var ids = goalForm.categories.map(function (c) { return Number(c.id) })
        verify(ids.indexOf(30) >= 0, "开着的目标表单没刷出新科目：" + JSON.stringify(ids))
        compare(goalForm.selectedCategoryId, chosen)
        compare(Number(goalForm.categories[combo.currentIndex].id), chosen)
    }
}
