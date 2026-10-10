import IPadCore
import XCTest

@MainActor final class TrashBridgeTests: XCTestCase {
    // 产品保证：清空确认时固定编号，确认期间新进废纸篓的记录不被误删。
    func testEmptyUsesIDsCapturedWhenConfirmationOpened() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(4), item(9)]
        let store = TrashStore(bridge: bridge); store.activate(); store.requestEmpty()
        bridge.result.items.append(item(12))
        store.reload()
        store.confirmEmpty()
        XCTAssertEqual(bridge.calls.last?.0, "empty")
        XCTAssertEqual(bridge.calls.last?.1, [4, 9])
    }

    // 产品保证：读取失败不会把上一份有效废纸篓数据替换成假空列表。
    func testReadFailurePreservesLastSuccessfulItems() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(7)]
        let store = TrashStore(bridge: bridge); store.activate()
        bridge.readError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])
        store.reload()
        XCTAssertEqual(store.items.map(\.id), [7])
        XCTAssertFalse(store.loadError.isEmpty)
    }

    // 产品保证：彻底删除失败显示服务原文；仅 gone（条目已不存在）时重读列表。
    func testDeleteFailureKeepsServiceReasonAndReloadsGone() {
        for code in ["blocked", "gone"] {
            let bridge = TrashBridgeFake(); bridge.result.items = [item(4)]
            let store = TrashStore(bridge: bridge); store.activate()
            XCTAssertEqual(store.items.map(\.id), [4])
            store.requestDelete(item(4)); XCTAssertEqual(store.pendingDelete?.id, 4)
            bridge.actionResult = TrashActionResult(error: "彻底删除失败：数据库只读", code: code)
            // 服务快照换成不同编号，重读与保留旧列表必须得到不同结果。
            bridge.result.items = [item(9)]
            store.confirmDelete()
            XCTAssertEqual(store.actionError, "彻底删除失败：数据库只读", code)
            XCTAssertEqual(store.items.map(\.id), code == "gone" ? [9] : [4], code)
            XCTAssertNil(store.pendingDelete)
            XCTAssertEqual(bridge.calls.last?.0, "delete"); XCTAssertEqual(bridge.calls.last?.1, [4])
        }
    }

    // 产品保证：清空失败显示服务原文；仅 gone 时重读列表，确认始终提交打开时的编号。
    func testEmptyFailureKeepsServiceReasonAndReloadsGone() {
        for code in ["blocked", "gone"] {
            let bridge = TrashBridgeFake(); bridge.result.items = [item(4), item(7)]
            let store = TrashStore(bridge: bridge); store.activate()
            XCTAssertEqual(store.items.map(\.id), [4, 7])
            store.requestEmpty(); XCTAssertEqual(store.pendingEmptyIDs, [4, 7])
            bridge.actionResult = TrashActionResult(error: "清空失败：有条目已被另一台设备删除", code: code)
            // 不触发变化回调，只有动作的 gone 分支可以更新这个快照。
            bridge.result.items = [item(9)]
            store.confirmEmpty()
            XCTAssertEqual(store.actionError, "清空失败：有条目已被另一台设备删除", code)
            XCTAssertEqual(store.items.map(\.id), code == "gone" ? [9] : [4, 7], code)
            XCTAssertNil(store.pendingEmptyIDs)
            XCTAssertEqual(bridge.calls.last?.0, "empty"); XCTAssertEqual(bridge.calls.last?.1, [4, 7])
        }
    }

    // 产品保证：空日期、今天、昨天與跨年日期按服务提供的逻辑日分组。
    func testGroupLabelsUseServiceLogicalDay() {
        XCTAssertEqual(TrashStore.groupLabel("2026-10-10", today: "2026-10-10"), "今天")
        XCTAssertEqual(TrashStore.groupLabel("2026-10-09", today: "2026-10-10"), "昨天")
        XCTAssertEqual(TrashStore.groupLabel("2025-12-30", today: "2026-01-01"), "2025年12月30日")
        XCTAssertEqual(TrashStore.groupLabel("", today: "2026-10-10"), "删除时间不详")
    }

    // 产品保证：恢复失败保留服务原因，并在时间冲突时带出原记录时间段。
    func testRestoreFailureKeepsServiceReasonAndConflictSpan() {
        var details = TrashDetails(); details.startTime = "2026-10-10T14:05:00"; details.endTime = "2026-10-10T14:50:00"
        let value = TrashItem(id: 1, kind: "focus_session", title: "复习", deletedAt: "", deletedDate: "2026-10-10",
                              remainingDays: 4, originSyncID: "", categoryName: "", categoryColor: "", restorable: true,
                              blockedReason: "", details: details)
        let result = TrashActionResult(error: "与已有专注记录冲突", conflict: "focus")
        XCTAssertEqual(TrashStore.restoreFailure(item: value, result: result, today: "2026-10-10"),
                       "没能恢复「复习」：10月10日 14:05–14:50 与已有专注记录冲突")
    }

    private func item(_ id: Int) -> TrashItem {
        TrashItem(id: id, kind: "memo", title: "条目", deletedAt: "", deletedDate: "2026-10-10", remainingDays: 3,
                  originSyncID: "", categoryName: "", categoryColor: "", restorable: true, blockedReason: "", details: TrashDetails())
    }

    // 产品保证：恢复先确认，取消不写服务；确认使用原编号并给出成功提示。
    func testRestoreConfirmationAndSuccessNotice() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(4)]
        let store = TrashStore(bridge: bridge); store.activate()
        store.requestRestore(item(4)); store.cancelRestore()
        XCTAssertFalse(bridge.calls.contains { $0.0 == "restore" })
        store.requestRestore(item(4)); store.confirmRestore()
        XCTAssertTrue(bridge.calls.contains { $0.0 == "restore" && $0.1 == [4] })
        XCTAssertEqual(store.restoredTitle, "条目")
        store.dismissNotice(); XCTAssertEqual(store.restoredTitle, "")
    }

    // 产品保证：逻辑日变化后重读服务的今日和剩余天数；离开页面不做无用读取。
    func testLogicalDayRefreshesActiveTrashOnly() {
        let bridge = TrashBridgeFake(); let day = LogicalDayBridgeFake()
        let store = TrashStore(bridge: bridge, logicalDay: day); store.activate()
        bridge.result.today = "2026-10-11"
        day.onChanged?(); XCTAssertEqual(store.today, "2026-10-11")
        store.deactivate(); bridge.result.today = "2026-10-12"
        day.onChanged?(); XCTAssertEqual(store.today, "2026-10-11")
    }
}
