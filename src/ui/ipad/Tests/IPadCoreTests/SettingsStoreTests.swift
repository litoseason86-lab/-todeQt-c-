import IPadCore
import XCTest

@MainActor final class SettingsStoreTests: XCTestCase {
    // 产品保证：系统外观和主题永远只有一个选中项，系统外观不显示壁纸且禁用壁纸写入。
    func testR1AppearanceMutualExclusionAndWallpaperAvailability() {
        let bridge = ShellBridgeFake(); bridge.snapshot.useWallpaper = true
        let store = ShellStore(bridge: bridge)
        XCTAssertEqual(store.selectedSystemAppearance, "system"); XCTAssertNil(store.selectedTheme)
        XCTAssertFalse(store.wallpaperAvailable); XCTAssertFalse(store.wallpaperVisible)
        store.selectTheme("starry")
        XCTAssertNil(store.selectedSystemAppearance); XCTAssertEqual(store.selectedTheme, "starry")
        XCTAssertTrue(store.wallpaperAvailable); XCTAssertTrue(store.wallpaperVisible)
        store.setAppearance("light")
        XCTAssertEqual(store.selectedSystemAppearance, "light"); XCTAssertNil(store.selectedTheme)
        XCTAssertFalse(store.wallpaperAvailable); XCTAssertFalse(store.wallpaperVisible)
        store.setUseWallpaper(false)
        XCTAssertTrue(bridge.snapshot.useWallpaper)
        store.setAppearance("dark")
        XCTAssertEqual(store.selectedSystemAppearance, "dark"); XCTAssertNil(store.selectedTheme)
        store.setAppearance("system")
        XCTAssertEqual(store.selectedSystemAppearance, "system")
    }
    // 产品保证：外观和主题写失败保留整份旧选择并显示原文，恢复遮罩期间没有写动作。
    func testR1AppearanceFailureAndRestoreBlockKeepOldSelection() {
        let bridge = ShellBridgeFake(); bridge.snapshot.appearance = "theme"; bridge.snapshot.backgroundTheme = "pink"
        let store = ShellStore(bridge: bridge); let previous = store.snapshot
        bridge.appearanceError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "外观偏好保存失败"])
        store.setAppearance("dark")
        XCTAssertEqual(store.snapshot, previous); XCTAssertEqual(store.errorMessage, "外观偏好保存失败")
        store.selectTheme("moon")
        XCTAssertEqual(store.snapshot, previous); XCTAssertEqual(store.errorMessage, "外观偏好保存失败")
        bridge.appearanceError = nil; bridge.snapshot.operationBlocksUI = true; bridge.onChanged?()
        store.setAppearance("system"); store.selectTheme("warm")
        XCTAssertEqual(bridge.snapshot.appearance, "theme"); XCTAssertEqual(bridge.snapshot.backgroundTheme, "pink")
    }
    // 产品保证：迁移由桥接给出，主题模式不依赖壁纸开关才能选中或使用主题配色。
    func testR1AppearanceConsumesMigrationAndKeepsThemeWithoutWallpaper() {
        let bridge = ShellBridgeFake(); bridge.snapshot.appearance = "theme"; bridge.snapshot.backgroundTheme = "rainy"
        bridge.snapshot.useWallpaper = false
        let store = ShellStore(bridge: bridge)
        XCTAssertEqual(store.selectedTheme, "rainy"); XCTAssertNil(store.selectedSystemAppearance)
        XCTAssertTrue(store.wallpaperAvailable); XCTAssertFalse(store.wallpaperVisible)
        bridge.snapshot.appearance = "system"; bridge.onChanged?()
        XCTAssertNil(store.selectedTheme); XCTAssertEqual(store.selectedSystemAppearance, "system")
    }
    // 产品保证：长休息行显示当前启用状态和服务设置，不启用时不冒充仍会自动长休息。
    func testR1LongBreakSummaryReflectsEnabledSettings() {
        let bridge = SettingsBridgeFake(); bridge.result.longBreakEnabled = false
        bridge.result.longBreakInterval = 4; bridge.result.longBreakMinutes = 15
        let store = SettingsStore(bridge: bridge)
        XCTAssertEqual(store.longBreakSummary, "关闭")
        store.setLongBreakEnabled(true)
        XCTAssertEqual(store.longBreakSummary, "每 4 个番茄 · 15 分钟")
        store.setLongBreakInterval(6); store.setLongBreakMinutes(20)
        XCTAssertEqual(store.longBreakSummary, "每 6 个番茄 · 20 分钟")
    }
    // 产品保证：同步页始终显示服务给的待同步数，文件夹存在时操作明确为重新选择。
    func testR1SyncFormProjectsPendingZeroAndFolderAction() {
        let bridge = SettingsSyncFake(); let store = SettingsSyncStore(bridge: bridge)
        XCTAssertEqual(store.pendingText, "0 项"); XCTAssertEqual(store.folderActionTitle, "选择同步文件夹")
        bridge.result.pendingCount = 8; bridge.result.hasFolder = true; bridge.onChanged?()
        XCTAssertEqual(store.pendingText, "8 项"); XCTAssertEqual(store.folderActionTitle, "重新选择文件夹")
    }
    // 产品保证：设置分组覆盖设计稿要求的通用专注、提示、日期、个人字段，并保持同步日志与外观入口。
    func testR1SettingsSectionsExposeFormFieldsAndSubpages() {
        let general = Set(SettingsAvailability.features(in: .general))
        XCTAssertTrue(general.isSuperset(of: [.workMinutes, .breakMinutes, .longBreak, .quickStart, .autoAdvance, .freeTimerWarning, .sound, .dayStart, .nickname]))
        XCTAssertEqual(SettingsAvailability.features(in: .sync), [.sync])
        XCTAssertTrue(SettingsAvailability.features(in: .appearance).contains(.backgroundTheme))
        XCTAssertFalse(SettingsAvailability.features(in: .appearance).contains(.dashboardTimer))
    }
    // 产品保证：设置写入失败时显示值恢复为写入前快照，并向页面提供错误。
    func testFailedWriteRollsBackDisplayedValue() {
        let bridge = SettingsBridgeFake(); bridge.result.workMinutes = 25
        let store = SettingsStore(bridge: bridge)
        bridge.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "写入失败"])
        store.setWorkMinutes(40)
        XCTAssertEqual(store.snapshot.workMinutes, 25)
        XCTAssertEqual(store.errorMessage, "写入失败")
    }

    // 产品保证：侧栏顺序写入不包含固定的废纸篓和设置入口。
    func testSidebarOrderExcludesFixedEntries() {
        let bridge = SettingsBridgeFake(); let store = SettingsStore(bridge: bridge)
        store.setSidebarOrder([.today, .trash, .focus, .settings])
        let write = bridge.calls.first { $0.0 == "setSidebarOrder" }
        XCTAssertEqual(write?.0, "setSidebarOrder")
        XCTAssertEqual(write?.1, .strings(["today", "focus"]))
    }
    // 产品保证：iPad 分组只包含有效项，Mac 专属项和系统辅助开关没有入口。
    func testPlatformGroupsExcludeUnavailableFeatures() {
        XCTAssertEqual(SettingsSection.allCases.count, 8)
        let shown = Set(SettingsSection.allCases.flatMap { SettingsAvailability.features(in: $0) })
        XCTAssertTrue(shown.contains(.workMinutes))
        XCTAssertTrue(shown.contains(.wallpaper))
        XCTAssertTrue(shown.isDisjoint(with: SettingsAvailability.hidden))
        XCTAssertEqual(SettingsAvailability.hidden, [.externalAI, .bringWindowFront, .globalHotkey,
            .customShortcuts, .closeToMenuBar, .reduceMotion, .reduceTransparency])
    }

    // 产品保证：其它页面或同步改了设置时，本页收到变化便刷新；失败信号保留原因。
    func testExternalChangesAndFailureSignalRefreshControls() {
        let bridge = SettingsBridgeFake(); bridge.result.backgroundTheme = "warm"
        let store = SettingsStore(bridge: bridge)
        bridge.result.backgroundTheme = "pink"; bridge.onBackgroundThemeChanged?()
        XCTAssertEqual(store.snapshot.backgroundTheme, "pink")
        bridge.onWriteFailed?("backgroundTheme", "偏好文件不可写")
        XCTAssertEqual(store.errorMessage, "偏好文件不可写")
        bridge.onWriteSucceeded?("backgroundTheme")
        XCTAssertEqual(store.errorMessage, "")
    }

    // 产品保证：外观的可选主题与现有七种主题一致，没有不存在的浅色主题。
    func testAppearanceOffersAllSupportedThemes() {
        XCTAssertEqual(SettingsAvailability.themes.map(\.id), ["warm", "pink", "jiangnan", "sword", "starry", "rainy", "moon"])
    }

    // 产品保证：宽窗口设置左侧选中分组后，右侧详情使用同一分组并显示对应标题。
    func testSelectingSettingsSectionUpdatesDetailTitle() {
        let store = SettingsStore(bridge: SettingsBridgeFake())
        XCTAssertEqual(store.selectedSection, .general)
        XCTAssertEqual(store.selectedSectionTitle, "通用")
        store.selectSection(.appearance)
        XCTAssertEqual(store.selectedSection, .appearance)
        XCTAssertEqual(store.selectedSectionTitle, "外观")
    }

    // 产品保证：壁纸写入口拒绝保存时，显示仍为旧偏好并提供错误，不假装开启成功。
    func testWallpaperFailureKeepsPreviousSnapshot() {
        let bridge = ShellBridgeFake(); bridge.snapshot.useWallpaper = false; bridge.snapshot.appearance = "theme"
        bridge.appearanceError = CocoaError(.fileWriteNoPermission)
        let store = ShellStore(bridge: bridge); store.refresh()
        XCTAssertFalse(store.snapshot.useWallpaper)
        store.setUseWallpaper(true)
        XCTAssertFalse(store.snapshot.useWallpaper)
        XCTAssertFalse(store.errorMessage.isEmpty)
    }
}
