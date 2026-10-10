pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../qml"
import "../../qml/components/settings"

TestCase {
    id: testCase
    name: "IPadNativeUI"
    width: 720
    height: 900
    visible: true
    when: windowShown
    property int writes: 0
    property bool requestedValue: false
    QtObject {
        id: preferences
        property bool isIPad: true
        property string error: ""
        property bool succeeds: true
        function setNativeUI(value) {
            testCase.writes += 1
            testCase.requestedValue = value
            return succeeds
        }
    }
    SettingsAppearancePage {
        id: page
        width: testCase.width
        ipadUiPreferencesRef: preferences
    }
    function init() {
        Theme.reduceMotion = true
        writes = 0; requestedValue = false
        preferences.isIPad = true; preferences.error = ""; preferences.succeeds = true
        page.ipadUiPreferencesRef = preferences
        page.nativeUIRequested = false; page.nativeUIError = ""
    }
    function cleanupTestCase() { Theme.reduceMotion = false }
    // 产品保证：Mac 缺少设备对象、iPhone 非 iPad 时都不提供新版入口，iPad 才可操作。
    function test_entryIsOnlyAvailableOnIPad() {
        compare(page.nativeUIEntryAvailable, true)
        preferences.isIPad = false
        compare(page.nativeUIEntryAvailable, false)
        compare(findChild(page, "settingsNativeUIButton").enabled, false)
        page.ipadUiPreferencesRef = null
        compare(page.nativeUIEntryAvailable, false)
    }
    // 产品保证：点击入口向本机偏好桥接请求 true，只提示下次生效；失败保留可重试按钮。
    function test_buttonRequestsNativeUIAndShowsOnlySavedSuccess() {
        var button = findChild(page, "settingsNativeUIButton")
        verify(button); verify(waitForItemPolished(page))
        preferences.succeeds = false; preferences.error = "保存失败"
        mouseClick(button)
        compare(writes, 1); compare(requestedValue, true)
        compare(page.nativeUIRequested, false); compare(page.nativeUIError, "保存失败")
        preferences.succeeds = true
        mouseClick(button)
        compare(writes, 2); compare(page.nativeUIRequested, true)
        compare(page.nativeUIError, ""); compare(button.enabled, false)
    }
}
