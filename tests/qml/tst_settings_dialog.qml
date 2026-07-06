import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "SettingsDialog"
    when: windowShown
    width: 700
    height: 520

    QtObject {
        id: appSettingsMock

        property string backgroundTheme: "warmPaper"
    }

    SettingsDialog {
        id: dialog

        appSettingsRef: appSettingsMock
    }

    function init() {
        appSettingsMock.backgroundTheme = "warmPaper"
        dialog.appSettingsRef = appSettingsMock
        dialog.close()
        wait(20)
    }

    function themeCell(themeId) {
        var repeater = findChild(dialog, "settingsThemeRepeater")
        verify(repeater)
        for (var i = 0; i < repeater.count; ++i) {
            var cell = repeater.itemAt(i)
            if (cell && cell.modelData.id === themeId) {
                return cell
            }
        }
        return null
    }

    function themeThumb(themeId) {
        var cell = themeCell(themeId)
        verify(cell)
        return findChild(cell, "settingsThemeThumb-" + themeId)
    }

    function test_galleryShowsAllThemes() {
        dialog.open()
        wait(20)
        var repeater = findChild(dialog, "settingsThemeRepeater")
        verify(repeater)
        compare(repeater.count, 6)
    }

    function test_clickThumbWritesThemeId() {
        dialog.open()
        wait(20)
        var thumb = themeThumb("celadon")
        verify(thumb)
        mouseClick(thumb)
        compare(appSettingsMock.backgroundTheme, "celadon")
    }

    function test_selectedFollowsSettings() {
        dialog.open()
        wait(20)
        var warmCell = themeCell("warmPaper")
        var celadonCell = themeCell("celadon")
        verify(warmCell)
        verify(celadonCell)
        verify(warmCell.selected)
        verify(!celadonCell.selected)

        appSettingsMock.backgroundTheme = "celadon"
        verify(celadonCell.selected)
        verify(!warmCell.selected)
    }

    function test_missingSettingsRefRendersAndClickIsNoop() {
        dialog.appSettingsRef = null
        dialog.open()
        wait(20)
        compare(findChild(dialog, "settingsThemeRepeater").count, 6)
        var thumb = themeThumb("sunset")
        verify(thumb)
        mouseClick(thumb) // 缺 appSettings（测试/降级）时：不崩溃、不写入。
        compare(appSettingsMock.backgroundTheme, "warmPaper")
    }
}
