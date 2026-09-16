import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "AddTaskDialogLayout"
    when: windowShown
    width: 1024
    height: 768

    AddTaskDialog {
        id: dialog
    }

    Item {
        id: contentArea

        x: 208
        y: 0
        width: 816
        height: 768

        AddTaskDialog {
            id: embeddedDialog
        }
    }

    QtObject {
        id: fakeCategoryManager

        signal operationFailed(string message)
        signal categoriesChanged()
        property bool failLoad: false
        // 内联新建用。0 表示服务拒绝（重名等）。
        property int nextNewId: 7
        property int addCategoryCalls: 0
        property string addCategoryName: ""
        property string addCategoryColor: ""
        property var extraCategories: []
        // 基础科目。用例可以换掉它，模拟两次打开之间科目被删或被重排。
        property var baseCategories: [
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]

        function getAllCategories() {
            if (failLoad) {
                operationFailed("科目数据库故障")
                return []
            }
            return baseCategories.concat(extraCategories)
        }

        function addCategory(name, color) {
            addCategoryCalls += 1
            addCategoryName = String(name)
            addCategoryColor = String(color)
            if (nextNewId <= 0)
                return 0
            var next = extraCategories.slice()
            next.push({ id: nextNewId, name: String(name), color: String(color) })
            extraCategories = next
            return nextNewId
        }
    }

    property int lastCategoryId: -999

    AddTaskDialog {
        id: categoryDialog
        categoryManagerRef: fakeCategoryManager

        onTaskAdded: function(title, date, categoryId) {
            testCase.lastCategoryId = Number(categoryId)
        }
    }

    AddTaskDialog {
        id: failingDialog
        taskSubmitter: function(title, date, categoryId) { return false }
    }

    property int submittedMinutes: -1

    AddTaskDialog {
        id: estimateDialog
        taskSubmitter: function(title, date, categoryId, estimatedMinutes) {
            testCase.submittedMinutes = Number(estimatedMinutes)
            return true
        }
    }

    property date providedDate: new Date(2026, 6, 25, 12, 0, 0)

    AddTaskDialog {
        id: refreshedDateDialog
        selectedDateProvider: function() { return testCase.providedDate }
    }

    function test_continuousEntryRetainsOptionsAndFailureRetainsDraft() {
        categoryDialog.open()
        // 弹窗动画结束后才完成科目载入；等待可交互状态，避免测试抢跑。
        tryCompare(categoryDialog, "opened", true)
        findChild(categoryDialog, "categoryComboBox").currentIndex = 1
        findChild(categoryDialog, "titleField").text = "第一项"
        categoryDialog.submit(true)
        verify(categoryDialog.visible)
        compare(findChild(categoryDialog, "titleField").text, "")
        compare(findChild(categoryDialog, "categoryComboBox").currentIndex, 1)
        compare(testCase.lastCategoryId, 1)
        findChild(categoryDialog, "titleField").text = "第二项"
        categoryDialog.submit(true)
        compare(testCase.lastCategoryId, 1)
        categoryDialog.close()
        failingDialog.open()
        findChild(failingDialog, "titleField").text = "保留草稿"
        failingDialog.submit(true)
        compare(findChild(failingDialog, "titleField").text, "保留草稿")
        verify(failingDialog.visible)
        failingDialog.close()
    }

    function verifyInsidePanel(popup: Popup, item: Item) {
        // 把控件坐标换算到弹窗面板内部，用来确认控件没有伸出边界。
        var local = popup.background.mapFromItem(item, 0, 0)
        verify(item.width > 0, item + " has no width")
        verify(item.height > 0, item + " has no height")
        verify(local.x >= 0, item + " starts before dialog panel")
        verify(local.y >= 0, item + " starts above dialog panel")
        verify(local.x + item.width <= popup.background.width,
               item + " overflows dialog panel horizontally")
        verify(local.y + item.height <= popup.background.height,
               item + " overflows dialog panel vertically")
    }

    function verifyDialogLayout(popup: Popup) {
        popup.open()
        wait(100)

        var titleField = findChild(popup, "titleField")
        var categoryComboBox = findChild(popup, "categoryComboBox")
        var cancelButton = findChild(popup, "cancelButton")
        var submitButton = findChild(popup, "submitButton")

        verify(titleField !== null)
        verify(categoryComboBox !== null)
        verify(cancelButton !== null)
        verify(submitButton !== null)

        compare(popup.contentItem.width, popup.width)
        compare(popup.background.width, popup.width)
        verifyInsidePanel(popup, titleField)
        verifyInsidePanel(popup, categoryComboBox)
        verifyInsidePanel(popup, cancelButton)
        verifyInsidePanel(popup, submitButton)
        popup.close()
    }

    function test_controlsStayInsidePanel() {
        verifyDialogLayout(dialog)
    }

    function test_controlsStayInsidePanelWhenEmbeddedInContentArea() {
        verifyDialogLayout(embeddedDialog)
    }

    function test_categorySelectionCanRemainEmpty() {
        // -1 是“未选择科目”的约定值，服务层会把它写成空科目。
        testCase.lastCategoryId = -999
        categoryDialog.open()
        wait(100)

        var titleField = findChild(categoryDialog, "titleField")
        var categoryComboBox = findChild(categoryDialog, "categoryComboBox")
        verify(titleField !== null)
        verify(categoryComboBox !== null)
        compare(categoryComboBox.currentIndex, 0)
        compare(categoryComboBox.displayText, "不设置科目")

        titleField.text = "无科目任务"
        categoryDialog.submit()

        compare(testCase.lastCategoryId, -1)
        categoryDialog.close()
    }

    function test_panelIsGlassDialog() {
        dialog.open()
        wait(20)
        var panel = findChild(dialog, "dialogPanel")
        verify(panel)
        verify(Qt.colorEqual(panel.color, Theme.glassDialog))
        dialog.close()
    }

    function test_failedSubmitKeepsInputAndDialogOpen() {
        wait(260)
        failingDialog.open()
        tryCompare(failingDialog, "opened", true, 3000)
        var titleField = findChild(failingDialog, "titleField")
        var errorLabel = findChild(failingDialog, "addTaskErrorLabel")
        verify(titleField)
        verify(errorLabel)

        titleField.text = "不能丢失的输入"
        failingDialog.submit()

        compare(failingDialog.opened, true)
        compare(titleField.text, "不能丢失的输入")
        verify(errorLabel.text.length > 0)
        failingDialog.close()
    }

    function test_categoryFailureSurvivesOpenRefresh() {
        fakeCategoryManager.failLoad = true
        categoryDialog.open()
        tryCompare(categoryDialog, "opened", true, 3000)

        var errorLabel = findChild(categoryDialog, "addTaskErrorLabel")
        verify(errorLabel)
        compare(errorLabel.text, "科目数据库故障")

        categoryDialog.close()
        fakeCategoryManager.failLoad = false
    }

    function estimateFieldsOf(popup) {
        var hour = findChild(popup, "addEstimateHourField")
        var minute = findChild(popup, "addEstimateMinuteField")
        verify(hour)
        verify(minute)
        return { hour: hour, minute: minute }
    }

    function test_overlongNotesBlockSubmitAndKeepDraft() {
        // 服务端对超长备注拒绝（不再截断）。弹窗要当场拦下并指明是备注，
        // 否则用户只看到一句笼统的「保存失败」，不知道该删哪里。
        testCase.submittedMinutes = -1
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 3000)
        findChild(estimateDialog, "titleField").text = "整理讲义"
        var fields = estimateFieldsOf(estimateDialog)
        fields.hour.text = "0"
        fields.minute.text = "30"
        var notes = findChild(estimateDialog, "addNotesField")
        var longNotes = new Array(estimateDialog.maxNotesLength + 2).join("x")
        compare(longNotes.length, estimateDialog.maxNotesLength + 1)
        notes.text = longNotes

        estimateDialog.submit()

        compare(testCase.submittedMinutes, -1)
        compare(estimateDialog.opened, true)
        compare(notes.text, longNotes)
        var errorLabel = findChild(estimateDialog, "addTaskErrorLabel")
        verify(errorLabel.text.indexOf("备注") >= 0, errorLabel.text)

        // 删到上限以内就能保存。
        notes.text = longNotes.slice(0, estimateDialog.maxNotesLength)
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 30)
        tryCompare(estimateDialog, "opened", false, 3000)
    }

    function test_estimateIsSubmittedAsMinutes() {
        testCase.submittedMinutes = -1
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 3000)
        findChild(estimateDialog, "titleField").text = "高数复习"

        var fields = estimateFieldsOf(estimateDialog)
        // 小时和分钟必须合成一个分钟数交给服务层，而不是各传各的。
        fields.hour.text = "1"
        fields.minute.text = "45"
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 105)
        tryCompare(estimateDialog, "opened", false, 3000)
    }

    function test_estimateDefaultsToUnsetAndResetsBetweenOpens() {
        testCase.submittedMinutes = -1
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 3000)
        findChild(estimateDialog, "titleField").text = "留空预计"

        var fields = estimateFieldsOf(estimateDialog)
        // 不填等于「未设置」，要老老实实传 0，而不是替用户猜一个默认时长。
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "0")
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 0)

        // 上一次填过的值不能留到下一次打开——那会让用户在不知情下重复套用旧预估。
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 3000)
        findChild(estimateDialog, "titleField").text = "第二次"
        fields = estimateFieldsOf(estimateDialog)
        fields.hour.text = "2"
        fields.minute.text = "0"
        estimateDialog.submit()
        compare(testCase.submittedMinutes, 120)

        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 3000)
        fields = estimateFieldsOf(estimateDialog)
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "0")

        // 填了但没提交：estimatedMinutes 从没被改过，绑定不会发出变化信号，
        // 只有 resetFields 里那句显式重灌能把输入框清干净。关闭走的就是这条路。
        fields.hour.text = "3"
        fields.minute.text = "30"
        compare(estimateDialog.estimatedMinutes, 0)
        estimateDialog.resetFields()
        compare(fields.hour.text, "0")
        compare(fields.minute.text, "0")
        estimateDialog.close()
    }

    function test_incompleteEstimateBlocksSubmit() {
        testCase.submittedMinutes = -1
        estimateDialog.open()
        tryCompare(estimateDialog, "opened", true, 3000)
        findChild(estimateDialog, "titleField").text = "清空分钟"

        var fields = estimateFieldsOf(estimateDialog)
        fields.minute.text = ""
        estimateDialog.submit()
        // 清空后提交曾会静默存成 0；必须挡住并把弹窗留在原地让用户看见报错。
        compare(testCase.submittedMinutes, -1)
        compare(estimateDialog.opened, true)
        verify(findChild(estimateDialog, "addTaskErrorLabel").text.length > 0)
        estimateDialog.close()
    }

    function test_selectedDateRefreshesEveryTimeDialogOpens() {
        testCase.providedDate = new Date(2026, 6, 25, 12, 0, 0)
        refreshedDateDialog.open()
        tryCompare(refreshedDateDialog, "opened", true, 3000)
        compare(Qt.formatDate(refreshedDateDialog.selectedDate, "yyyy-MM-dd"), "2026-07-25")
        refreshedDateDialog.close()
        tryCompare(refreshedDateDialog, "opened", false, 3000)

        // 模拟弹窗长时间未用后跨过逻辑日边界；再打开不得沿用上次日期。
        testCase.providedDate = new Date(2026, 6, 26, 12, 0, 0)
        refreshedDateDialog.open()
        tryCompare(refreshedDateDialog, "opened", true, 3000)
        compare(Qt.formatDate(refreshedDateDialog.selectedDate, "yyyy-MM-dd"), "2026-07-26")
        refreshedDateDialog.close()
    }

    // —— 科目下拉的内联新建 ——
    //
    // 此前建任务建到一半想起要分个新科目，只能放下手里的事去开
    //「设置 → 数据 → 科目管理」。这一组盯住三件事：
    // 哨兵不会被当成科目提交、取消后下拉不会停在哨兵上、建完自动选中。

    // 复位写在 init 而不是用例末尾：一条用例中途失败就跳过还原的话，
    // 被改过的科目列表和没关的弹窗会把后面的用例一起带红。
    function init() {
        fakeCategoryManager.baseCategories = [
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]
        fakeCategoryManager.extraCategories = []
        fakeCategoryManager.failLoad = false
        if (categoryDialog.visible) {
            categoryDialog.close()
            tryCompare(categoryDialog, "visible", false, 2000)
        }
    }

    function resetCategoryFixture() {
        fakeCategoryManager.failLoad = false
        fakeCategoryManager.nextNewId = 7
        fakeCategoryManager.addCategoryCalls = 0
        fakeCategoryManager.addCategoryName = ""
        fakeCategoryManager.addCategoryColor = ""
        fakeCategoryManager.extraCategories = []
        fakeCategoryManager.baseCategories = [
            { id: 1, name: "数学", color: "#d4a574" },
            { id: 2, name: "英语", color: "#c9956e" }
        ]
        categoryDialog.close()
        categoryDialog.refreshCategories()
    }

    // onOpened / onClosed 要等进出场动画结束才触发，刷新科目、复位下拉都在里面。
    // 不等就操作，测到的是上一次打开留下的列表。
    function openDialog(dialog) {
        dialog.open()
        tryCompare(dialog, "opened", true, 2000)
    }

    function closeDialog(dialog) {
        dialog.close()
        tryCompare(dialog, "visible", false, 2000)
    }

    function selectedOptionId(dialog) {
        var combo = findChild(dialog, "categoryComboBox")
        verify(combo)
        verify(combo.currentIndex >= 0 && combo.currentIndex < dialog.categoryOptions.length,
               "下拉停在了越界位置：" + combo.currentIndex)
        return Number(dialog.categoryOptions[combo.currentIndex].id)
    }

    function indexOfOption(dialog, id) {
        for (var i = 0; i < dialog.categoryOptions.length; ++i) {
            if (Number(dialog.categoryOptions[i].id) === id)
                return i
        }
        return -1
    }

    function test_optionsEndWithNewCategorySentinel() {
        resetCategoryFixture()

        var options = categoryDialog.categoryOptions
        // 不设置科目 + 数学 + 英语 + 哨兵
        compare(options.length, 4)
        compare(Number(options[0].id), -1)
        compare(Number(options[options.length - 1].id), categoryDialog.newCategorySentinelId)
    }

    function test_choosingSentinelRevertsSelectionAndOpensPrompt() {
        resetCategoryFixture()
        var combo = findChild(categoryDialog, "categoryComboBox")
        verify(combo)
        var prompt = findChild(categoryDialog, "addTaskNewCategoryPrompt")
        verify(prompt)

        // 先停在「英语」上，再去点哨兵。
        combo.currentIndex = 2
        categoryDialog.handleCategoryActivated(2)
        compare(categoryDialog.lastRealCategoryId, 2)

        categoryDialog.handleCategoryActivated(3)

        // 下拉必须退回「英语」——停在「+ 新建科目…」上不是一个合法的科目归属。
        compare(combo.currentIndex, 2)
        compare(prompt.opened, true)
        prompt.close()
    }

    function test_createdCategoryIsSelectedAutomatically() {
        resetCategoryFixture()
        var combo = findChild(categoryDialog, "categoryComboBox")
        verify(combo)
        var prompt = findChild(categoryDialog, "addTaskNewCategoryPrompt")
        verify(prompt)

        prompt.openPrompt()
        var field = findChild(prompt, "newCategoryPromptField")
        verify(field)
        field.text = "专业课"
        prompt.submit()

        compare(fakeCategoryManager.addCategoryCalls, 1)
        compare(fakeCategoryManager.addCategoryName, "专业课")
        // 颜色自动取，不再问用户一次。
        verify(fakeCategoryManager.addCategoryColor.length > 0)
        // 建完直接选中它——用户此刻要的就是拿它去归类眼前这条任务。
        compare(Number(categoryDialog.categoryOptions[combo.currentIndex].id), 7)
    }

    function test_duplicateNameKeepsInputAndReportsError() {
        resetCategoryFixture()
        fakeCategoryManager.nextNewId = 0
        var prompt = findChild(categoryDialog, "addTaskNewCategoryPrompt")
        verify(prompt)

        prompt.openPrompt()
        var field = findChild(prompt, "newCategoryPromptField")
        verify(field)
        field.text = "数学"
        prompt.submit()

        // 失败时输入不能被清掉——让用户直接改，而不是重打一遍。
        compare(field.text, "数学")
        verify(prompt.errorText.length > 0)
        compare(prompt.opened, true)
        prompt.close()
    }

    function test_sentinelIsNeverSubmittedAsCategoryId() {
        resetCategoryFixture()
        // 提交必须来自打开的表单，关闭中的弹窗不再允许写入。
        categoryDialog.open()
        tryCompare(categoryDialog, "opened", true)
        var combo = findChild(categoryDialog, "categoryComboBox")
        verify(combo)
        var titleField = findChild(categoryDialog, "titleField")
        verify(titleField)

        // 绕过 handleCategoryActivated 的退回，直接把下拉按在哨兵上，
        // 模拟"某条路径漏了退回"。最后一道闸必须把 -2 收敛成 -1。
        combo.currentIndex = 3
        compare(Number(categoryDialog.categoryOptions[3].id), categoryDialog.newCategorySentinelId)

        testCase.lastCategoryId = -999
        titleField.text = "哨兵不能被当成科目"
        categoryDialog.submit()

        compare(testCase.lastCategoryId, -1)
    }

    // —— 审查修复：取消新建科目后的恢复（2026-09-14）——
    // 恢复按科目编号，不按下标：下标会随列表增删与重排变化，而弹窗关掉再开时
    // 上一次记下的位置也不再属于这一次。

    function test_cancelNewCategoryAfterReopenDoesNotRestoreLastSessionsCategory() {
        resetCategoryFixture()
        var combo = findChild(categoryDialog, "categoryComboBox")

        // 上一次打开：选了「英语」。
        openDialog(categoryDialog)
        combo.currentIndex = indexOfOption(categoryDialog, 2)
        categoryDialog.handleCategoryActivated(combo.currentIndex)
        closeDialog(categoryDialog)

        // 这一次打开：下拉复位在「不设置科目」，用户点哨兵又取消。
        openDialog(categoryDialog)
        compare(selectedOptionId(categoryDialog), -1)
        var prompt = findChild(categoryDialog, "addTaskNewCategoryPrompt")
        categoryDialog.handleCategoryActivated(indexOfOption(categoryDialog, categoryDialog.newCategorySentinelId))
        prompt.close()

        // 必须退回这一次的「不设置科目」，不能变成用户这次根本没选过的「英语」。
        compare(selectedOptionId(categoryDialog), -1)
        closeDialog(categoryDialog)
    }

    function test_cancelNewCategoryNeverLandsOnSentinelAfterCategoryRemoved() {
        resetCategoryFixture()
        var combo = findChild(categoryDialog, "categoryComboBox")

        openDialog(categoryDialog)
        combo.currentIndex = indexOfOption(categoryDialog, 2)
        categoryDialog.handleCategoryActivated(combo.currentIndex)
        closeDialog(categoryDialog)

        // 两次打开之间「英语」被删了：选项变成 [不设置科目, 数学, 哨兵]，
        // 旧的下标 2 正好指着哨兵本身。
        fakeCategoryManager.baseCategories = [ { id: 1, name: "数学", color: "#d4a574" } ]
        openDialog(categoryDialog)
        var prompt = findChild(categoryDialog, "addTaskNewCategoryPrompt")
        categoryDialog.handleCategoryActivated(indexOfOption(categoryDialog, categoryDialog.newCategorySentinelId))
        prompt.close()

        verify(selectedOptionId(categoryDialog) !== categoryDialog.newCategorySentinelId,
               "取消后下拉停在了「+ 新建科目…」上")
        closeDialog(categoryDialog)
    }

    function test_cancelRestoresSameCategoryWhenListIsReordered() {
        resetCategoryFixture()
        var combo = findChild(categoryDialog, "categoryComboBox")

        openDialog(categoryDialog)
        combo.currentIndex = indexOfOption(categoryDialog, 2)
        categoryDialog.handleCategoryActivated(combo.currentIndex)

        // 打开期间列表被重排（科目按 display_order、name 排序，别处改了顺序或插进一条）。
        // 「英语」挪到了别的下标上；取消新建后要回到「英语」本身，而不是回到原来那个位置上的别的科目。
        // 「英语」从下标 2 挪到下标 1，原来的下标 2 上换成了「政治」。
        fakeCategoryManager.baseCategories = [
            { id: 2, name: "英语", color: "#c9956e" },
            { id: 3, name: "政治", color: "#aaaaaa" },
            { id: 1, name: "数学", color: "#d4a574" }
        ]
        categoryDialog.refreshCategories()
        combo.currentIndex = indexOfOption(categoryDialog, 2)
        compare(combo.currentIndex, 1)

        var prompt = findChild(categoryDialog, "addTaskNewCategoryPrompt")
        categoryDialog.handleCategoryActivated(indexOfOption(categoryDialog, categoryDialog.newCategorySentinelId))
        prompt.close()

        compare(selectedOptionId(categoryDialog), 2)
        closeDialog(categoryDialog)
    }

    function test_openingSyncsTheRestorePointToTheInitialSelection() {
        resetCategoryFixture()
        var combo = findChild(categoryDialog, "categoryComboBox")
        openDialog(categoryDialog)
        combo.currentIndex = indexOfOption(categoryDialog, 1)
        categoryDialog.handleCategoryActivated(combo.currentIndex)
        closeDialog(categoryDialog)

        openDialog(categoryDialog)
        // 每次打开，恢复点都要跟这一次的初始选中同步。
        compare(categoryDialog.lastRealCategoryId, selectedOptionId(categoryDialog))
        closeDialog(categoryDialog)
    }
}
