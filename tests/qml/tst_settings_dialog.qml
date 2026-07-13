import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "SettingsDialog"
    when: windowShown
    width: 700
    // 新增第四行偏好后给足高度，避免单测点击被滚动裁剪干扰。
    // （520px 下的滚动到关闭属人工冒烟验收，不在此单测覆盖）。
    height: 880

    QtObject {
        id: appSettingsMock

        property string backgroundTheme: "warm"
        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
        property int dayStartHour: 4
    }

    Component {
        id: signalSpyComponent

        SignalSpy {}
    }

    SettingsDialog {
        id: dialog

        appSettingsRef: appSettingsMock
    }

    function init() {
        appSettingsMock.backgroundTheme = "warm"
        appSettingsMock.soundEnabled = true
        appSettingsMock.reduceMotion = false
        appSettingsMock.slimClockFont = true
        appSettingsMock.dayStartHour = 4
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

    function test_eachThumbnailUsesCandidateThemeGlassAndDecodeSize() {
        var warmCell = themeCell("warm")
        var starryCell = themeCell("starry")
        verify(warmCell)
        verify(starryCell)

        var warmGlass = findChild(warmCell, "settingsThemeGlass-warm")
        var starryGlass = findChild(starryCell, "settingsThemeGlass-starry")
        verify(warmGlass)
        verify(starryGlass)
        verify(Qt.colorEqual(warmGlass.color, Theme.glassCardForMode("light")))
        verify(Qt.colorEqual(starryGlass.color, Theme.glassCardForMode("dark")))
        verify(!Qt.colorEqual(warmGlass.color, starryGlass.color))

        var warmThumb = themeThumb("warm")
        var wallpaper = findChild(warmThumb, "wallpaperImage")
        verify(wallpaper)
        compare(wallpaper.sourceSize.width, 154)
        compare(wallpaper.sourceSize.height, 66)
    }

    function test_clickThumbWritesThemeId() {
        dialog.open()
        wait(20)
        var thumb = themeThumb("jiangnan")
        verify(thumb)
        mouseClick(thumb)
        compare(appSettingsMock.backgroundTheme, "jiangnan")
    }

    function test_selectedFollowsSettings() {
        dialog.open()
        wait(20)
        var warmCell = themeCell("warm")
        var jiangnanCell = themeCell("jiangnan")
        verify(warmCell)
        verify(jiangnanCell)
        verify(warmCell.selected)
        verify(!jiangnanCell.selected)

        appSettingsMock.backgroundTheme = "jiangnan"
        verify(jiangnanCell.selected)
        verify(!warmCell.selected)
    }

    function test_missingSettingsRefRendersAndClickIsNoop() {
        dialog.appSettingsRef = null
        dialog.open()
        wait(20)
        compare(findChild(dialog, "settingsThemeRepeater").count, 6)
        var thumb = themeThumb("starry")
        verify(thumb)
        mouseClick(thumb) // 缺 appSettings（测试/降级）时：不崩溃、不写入。
        compare(appSettingsMock.backgroundTheme, "warm")
    }

    function test_soundSwitchBindsSetting() {
        appSettingsMock.soundEnabled = true
        dialog.open()
        wait(20)

        var sw = findChild(dialog, "settingsSoundSwitch")
        verify(sw)
        compare(sw.checked, true)

        sw.toggle()
        sw.toggled()
        compare(appSettingsMock.soundEnabled, false)
    }

    function test_reduceMotionSwitchBindsSetting() {
        appSettingsMock.reduceMotion = false
        dialog.open()
        wait(20)

        var sw = findChild(dialog, "settingsReduceMotionSwitch")
        verify(sw)
        compare(sw.checked, false)

        sw.toggle()
        sw.toggled()
        compare(appSettingsMock.reduceMotion, true)
    }

    function test_clickingPreferenceRowsTogglesSettings() {
        dialog.open()
        wait(20)

        var soundRow = findChild(dialog, "settingsSoundSwitchRow")
        var motionRow = findChild(dialog, "settingsReduceMotionSwitchRow")
        verify(soundRow)
        verify(motionRow)

        mouseClick(soundRow, 8, soundRow.height / 2, Qt.LeftButton, Qt.NoModifier)
        compare(appSettingsMock.soundEnabled, false)

        mouseClick(motionRow, 8, motionRow.height / 2, Qt.LeftButton, Qt.NoModifier)
        compare(appSettingsMock.reduceMotion, true)
    }

    function test_clickingPreferenceSwitchTogglesOnce() {
        dialog.open()
        wait(20)

        var soundSwitch = findChild(dialog, "settingsSoundSwitch")
        verify(soundSwitch)

        mouseClick(soundSwitch)
        compare(appSettingsMock.soundEnabled, false)
    }

    function test_slimClockFontSwitchBindsSetting() {
        appSettingsMock.slimClockFont = true
        dialog.open()
        wait(20)

        var sw = findChild(dialog, "settingsSlimClockFontSwitch")
        verify(sw)
        compare(sw.checked, true)

        sw.toggle()
        sw.toggled()
        compare(appSettingsMock.slimClockFont, false)
    }

    function test_slimClockFontRowTogglesOnce() {
        appSettingsMock.slimClockFont = true
        dialog.open()
        wait(20)

        var row = findChild(dialog, "settingsSlimClockFontSwitchRow")
        verify(row)
        mouseClick(row, 8, row.height / 2, Qt.LeftButton, Qt.NoModifier)
        compare(appSettingsMock.slimClockFont, false)
    }

    function test_slimClockFontSwitchTogglesOnce() {
        appSettingsMock.slimClockFont = true
        dialog.open()
        wait(20)

        var sw = findChild(dialog, "settingsSlimClockFontSwitch")
        verify(sw)
        mouseClick(sw)
        compare(appSettingsMock.slimClockFont, false)
    }

    function test_slimClockFontMissingSettingsRefIsNoop() {
        appSettingsMock.slimClockFont = true
        dialog.appSettingsRef = null
        dialog.open()
        wait(20)

        var row = findChild(dialog, "settingsSlimClockFontSwitchRow")
        verify(row)
        mouseClick(row, 8, row.height / 2, Qt.LeftButton, Qt.NoModifier)
        compare(appSettingsMock.slimClockFont, true)
    }

    function test_preferenceSwitchesAlignToGroupRightEdge() {
        dialog.open()

        var prefGroup = findChild(dialog, "settingsPreferenceGroup")
        var switchTrack = findChild(dialog, "settingsSoundSwitchTrack")
        verify(prefGroup)
        verify(switchTrack)
        tryVerify(function() {
            return prefGroup.width > 0 && switchTrack.width > 0
                    && switchTrack.mapToItem(prefGroup, 0, 0).x > 0
        }, 1000)

        var trackPos = switchTrack.mapToItem(prefGroup, 0, 0)
        verify(trackPos.x + switchTrack.width >= prefGroup.width - Theme.space24,
               "偏好开关应贴近组卡右侧，不能挤在文字旁边")
    }

    function test_manageRowsEmitSignals() {
        dialog.open()
        wait(20)

        var routineSpy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dialog,
            signalName: "routineRequested"
        })
        verify(routineSpy)

        var row = findChild(dialog, "settingsManageRoutine")
        verify(row)
        mouseClick(row)
        compare(routineSpy.count, 1)
    }

    function test_closeButtonHasObjectName() {
        dialog.open()
        wait(20)
        verify(findChild(dialog, "settingsCloseButton"))
    }

    function test_preferencesAndManageAreGroupedCards() {
        dialog.open()
        wait(20)
        var prefGroup = findChild(dialog, "settingsPreferenceGroup")
        var manageGroup = findChild(dialog, "settingsManageGroup")
        verify(prefGroup, "偏好应收进组卡")
        verify(manageGroup, "管理应收进组卡")
        // 组卡是不透明浅色（内容不再直接坐在半透玻璃上）。
        verify(Qt.colorEqual(prefGroup.color, Theme.surfaceRaised))
        verify(Qt.colorEqual(manageGroup.color, Theme.surfaceRaised))
    }

    function test_panelIsNearlyOpaqueAndPreferenceRowsAreConnected() {
        dialog.open()
        wait(20)

        var panel = findChild(dialog, "settingsDialogPanel")
        verify(panel)
        verify(panel.color.a >= 0.98, "设置弹窗底色应接近不透明，不能透出背景文字")

        var soundCaption = findChild(dialog, "settingsSoundSwitchCaption")
        var motionCaption = findChild(dialog, "settingsReduceMotionSwitchCaption")
        verify(soundCaption)
        verify(motionCaption)
        compare(soundCaption.text, "阶段完成时播放")
        compare(motionCaption.text, "关闭循环与切换动画")

        verify(findChild(dialog, "settingsPreferenceDivider"))
        verify(findChild(dialog, "settingsManageDividerRoutineCategory"))
        verify(findChild(dialog, "settingsManageDividerCategoryExport"))

        var routineRow = findChild(dialog, "settingsManageRoutine")
        verify(routineRow)
        compare(routineRow.implicitHeight, 40)
    }

    function test_dialogUsesWideReferenceLayout() {
        dialog.open()
        wait(20)

        verify(dialog.width >= 540, "设置弹窗不能继续使用窄 420 版式")

        var warmThumb = themeThumb("warm")
        verify(warmThumb)
        verify(warmThumb.width >= 148, "主题缩略图应放大到参考图的宽卡片尺度")
        verify(warmThumb.height >= 70, "主题缩略图高度应随宽卡片放大")

        var prefGroup = findChild(dialog, "settingsPreferenceGroup")
        verify(prefGroup)
        verify(prefGroup.x >= Theme.space24, "组卡左边距应扩大到 24")
        verify(prefGroup.width <= dialog.width - Theme.space24 * 2 + 1,
               "组卡宽度应给左右 24 留白")

        var closeButton = findChild(dialog, "settingsCloseButton")
        verify(closeButton)
        compare(closeButton.implicitWidth, 96)
        compare(closeButton.implicitHeight, 40)
    }

    function test_dayStartStepperBindsAndWrites() {
        dialog.open()
        wait(20)

        verify(findChild(dialog, "settingsDayStartRow"))
        var valueText = findChild(dialog, "settingsDayStartValue")
        verify(valueText)
        compare(valueText.text, "4")

        mouseClick(findChild(dialog, "settingsDayStartPlus"))
        compare(appSettingsMock.dayStartHour, 5)
        compare(valueText.text, "5")

        mouseClick(findChild(dialog, "settingsDayStartMinus"))
        compare(appSettingsMock.dayStartHour, 4)
    }

    function test_dayStartStepperMissingSettingsRefIsNoop() {
        dialog.appSettingsRef = null
        dialog.open()
        wait(20)

        mouseClick(findChild(dialog, "settingsDayStartPlus"))
        compare(appSettingsMock.dayStartHour, 4)
    }
}
