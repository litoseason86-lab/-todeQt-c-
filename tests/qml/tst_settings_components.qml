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

    function test_publicInterfacesExist() {
        compare(navigation.currentIndex, 0)
        verify(appearancePage.compact !== undefined)
        verify(focusPage.appSettingsRef !== undefined)
        verify(generalPage.commitPendingEdits instanceof Function)
        verify(dataPage.appSettingsRef !== undefined)
        verify(aboutPage.compact !== undefined)
    }
}
