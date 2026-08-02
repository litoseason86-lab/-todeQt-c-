import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"
import "../../qml/views"

TestCase {
    id: testCase
    name: "CountdownUi"
    when: windowShown
    width: 720
    height: 520

    property int addCount: 0
    property string addedName: ""
    property string addedDateText: ""
    property int bannerClickCount: 0
    property int bannerAddCount: 0
    property var fakeNow: new Date(2026, 6, 8, 3, 59)

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    ListModel {
        id: countdownModel
    }

    QtObject {
        id: fakeCountdownService

        property var model: countdownModel
        property var primaryGoal: null
        property bool deleteSucceeds: true
        property bool reorderSucceeds: true
        property bool reloadSucceeds: true
        property int reloadCalls: 0

        signal operationFailed(string message)
        signal goalsReloaded()

        function addGoal(name, targetDate) {
            testCase.addCount += 1
            testCase.addedName = name
            testCase.addedDateText = Qt.formatDate(targetDate, "yyyy-MM-dd")
            primaryGoal = {
                goalId: 1,
                name: name,
                targetDate: targetDate,
                displayOrder: 0,
                daysRemaining: 10
            }
            countdownModel.append(primaryGoal)
            return true
        }

        function updateGoal(id, name, targetDate) {
            primaryGoal = {
                goalId: id,
                name: name,
                targetDate: targetDate,
                displayOrder: 0,
                daysRemaining: 12
            }
            return true
        }

        function deleteGoal(id) {
            if (!deleteSucceeds)
                return false
            countdownModel.clear()
            primaryGoal = null
            return true
        }

        function reorder(fromIndex, toIndex) {
            if (!reorderSucceeds)
                return false
            countdownModel.move(fromIndex, toIndex, 1)
            primaryGoal = countdownModel.count > 0 ? countdownModel.get(0) : null
            return true
        }

        function reload() {
            reloadCalls += 1
            if (reloadSucceeds)
                goalsReloaded()
            return reloadSucceeds
        }
    }

    CountdownBanner {
        id: emptyBanner
        width: 520
        primaryGoal: null
        onAddRequested: testCase.bannerAddCount += 1
    }

    CountdownBanner {
        id: goalBanner
        y: 80
        width: 520
        primaryGoal: ({
                goalId: 2,
                name: "研究生初试",
                targetDate: new Date(2026, 11, 23),
                daysRemaining: 196
            })
        onClicked: testCase.bannerClickCount += 1
    }

    CountdownDialog {
        id: countdownDialog
        countdownServiceRef: fakeCountdownService
        logicalNowProvider: function() { return testCase.fakeNow }
    }

    CountdownView {
        id: countdownView
        y: 170
        width: 640
        height: 320
        visible: false
        countdownServiceRef: fakeCountdownService
    }

    function init() {
        testCase.addCount = 0
        testCase.addedName = ""
        testCase.addedDateText = ""
        testCase.bannerClickCount = 0
        testCase.bannerAddCount = 0
        testCase.fakeNow = new Date(2026, 6, 8, 3, 59)
        countdownModel.clear()
        fakeCountdownService.primaryGoal = null
        fakeCountdownService.deleteSucceeds = true
        fakeCountdownService.reorderSucceeds = true
        fakeCountdownService.reloadSucceeds = true
        fakeCountdownService.reloadCalls = 0
        countdownView.loadError = ""
        countdownDialog.close()
    }

    function cleanup() {
        countdownDialog.close()
        countdownView.visible = false
        wait(260)
    }

    function test_bannerRoutesEmptyAndExistingGoalClicks() {
        emptyBanner.activate()
        compare(testCase.bannerAddCount, 1)

        goalBanner.activate()
        compare(testCase.bannerClickCount, 1)
    }

    function test_dialogAddsGoalThroughInjectedService() {
        countdownDialog.openForAdd()
        wait(120)

        var nameField = findChild(countdownDialog, "countdownNameField")
        var dateField = findChild(countdownDialog, "countdownDateField")
        verify(nameField !== null)
        verify(dateField !== null)

        nameField.text = "研究生初试"
        dateField.text = "2026-12-23"
        countdownDialog.submit()

        compare(testCase.addCount, 1)
        compare(testCase.addedName, "研究生初试")
        compare(testCase.addedDateText, "2026-12-23")
        verify(fakeCountdownService.primaryGoal !== null)
    }

    function test_dialogDefaultDateUsesLogicalToday() {
        compare(countdownDialog.dateToInput(null), "2026-07-07")
        countdownDialog.openForAdd()
        var dateField = findChild(countdownDialog, "countdownDateField")
        verify(dateField)
        compare(dateField.text, "2026-08-06")

        countdownDialog.close()
        testCase.fakeNow = new Date(2026, 6, 8, 4, 0)
        countdownDialog.openForAdd()
        compare(dateField.text, "2026-08-07")
    }

    function test_countdownViewReflectsPrimaryGoal() {
        fakeCountdownService.addGoal("研究生初试", new Date(2026, 11, 23))
        countdownView.visible = true
        wait(80)

        verify(fakeCountdownService.primaryGoal !== null)
        compare(countdownModel.count, 1)
    }

    function test_countdownHeroDaysUsesDataFamily() {
        var daysText = findChild(countdownView, "countdownHeroDays")
        verify(daysText)
        compare(daysText.font.family, Theme.fontFamilyData)
    }

    function test_countdownHeroDaysUsesReadableInk() {
        // 倒计时天数大字用 accentInk（AA 达标），不得回退低对比的 accent。
        var daysText = findChild(countdownView, "countdownHeroDays")
        verify(daysText)
        verify(Qt.colorEqual(daysText.color, Theme.accentInk), "倒计时天数应为 accentInk")
    }

    function test_firstSecondaryGoalCanBecomePrimaryWithoutBlankRow() {
        countdownModel.append({
            goalId: 1, name: "主目标", targetDate: new Date(2026, 11, 23),
            displayOrder: 0, daysRemaining: 10
        })
        countdownModel.append({
            goalId: 2, name: "可晋升目标", targetDate: new Date(2027, 0, 1),
            displayOrder: 1, daysRemaining: 20
        })
        fakeCountdownService.primaryGoal = countdownModel.get(0)
        countdownView.visible = true
        wait(100)

        var list = findChild(countdownView, "countdownSecondaryList")
        var item = findChild(countdownView, "countdownSecondaryItem")
        verify(list)
        verify(item)
        compare(item.canMoveUp, true)
        compare(Math.round(item.mapToItem(list, 0, 0).y), 0)

        item.moveUpRequested()
        compare(countdownModel.get(0).name, "可晋升目标")
    }

    function test_operationFailureWithoutDataUsesErrorStateInsteadOfEmptyState() {
        fakeCountdownService.operationFailed("读取倒计时目标失败")

        tryCompare(countdownView, "showingErrorState", true)
        compare(countdownView.showingEmptyState, false)
        var errorText = findChild(countdownView, "countdownLoadErrorText")
        verify(errorText !== null)
        compare(errorText.text, "读取倒计时目标失败")
    }

    function test_operationFailureKeepsExistingGoalAndShowsBanner() {
        fakeCountdownService.addGoal("已有目标", new Date(2026, 11, 23))
        fakeCountdownService.operationFailed("读取失败，但旧数据可用")

        tryCompare(countdownView, "showingErrorState", true)
        compare(countdownModel.count, 1)
        compare(fakeCountdownService.primaryGoal.name, "已有目标")
        var bannerText = findChild(countdownView, "countdownErrorText")
        verify(bannerText !== null)
        compare(bannerText.text, "读取失败，但旧数据可用")
    }

    function test_retrySuccessClearsRecoverableError() {
        fakeCountdownService.operationFailed("临时读取失败")
        tryCompare(countdownView, "showingErrorState", true)

        compare(countdownView.retryLoad(), true)
        compare(fakeCountdownService.reloadCalls, 1)
        tryCompare(countdownView, "showingErrorState", false)
    }

    function test_falseDeleteAndReorderShowFallbackErrors() {
        countdownModel.append({
            goalId: 1, name: "主目标", targetDate: new Date(2026, 11, 23),
            displayOrder: 0, daysRemaining: 10
        })
        countdownModel.append({
            goalId: 2, name: "次要目标", targetDate: new Date(2027, 0, 1),
            displayOrder: 1, daysRemaining: 20
        })
        fakeCountdownService.primaryGoal = countdownModel.get(0)
        countdownView.visible = true

        var item = null
        tryVerify(function() {
            item = findChild(countdownView, "countdownSecondaryItem")
            return item !== null
        })

        fakeCountdownService.deleteSucceeds = false
        item.deleteRequested(2)
        tryCompare(countdownView, "showingErrorState", true)
        compare(countdownView.loadError, "删除目标失败，请重试")

        countdownView.loadError = ""
        fakeCountdownService.reorderSucceeds = false
        item.moveUpRequested()
        tryCompare(countdownView, "showingErrorState", true)
        compare(countdownView.loadError, "调整目标顺序失败，请重试")
    }
}
