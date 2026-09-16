import QtQuick
import QtTest
import "../../qml/components"

// 目标表单的「目标投入」字段：打开、编辑、再保存不能悄悄改掉用户的目标量。
//
// 目标上限是 60000 分钟（1000 小时），旧版「番茄数 × 25」迁移过来的目标
// 超过 99 小时很常见（240 个番茄以上）。输入框只要少收一位，打开编辑的那一刻
// 数字就被截短，用户只改个标题点保存，目标量就被写成了截短后的值。
TestCase {
    id: testCase
    name: "GoalFormTarget"
    when: windowShown
    width: 800
    height: 700

    QtObject {
        id: categoryManager

        signal categoriesChanged()
        signal operationFailed(string message)

        function getAllCategories() {
            return [ { id: 1, name: "数学", color: "#d4a574" } ]
        }
        function addCategory(name, color) { return -1 }
    }

    QtObject {
        id: goalService

        signal operationFailed(string message)

        readonly property int maxTitleLength: 100
        readonly property int maxTargetMinutes: 60000
        property var lastUpdate: null

        function updateGoal(goalId, title, categoryId, targetMinutes, startDate, deadline) {
            lastUpdate = { goalId: goalId, title: title, targetMinutes: targetMinutes }
            return true
        }
        function addGoal(title, categoryId, targetMinutes, startDate, deadline) {
            return true
        }
    }

    GoalFormDialog {
        id: form
        categoryManagerRef: categoryManager
        goalServiceRef: goalService
    }

    function init() {
        goalService.lastUpdate = null
        if (form.visible) {
            form.close()
            tryCompare(form, "visible", false, 2000)
        }
    }

    function test_editingGoalAbove99HoursKeepsTargetUnchanged() {
        // 25000 分钟 = 416 小时 40 分钟：小时框需要三位数字。
        form.openForEdit({ id: 7, title: "考研数学", categoryId: 1,
                           targetMinutes: 25000, startDate: "2026-09-01" })
        tryCompare(form, "opened", true, 2000)

        const hourField = findChild(form, "goalTargetHourField")
        verify(hourField)
        compare(hourField.text, "416")

        verify(form.submit(), "保存失败：" + form.errorText)
        verify(goalService.lastUpdate)
        compare(goalService.lastUpdate.targetMinutes, 25000)
    }

    function test_targetAtTheThousandHourCapCanBeEntered() {
        form.openForEdit({ id: 8, title: "长期阅读", categoryId: 1,
                           targetMinutes: 60000, startDate: "2026-09-01" })
        tryCompare(form, "opened", true, 2000)

        compare(findChild(form, "goalTargetHourField").text, "1000")
        verify(form.submit(), "保存失败：" + form.errorText)
        compare(goalService.lastUpdate.targetMinutes, 60000)
    }

    function test_newGoalResetsDurationAndClosingPreventsAnotherSave() {
        form.openForAdd()
        tryCompare(form, "opened", true)
        findChild(form, "goalTargetHourField").text = "15"
        form.close()
        tryCompare(form, "visible", false)
        form.openForAdd()
        tryCompare(form, "opened", true)
        compare(findChild(form, "goalTargetHourField").text, "1")
        compare(findChild(form, "goalTargetMinuteField").text, "40")
        findChild(form, "goalTitleField").text = "测试目标"
        verify(form.submit())
        verify(!form.submit(), "关闭中的表单不允许再次创建")
    }

}
