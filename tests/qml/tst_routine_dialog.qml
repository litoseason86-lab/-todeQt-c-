import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"
import "../../qml/RoutineWeekdays.js" as Weekdays

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
    property var lastChanges: null
    property int updatedRoutineId: -1
    property string updatedTitle: ""
    property int updatedCategoryId: -999
    property var lastWeekdays: -999
    property var updatedWeekdays: -999
    property int weekdaysCalls: 0
    property int weekdaysRoutineId: -1
    property bool weekdaysResult: true
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

        function addRoutine(title, categoryId, weekdays) {
            testCase.addCalls += 1
            testCase.lastCategoryId = categoryId
            // 弹窗不再传重复日；留着这个形参是为了记录「确实没传」（undefined）。
            testCase.lastWeekdays = weekdays
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
                displayOrder: 0,
                // 服务层对省略的 weekdays 按「每天」落地，替身照做。
                weekdays: weekdays === undefined ? 0x7F : weekdays
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

        // 编辑只交改过的字段：记下改动表本身，再按服务层的口径把没交的字段原样留着。
        function updateRoutineChanges(id, changes) {
            testCase.updateCalls += 1
            testCase.updatedRoutineId = id
            testCase.lastChanges = changes
            if (changes.title !== undefined)
                testCase.updatedTitle = changes.title
            if (changes.categoryId !== undefined)
                testCase.updatedCategoryId = changes.categoryId
            // 改标题/科目不该带重复日过来；记下来好断言它确实是 undefined。
            testCase.updatedWeekdays = changes.weekdays
            if (!testCase.updateResult) {
                return false
            }

            testCase.added = testCase.added.map(function(item) {
                if (item.id !== id) {
                    return item
                }
                var categoryId = changes.categoryId === undefined ? item.categoryId : changes.categoryId
                return {
                    id: item.id,
                    title: changes.title === undefined ? item.title : changes.title,
                    categoryId: categoryId,
                    categoryName: categoryId === 7 ? "数学" : "",
                    categoryColor: categoryId === 7 ? "#d4a574" : "",
                    active: item.active,
                    displayOrder: item.displayOrder,
                    // 重复日由 setRoutineWeekdays 单独写，更新标题时原样保留。
                    weekdays: item.weekdays
                }
            })
            routinesChanged()
            return true
        }

        function setRoutineActive(id, active) {
            return true
        }

        function setRoutineWeekdays(id, weekdays) {
            testCase.weekdaysCalls += 1
            testCase.weekdaysRoutineId = id
            testCase.lastWeekdays = weekdays
            if (!testCase.weekdaysResult) {
                return false
            }
            testCase.added = testCase.added.map(function(item) {
                if (item.id !== id) {
                    return item
                }
                return {
                    id: item.id, title: item.title, categoryId: item.categoryId,
                    categoryName: item.categoryName, categoryColor: item.categoryColor,
                    active: item.active, displayOrder: item.displayOrder, weekdays: weekdays
                }
            })
            routinesChanged()
            return true
        }
    }

    QtObject {
        id: fakeCategoryManager

        signal operationFailed(string message)
        property bool failLoad: false

        // 界面读科目走这里：成败放在返回值里，和真实服务一样不发失败信号。
        function readAllCategories() {
            if (failLoad)
                return { ok: false, categories: [], error: "科目数据库故障" }
            return { ok: true, categories: getAllCategories() }
        }
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
        testCase.lastChanges = null
        testCase.updatedRoutineId = -1
        testCase.updatedTitle = ""
        testCase.updatedCategoryId = -999
        testCase.lastWeekdays = -999
        testCase.updatedWeekdays = -999
        testCase.weekdaysCalls = 0
        testCase.weekdaysRoutineId = -1
        testCase.weekdaysResult = true
        testCase.deletedId = -1
        testCase.addResult = true
        testCase.updateResult = true
        fakeRoutineManager.failLoad = false
        fakeCategoryManager.failLoad = false
        dialog.routineManagerRef = fakeRoutineManager
        dialog.categoryManagerRef = fakeCategoryManager
        // 重复弹窗是套在本弹窗上的第二层 Popup：上一条用例开着它离开，
        // 会挡住后面用例的点击（用例按函数名字母序跑，不是书写顺序）。
        dialog.weekdayDialogRef.close()
        // 切过主题的用例若中途失败就来不及还原；每条用例开始前统一回到暖色主题。
        Theme.activeThemeId = "warm"
        dialog.close()
        // Popup 有退出过渡；等真正关闭后再开启，避免下个用例沿用上次列表模型。
        tryCompare(dialog, "opened", false, 3000)
    }

    // 列表行由 ListView 生成，和 Repeater 委托一样从弹窗根 findChild 找不到；
    // 只能从 contentItem 的子项里按业务属性挑出想要的那一行。
    function routineRowWith(activeState) {
        var list = findChild(dialog, "routineListView")
        verify(list !== null)
        // 委托不是 open() 一返回就有的。刚打开就直接取，机器被并行任务抢占时会取到空，
        // 于是「布局还没铺开」被误判成「行不存在」。等它出现，条件成立就立刻返回，不浪费时间。
        var found = null
        tryVerify(function() {
            var kids = list.contentItem.children
            for (var i = 0; i < kids.length; ++i) {
                if (kids[i].routineActive === activeState) {
                    found = kids[i]
                    return true
                }
            }
            return false
        }, 3000, "等不到 active=" + activeState + " 的例行行")
        return found
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

    // 产品保证：编辑例行只交出改过的字段，没改就不写库。编辑开着时另一台改了另一项，
    // 这边保存不会用打开时的旧值把它盖掉。
    // 抓住的错误实现：标题、科目一起交回，或者没改也写一次。
    function test_editSendsOnlyChangedFields() {
        testCase.added = [{
            id: 51,
            title: "背单词",
            categoryId: -1,
            categoryName: "",
            categoryColor: "",
            active: true,
            displayOrder: 1
        }]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)
        var categoryCombo = findChild(dialog, "routineCategoryCombo")
        verify(categoryCombo !== null)

        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 51)
        categoryCombo.currentIndex = 1
        dialog.submit()
        compare(testCase.updateCalls, 1)
        compare(Object.keys(testCase.lastChanges).join(","), "categoryId", "只改了科目，标题没动不交")
        compare(testCase.lastChanges.categoryId, 7)
        tryCompare(dialog, "editingRoutineId", -1)

        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 51)
        dialog.submit()
        compare(testCase.updateCalls, 1, "什么都没改，不写库")
        tryCompare(dialog, "editingRoutineId", -1, 3000, "照常退出编辑")
        dialog.close()
    }

    // 产品保证：编辑例行时科目没读出来，不等于科目被删了：读失败的那一刻报出原因，下拉和选中的科目原样保留，
    // 保存时不会把例行的科目清掉。「先开始编辑、再读失败」和「先读失败、再开始编辑」两种顺序都一样。
    // （开始编辑、输入会照常清掉提示，和其它一次性提示一致；这里只管失败当时报出原因。）
    // 抓住的错误实现：读失败时拿空列表重建下拉，选中的科目被当成已删除退回「不设置科目」，保存时连科目一起交上去清空。
    function test_categoryReadFailureKeepsEditedCategory() {
        testCase.added = [{
            id: 61,
            title: "背单词",
            categoryId: 7,
            categoryName: "数学",
            categoryColor: "#d4a574",
            active: true,
            displayOrder: 1
        }]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        // 顺序一：先开始编辑，弹窗开着时重读（例行列表变了会重读科目），这次科目读失败。
        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 61)
        compare(dialog.selectedCategoryId(), 7, "前置：选中的是科目 7")
        fakeCategoryManager.failLoad = true
        fakeRoutineManager.routinesChanged()
        compare(dialog.errorText, "科目数据库故障", "读失败的那一刻报出原因")
        compare(dialog.selectedCategoryId(), 7, "选中的科目还在")
        findChild(dialog, "routineTitleField").text = "背单词 List 5"
        dialog.submit()
        compare(testCase.updateCalls, 1)
        compare(Object.keys(testCase.lastChanges).join(","), "title", "科目没交，不会被清掉")
        tryCompare(dialog, "editingRoutineId", -1, 3000)
        dialog.close()
        tryCompare(dialog, "opened", false, 3000)

        // 顺序二：打开时科目就读失败，之后才开始编辑。
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)
        compare(dialog.errorText, "科目数据库故障", "打开时读失败，报出原因")
        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", 61)
        compare(dialog.selectedCategoryId(), 7, "下拉还是上一次读到的，选中的科目还在")
        findChild(dialog, "routineTitleField").text = "背单词 List 6"
        dialog.submit()
        compare(testCase.updateCalls, 2)
        compare(Object.keys(testCase.lastChanges).join(","), "title", "科目没交，不会被清掉")
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

    function test_addAndEditNeverTouchWeekdays() {
        // 新增表单不再有星期控件：重复日交给服务层的默认值（每天），
        // 改标题/科目也不该顺手把它带过去覆盖掉。这两件事各由一个入口负责。
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var input = findChild(dialog, "routineTitleField")
        verify(input !== null)
        input.text = "背单词"
        dialog.submit()

        compare(testCase.addCalls, 1)
        compare(testCase.lastWeekdays, undefined)
        compare(testCase.added[0].weekdays, 0x7F)

        // 把它改成周一三五，再改标题，重复日必须原样还在。
        verify(fakeRoutineManager.setRoutineWeekdays(testCase.added[0].id, 0x15))
        dialog.beginEditing(dialog.routines[0])
        tryCompare(dialog, "editingRoutineId", testCase.added[0].id)
        input.text = "背单词 2"
        dialog.submit()

        compare(testCase.updateCalls, 1)
        compare(testCase.updatedWeekdays, undefined)
        compare(testCase.added[0].weekdays, 0x15)
        dialog.close()
    }

    function test_weekdayStripLightsExactlyTheSelectedDays() {
        // 列表行里没有文字了，这七个点就是唯一能看出「哪几天」的东西：
        // 点亮的位置必须和掩码逐位一致，第 i 个点对应第 i 位（0 = 周一）。
        // 整排画反或错位一天，界面照样好看，用户却会按错误的节奏安排一整周。
        var masks = [0x7F, 0x1F, 0x60, 0x01, 0x15, 0x2B, 0x3B, 0x5F]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        for (var i = 0; i < masks.length; ++i) {
            var mask = masks[i]
            testCase.added = [{
                id: 1, title: "例行", categoryId: -1, categoryName: "", categoryColor: "",
                active: true, displayOrder: 1, weekdays: mask
            }]
            fakeRoutineManager.routinesChanged()

            // 等到这一行的点阵换成当前掩码再断言，避免读到上一轮还没被替换掉的委托。
            var strip = null
            tryVerify(function() {
                var row = testCase.routineRowWith(true)
                if (row === null) {
                    return false
                }
                var candidate = findChild(row, "routineWeekdayStrip")
                if (candidate === null || candidate.weekdaysMask !== mask) {
                    return false
                }
                strip = candidate
                return true
            }, 3000, "等不到掩码 " + mask + " 的点阵")

            for (var day = 0; day < 7; ++day) {
                var mark = findChild(strip.contentItem, "routineWeekdayMark" + day)
                verify(mark !== null, "缺第 " + day + " 个点")
                compare(mark.lit, (mask & (1 << day)) !== 0,
                        "掩码 " + mask + " 的第 " + day + " 个点亮灭不对")
            }
        }
        dialog.close()
    }

    function test_weekdayStripKeepsTextInAccessibleNameAndTooltip() {
        // 点阵没有文字，读屏和悬停提示就是唯一的文字出口，不能只剩一个没名字的按钮。
        testCase.added = [{
            id: 1, title: "计算机网络", categoryId: -1, categoryName: "", categoryColor: "",
            active: true, displayOrder: 1, weekdays: 0x15
        }]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var strip = findChild(testCase.routineRowWith(true), "routineWeekdayStrip")
        verify(strip !== null)
        // 悬停提示在源码里就绑到 Accessible.name，断言这一处即可覆盖两者的文案；
        // ToolTip 是附加属性，从对象外部读到的是 undefined，测不了。
        compare(strip.Accessible.name, "重复：周一三五，点击修改")
        dialog.close()
    }

    function test_weekdayPillOpensDialogForThatRoutine() {
        testCase.added = [
            { id: 42, title: "计算机网络", categoryId: -1, categoryName: "", categoryColor: "",
              active: true, displayOrder: 1, weekdays: 0x15 }
        ]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        var strip = findChild(testCase.routineRowWith(true), "routineWeekdayStrip")
        verify(strip !== null)
        compare(dialog.weekdayDialogRef.opened, false)

        mouseClick(strip)
        tryCompare(dialog.weekdayDialogRef, "opened", true, 3000)
        // 打开的必须是这一行对应的那条例行，并带着它当前的重复日。
        compare(dialog.weekdayDialogRef.routineId, 42)
        compare(dialog.weekdayDialogRef.routineTitle, "计算机网络")
        compare(dialog.weekdayDialogRef.selectedWeekdays, 0x15)

        dialog.weekdayDialogRef.close()
        dialog.close()
    }

    function test_disabledRoutineRowRecedesInBothThemes() {
        testCase.added = [
            { id: 1, title: "启用的", categoryId: -1, categoryName: "", categoryColor: "",
              active: true, displayOrder: 1, weekdays: 0x7F },
            { id: 2, title: "停用的", categoryId: -1, categoryName: "", categoryColor: "",
              active: false, displayOrder: 2, weekdays: 0x7F }
        ]
        dialog.open()
        tryCompare(dialog, "opened", true, 3000)

        // 「停用」靠整行沉下去来表达，而这件事必须在明暗两套主题下同时成立。
        // surfaceRaised 在浅色下比 surface 深、在夜间主题下却比它亮：拿它做停用底色，
        // 白天没问题，夜里停用行反而是整列最亮最扎眼的一条，而且不会有任何测试变红。
        var themes = ["warm", "starry"]
        for (var i = 0; i < themes.length; ++i) {
            Theme.activeThemeId = themes[i]
            var activeRow = testCase.routineRowWith(true)
            var inactiveRow = testCase.routineRowWith(false)
            verify(activeRow !== null)
            verify(inactiveRow !== null)
            verify(Theme.relativeLuminance(inactiveRow.color)
                   < Theme.relativeLuminance(activeRow.color),
                   themes[i] + " 主题下停用行底色必须比正常行更暗")
        }

        Theme.activeThemeId = "warm"
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
