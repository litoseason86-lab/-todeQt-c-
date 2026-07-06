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

    ListModel {
        id: countdownModel
    }

    QtObject {
        id: fakeCountdownService

        property var model: countdownModel
        property var primaryGoal: null

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
            countdownModel.clear()
            primaryGoal = null
            return true
        }

        function reorder(fromIndex, toIndex) {
            countdownModel.move(fromIndex, toIndex, 1)
            return true
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
        countdownModel.clear()
        fakeCountdownService.primaryGoal = null
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
}
