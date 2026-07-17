import QtQuick
import QtTest
import "../../qml/components/settings"
import "../../qml"

TestCase {
    id: testCase
    name: "SettingsComponents"
    when: windowShown

    Component {
        id: signalSpyComponent

        SignalSpy {}
    }

    QtObject {
        id: appSettingsMock

        property string backgroundTheme: "warm"
        property bool reduceMotion: false
        property bool slimClockFont: true
        property bool soundEnabled: true
        property int workMinutes: 60
        property int breakMinutes: 10
        property string nickname: ""
        property int dayStartHour: 4
        property bool reduceTransparency: false
        property bool raiseOnPhaseComplete: true
        property bool autoStartBreak: false
        property bool autoStartNextPomodoro: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
    }

    SettingsNavigation {
        id: navigation
    }

    SettingsAppearancePage {
        id: appearancePage
        width: 520
        appSettingsRef: appSettingsMock
    }

    SettingsFocusPage {
        id: focusPage
        width: 520
        appSettingsRef: appSettingsMock
    }

    SettingsGeneralPage {
        id: generalPage
        width: 520
        appSettingsRef: appSettingsMock
    }

    SettingsDataPage {
        id: dataPage
        width: 520
        appSettingsRef: appSettingsMock
    }

    SettingsAboutPage {
        id: aboutPage
        width: 520
    }

    SettingsSwitch {
        id: settingsSwitch
    }

    function test_publicInterfacesExist() {
        compare(navigation.currentIndex, 0)
        verify(appearancePage.compact !== undefined)
        verify(focusPage.appSettingsRef !== undefined)
        verify(generalPage.commitPendingEdits instanceof Function)
        verify(dataPage.appSettingsRef !== undefined)
        verify(aboutPage.compact !== undefined)
    }

    function test_navigationAndControlMetrics() {
        compare(settingsSwitch.implicitHeight, 44)
        compare(settingsSwitch.animationDuration, 120)
        compare(navigation.animationDuration, 100)
        settingsSwitch.reduceMotion = true
        compare(settingsSwitch.animationDuration, 0)
        navigation.reduceMotion = true
        compare(navigation.animationDuration, 0)
        navigation.reduceMotion = false
    }

    function test_switchRollsBackWhenPersistedValueDoesNotChange() {
        settingsSwitch.persistedChecked = false
        settingsSwitch.click()
        tryCompare(settingsSwitch, "checked", false)
    }

    function test_currentNavigationAndThemeCannotToggleOff() {
        navigation.currentIndex = 0
        var appearanceButton = findChild(navigation, "settingsCategoryAppearance")
        verify(appearanceButton)
        appearanceButton.click()
        verify(appearanceButton.checked)

        appSettingsMock.backgroundTheme = "warm"
        var warmChoice = findChild(appearancePage, "settingsThemeChoice-warm")
        verify(warmChoice)
        warmChoice.click()
        verify(warmChoice.checked)
    }

    function test_appearancePageUsesBoundedThemeGallery() {
        var repeater = findChild(appearancePage, "settingsThemeRepeater")
        verify(repeater)
        compare(repeater.count, 7)

        var warmChoice = findChild(appearancePage, "settingsThemeChoice-warm")
        verify(warmChoice)
        var wallpaper = findChild(warmChoice, "wallpaperImage")
        verify(wallpaper)
        compare(wallpaper.sourceSize.width, 154)
        compare(wallpaper.sourceSize.height, 84)
    }

    function test_legacyThemeStillShowsWarmSelected() {
        appSettingsMock.backgroundTheme = "warmPaper"
        var warmChoice = findChild(appearancePage, "settingsThemeChoice-warm")
        verify(warmChoice)
        verify(warmChoice.checked)
        appSettingsMock.backgroundTheme = "warm"
    }

    function test_themeChoiceWritesThemeAndUsesCandidateGlass() {
        appSettingsMock.backgroundTheme = "warm"
        var starryChoice = findChild(appearancePage, "settingsThemeChoice-starry")
        verify(starryChoice)
        starryChoice.click()
        compare(appSettingsMock.backgroundTheme, "starry")
        verify(starryChoice.checked)

        var starryGlass = findChild(starryChoice, "settingsThemeGlass-starry")
        verify(starryGlass)
        verify(Qt.colorEqual(starryGlass.color, Theme.glassCardForMode("dark")))
        appSettingsMock.backgroundTheme = "warm"
    }

    function test_reduceMotionDisablesSwitchAnimation() {
        appSettingsMock.reduceMotion = true
        var motionSwitch = findChild(appearancePage, "settingsReduceMotionSwitch")
        verify(motionSwitch)
        compare(motionSwitch.animationDuration, 0)
        appSettingsMock.reduceMotion = false
    }

    function test_focusDurationsWriteSharedSettings() {
        appSettingsMock.workMinutes = 60
        appSettingsMock.breakMinutes = 10
        var workPlus = findChild(focusPage, "settingsWorkMinutesPlus")
        var breakMinus = findChild(focusPage, "settingsBreakMinutesMinus")
        verify(workPlus)
        verify(breakMinus)
        workPlus.click()
        breakMinus.click()
        compare(appSettingsMock.workMinutes, 61)
        compare(appSettingsMock.breakMinutes, 9)
    }

    function test_reduceTransparencyWritesSetting() {
        appSettingsMock.reduceTransparency = false
        var sw = findChild(appearancePage, "settingsReduceTransparencySwitch")
        verify(sw)
        sw.click()
        compare(appSettingsMock.reduceTransparency, true)
    }

    function test_raiseOnPhaseCompleteWritesSetting() {
        appSettingsMock.raiseOnPhaseComplete = true
        var sw = findChild(focusPage, "settingsRaiseOnPhaseSwitch")
        verify(sw)
        sw.click()
        compare(appSettingsMock.raiseOnPhaseComplete, false)
    }

    function test_autoStartSwitchesWriteSettings() {
        appSettingsMock.autoStartBreak = false
        appSettingsMock.autoStartNextPomodoro = false
        var breakSwitch = findChild(focusPage, "settingsAutoStartBreakSwitch")
        var nextSwitch = findChild(focusPage, "settingsAutoStartNextSwitch")
        verify(breakSwitch)
        verify(nextSwitch)
        breakSwitch.click()
        nextSwitch.click()
        compare(appSettingsMock.autoStartBreak, true)
        compare(appSettingsMock.autoStartNextPomodoro, true)
    }

    function test_longBreakControlsWriteSettings() {
        appSettingsMock.longBreakEnabled = true
        appSettingsMock.longBreakMinutes = 15
        appSettingsMock.longBreakInterval = 4
        var minutesPlus = findChild(focusPage, "settingsLongBreakMinutesPlus")
        var intervalMinus = findChild(focusPage, "settingsLongBreakIntervalMinus")
        verify(minutesPlus)
        verify(intervalMinus)
        minutesPlus.click()
        intervalMinus.click()
        compare(appSettingsMock.longBreakMinutes, 16)
        compare(appSettingsMock.longBreakInterval, 3)

        var longSwitch = findChild(focusPage, "settingsLongBreakSwitch")
        verify(longSwitch)
        longSwitch.click()
        compare(appSettingsMock.longBreakEnabled, false)
    }

    function test_generalPageCommitsNicknameDraft() {
        appSettingsMock.nickname = ""
        generalPage.appSettingsRef = null
        generalPage.appSettingsRef = appSettingsMock
        var field = findChild(generalPage, "settingsNicknameField")
        verify(field)
        field.text = "  小番茄  "
        generalPage.nicknameDraft = field.text
        verify(generalPage.commitPendingEdits())
        compare(appSettingsMock.nickname, "小番茄")
    }

    function test_generalDayStartUsesSharedSetting() {
        appSettingsMock.dayStartHour = 4
        var plus = findChild(generalPage, "settingsDayStartPlus")
        verify(plus)
        plus.click()
        compare(appSettingsMock.dayStartHour, 5)
    }

    function test_dataActionsEmitSignals() {
        var routineSpy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dataPage,
            signalName: "routineRequested"
        })
        verify(routineSpy)
        var routineButton = findChild(dataPage, "settingsManageRoutine")
        verify(routineButton)
        routineButton.click()
        compare(routineSpy.count, 1)
    }

    function test_aboutUsesApplicationVersion() {
        var versionText = findChild(aboutPage, "settingsAboutVersion")
        verify(versionText)
        compare(versionText.text, Qt.application.version)
    }
}
