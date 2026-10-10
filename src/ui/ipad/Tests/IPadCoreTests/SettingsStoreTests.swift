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
}
