import QtQuick
import QtTest
import "../../qml/components/settings"
import "../../qml"

TestCase {
    id: testCase
    name: "SettingsComponents"
    when: windowShown

    QtObject {
        id: appSettingsMock

        property string backgroundTheme: "warm"
        property bool reduceMotion: false
        property bool slimClockFont: true
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
    }

    SettingsGeneralPage {
        id: generalPage
    }

    SettingsDataPage {
        id: dataPage
    }

    SettingsAboutPage {
        id: aboutPage
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
        settingsSwitch.reduceMotion = true
        compare(settingsSwitch.animationDuration, 0)
    }

    function test_appearancePageUsesBoundedThemeGallery() {
        var repeater = findChild(appearancePage, "settingsThemeRepeater")
        verify(repeater)
        compare(repeater.count, 6)

        var warmChoice = findChild(appearancePage, "settingsThemeChoice-warm")
        verify(warmChoice)
        var wallpaper = findChild(warmChoice, "wallpaperImage")
        verify(wallpaper)
        compare(wallpaper.sourceSize.width, 154)
        compare(wallpaper.sourceSize.height, 66)
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
}
