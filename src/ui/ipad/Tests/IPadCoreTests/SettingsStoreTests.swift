import IPadCore
import XCTest

@MainActor final class SettingsStoreTests: XCTestCase {
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

    // 产品保证：壁纸写入口拒绝保存时，显示仍为旧偏好并提供错误，不假装开启成功。
    func testWallpaperFailureKeepsPreviousSnapshot() {
        let bridge = ShellBridgeFake(); bridge.snapshot.useWallpaper = false
        let store = ShellStore(bridge: bridge); store.refresh()
        XCTAssertFalse(store.snapshot.useWallpaper)
        store.setUseWallpaper(true)
        XCTAssertFalse(store.snapshot.useWallpaper)
        XCTAssertFalse(store.errorMessage.isEmpty)
    }
}
