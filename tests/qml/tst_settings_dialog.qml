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
        property bool reduceTransparency: false
        property bool sidebarVisible: true
        property bool raiseOnPhaseComplete: true
        property bool autoStartBreak: false
        property bool autoStartNextPomodoro: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property int dayStartHour: 4
        property string nickname: ""
        property int workMinutes: 25
        property int breakMinutes: 5
        signal settingsWriteSucceeded(string key)
        signal settingsWriteFailed(string key, string message)
    }

    SettingsDialog {
        id: dialog

        appSettingsRef: appSettingsMock
    }

    function init() {
        appSettingsMock.reduceMotion = false
        appSettingsMock.nickname = ""
        dialog.close()
        dialog.currentSection = 0
        dialog.statusIsError = false
        dialog.statusText = "设置将自动保存到本机"
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

    function test_sectionChangeCommitsNicknameDraft() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        dialog.requestSection(2)

        var pageLoader = findChild(dialog, "settingsPageLoader")
        verify(pageLoader)
        tryCompare(pageLoader, "status", Loader.Ready)
        var field = findChild(pageLoader.item, "settingsNicknameField")
        verify(field)
        field.text = "  小番茄  "
        pageLoader.item.nicknameDraft = field.text

        dialog.requestSection(0)
        compare(appSettingsMock.nickname, "小番茄")
        compare(dialog.currentSection, 0)
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

    function test_writeFailureStaysVisibleUntilSuccess() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        appSettingsMock.settingsWriteFailed("appearance/reduceMotion", "设置文件不可写")

        var status = findChild(dialog, "settingsStatusText")
        verify(status)
        compare(status.text, "无法保存设置，请检查系统权限后重试")
        verify(status.visible)
        verify(dialog.statusIsError)

        appSettingsMock.settingsWriteSucceeded("appearance/reduceMotion")
        compare(status.text, "所有设置已保存到本机")
        verify(!dialog.statusIsError)
    }

    function test_controlsMeetMinimumTarget() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        verify(findChild(dialog, "settingsCloseButton").implicitHeight >= 44)
        verify(findChild(navigation, "settingsCategoryAppearance").implicitHeight >= 44)
    }

    function test_reduceMotionStopsDialogAndNavigationAnimations() {
        appSettingsMock.reduceMotion = true
        dialog.open()
        tryCompare(dialog, "opened", true)
        compare(dialog.animationDuration, 0)
        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        compare(navigation.animationDuration, 0)
        appSettingsMock.reduceMotion = false
    }

    function test_keyboardFocusScrollsLongPageIntoViewAndSectionResets() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        dialog.requestSection(1)

        var pageLoader = findChild(dialog, "settingsPageLoader")
        var pageScroll = findChild(dialog, "settingsPageScroll")
        verify(pageLoader)
        verify(pageScroll)
        tryCompare(pageLoader, "status", Loader.Ready)

        var bottomSwitch = findChild(pageLoader.item, "settingsRaiseOnPhaseSwitch")
        verify(bottomSwitch)
        bottomSwitch.forceActiveFocus()
        tryVerify(function() { return pageScroll.contentItem.contentY > 0 })

        dialog.requestSection(0)
        tryCompare(pageScroll.contentItem, "contentY", 0)
    }
}
