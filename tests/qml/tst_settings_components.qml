import QtQuick
import QtTest
import "../../qml/components/settings"

TestCase {
    id: testCase
    name: "SettingsComponents"
    when: windowShown

    SettingsNavigation {
        id: navigation
    }

    SettingsAppearancePage {
        id: appearancePage
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
}
