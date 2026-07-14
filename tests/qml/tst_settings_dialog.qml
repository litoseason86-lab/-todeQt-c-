import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase

    name: "SettingsDialog"
    when: windowShown
    width: 1000
    height: 760

    Component {
        id: signalSpyComponent

        SignalSpy {}
    }

    QtObject {
        id: appSettingsMock

        property string backgroundTheme: "warm"
        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
        property int dayStartHour: 4
        property string nickname: ""
        property int workMinutes: 25
        property int breakMinutes: 5
    }

    SettingsDialog {
        id: dialog

        appSettingsRef: appSettingsMock
    }

    function init() {
        dialog.close()
        dialog.currentSection = 0
        wait(20)
    }

    function test_shellUsesFiveCategoryNavigation() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        compare(dialog.width, 760)
        verify(dialog.height <= 640)

        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        compare(findChild(navigation, "settingsCategoryRepeater").count, 5)
        verify(findChild(dialog, "settingsStatusText"))
        verify(findChild(dialog, "settingsCloseButton"))
    }

    function test_categoryButtonIsKeyboardFocusable() {
        dialog.open()
        tryCompare(dialog, "opened", true)

        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        var focusButton = findChild(navigation, "settingsCategoryFocus")
        verify(focusButton)
        verify(focusButton.activeFocusOnTab)
        focusButton.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(dialog.currentSection, 1)
    }

    function test_dialogRespectsSmallWindowMargins() {
        testCase.width = 860
        testCase.height = 620
        dialog.open()
        tryCompare(dialog, "opened", true)

        verify(dialog.width <= testCase.width - 64)
        verify(dialog.height <= testCase.height - 64)

        testCase.width = 1000
        testCase.height = 760
    }

    function test_dataActionClosesDialogAndForwardsSignal() {
        var routineSpy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dialog,
            signalName: "routineRequested"
        })
        verify(routineSpy)

        dialog.open()
        tryCompare(dialog, "opened", true)
        dialog.requestSection(3)
        compare(dialog.currentSection, 3)

        var pageLoader = findChild(dialog, "settingsPageLoader")
        verify(pageLoader)
        tryCompare(pageLoader, "status", Loader.Ready)
        var routineButton = findChild(pageLoader.item, "settingsManageRoutine")
        verify(routineButton)
        routineButton.click()

        compare(routineSpy.count, 1)
        tryCompare(dialog, "opened", false)
    }
}
