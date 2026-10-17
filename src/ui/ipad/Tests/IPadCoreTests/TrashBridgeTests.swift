import IPadCore
import Observation
import XCTest

@MainActor final class TrashBridgeTests: XCTestCase {
    // 产品保证：进入废纸篓清理失败保留桥接具体原因，同时仍读取列表供用户处理。
    func testPurgeFailureKeepsSpecificReasonAndReadsItems() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(7)]
        bridge.purgeError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "清理过期废纸篓失败：T33 database is locked"])
        let store = TrashStore(bridge: bridge); store.activate()
        XCTAssertEqual(store.actionError, "清理过期废纸篓失败：T33 database is locked")
        XCTAssertTrue(store.loaded); XCTAssertEqual(store.items.map(\.id), [7])
        XCTAssertEqual(bridge.calls.map { $0.0 }, ["purge"])
        XCTAssertEqual(bridge.readCount, 1)
    }

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

    // 产品保证：切换废纸篓操作时只保留最后一次确认意图，取消不会恢复旧意图。
    func testSwitchingConfirmationKeepsOnlyLatestIntent() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(4), item(9)]
        let store = TrashStore(bridge: bridge); store.activate()
        store.requestEmpty(); XCTAssertEqual(store.pendingEmptyIDs, [4, 9])
        store.requestRestore(item(4))
        XCTAssertNil(store.pendingEmptyIDs); XCTAssertEqual(store.pendingRestore?.id, 4)
        store.requestDelete(item(9))
        XCTAssertNil(store.pendingRestore); XCTAssertEqual(store.pendingDelete?.id, 9)
        store.cancelDelete(); store.confirmRestore(); store.confirmEmpty(); store.confirmDelete()
        XCTAssertFalse(bridge.calls.contains { ["restore", "delete", "empty"].contains($0.0) })
    }

    // 产品保证：不可恢复条目不产生恢复确认，仍可经独立确认彻底删除。
    func testBlockedItemDoesNotOpenRestoreConfirmation() {
        let bridge = TrashBridgeFake()
        let blocked = TrashItem(id: 8, kind: "memo", title: "损坏条目", deletedAt: "", deletedDate: "2026-10-10",
            remainingDays: 3, originSyncID: "", categoryName: "", categoryColor: "", restorable: false,
            blockedReason: "corrupted", details: TrashDetails())
        XCTAssertFalse(blocked.restorable)
        let store = TrashStore(bridge: bridge)
        store.requestRestore(blocked); XCTAssertNil(store.pendingRestore)
        store.confirmRestore(); XCTAssertTrue(bridge.calls.isEmpty)
        store.requestDelete(blocked); XCTAssertEqual(store.pendingDelete?.id, 8)
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
    // 产品保证：多选全选可反选，刷新移除失效编号，离开页面清空选择与确认。
    func testBatchSelectionLifecycle() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(9), item(4)]
        let store = TrashStore(bridge: bridge); store.activate(); store.beginSelection()
        XCTAssertFalse(store.allSelected); store.toggleSelectAll(); XCTAssertEqual(store.selection, [9, 4]); XCTAssertTrue(store.allSelected)
        store.toggleSelectAll(); XCTAssertTrue(store.selection.isEmpty)
        store.toggleSelection(4); store.toggleSelection(9); bridge.result.items = [item(4)]; store.reload()
        XCTAssertEqual(store.selection, [4]); store.requestDeleteSelection(); store.deactivate()
        XCTAssertFalse(store.selecting); XCTAssertTrue(store.selection.isEmpty); XCTAssertNil(store.confirmation)
    }
    // 产品保证：批量恢复按列表次序逐条写，成功项移出选择，混合失败逐条说明，整批仅重读一次。
    func testPartialRestoreKeepsFailuresAndReloadsOnce() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(9), item(4), item(7)]
        let store = TrashStore(bridge: bridge); store.activate(); store.beginSelection()
        store.toggleSelection(7); store.toggleSelection(4); store.toggleSelection(9)
        bridge.restoreResults[4] = TrashActionResult(error: "与已有记录冲突", conflict: "focus")
        bridge.restoreResults[7] = TrashActionResult(error: "数据库只读")
        bridge.onRestore = { id in
            if id == 9 { bridge.result.items.removeAll { $0.id == 9 } }
            bridge.onChanged?()
        }
        let reads = bridge.readCount; store.restoreSelection()
        XCTAssertEqual(bridge.calls.filter { $0.0 == "restore" }.map(\.1), [[9], [4], [7]])
        XCTAssertEqual(bridge.readCount, reads + 1); XCTAssertEqual(store.selection, [4, 7]); XCTAssertTrue(store.selecting)
        XCTAssertEqual(store.actionError, "有 2 项没能恢复：没能恢复「条目」：与已有记录冲突\n没能恢复「条目」：数据库只读")
        XCTAssertEqual(store.batchNotice, "")
    }
    // 产品保证：全部恢复成功退出多选并显示批次数，清提示同时清批量成功文案。
    func testBatchRestoreSuccessNotice() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(9), item(4), item(7)]
        let store = TrashStore(bridge: bridge); store.activate(); store.beginSelection(); store.toggleSelectAll()
        store.restoreSelection()
        XCTAssertFalse(store.selecting); XCTAssertTrue(store.selection.isEmpty); XCTAssertEqual(store.batchNotice, "已恢复 3 项")
        store.dismissNotice(); XCTAssertEqual(store.batchNotice, ""); XCTAssertEqual(store.actionError, "")
    }
    // 产品保证：不可恢复条目不调用恢复服务，抛错条目也保留选择并显示逐条原因。
    func testBlockedAndThrownRestoreFailures() {
        let bridge = TrashBridgeFake()
        let blocked = TrashItem(id: 7, kind: "memo", title: "损坏", deletedAt: "", deletedDate: "2026-10-10", remainingDays: 3,
            originSyncID: "", categoryName: "", categoryColor: "", restorable: false, blockedReason: "corrupted", details: TrashDetails())
        XCTAssertFalse(blocked.restorable); bridge.result.items = [blocked, item(9)]
        let store = TrashStore(bridge: bridge); store.activate(); store.beginSelection(); store.toggleSelectAll()
        bridge.actionError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "锁定"])
        store.restoreSelection()
        XCTAssertEqual(bridge.calls.filter { $0.0 == "restore" }.map(\.1), [[9]])
        XCTAssertEqual(store.selection, [7, 9]); XCTAssertEqual(store.actionError, "有 2 项没能恢复：没能恢复「损坏」：内容已损坏，无法恢复\n没能恢复「条目」：锁定")
    }
    // 产品保证：批量彻底删除固定确认时的列表顺序，取消不写，成功退出多选。
    func testBatchDeleteConfirmationCapturesOrderedIDs() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(9), item(4)]
        let store = TrashStore(bridge: bridge); store.activate(); store.beginSelection()
        store.requestDeleteSelection(); XCTAssertNil(store.confirmation)
        store.toggleSelection(4); store.toggleSelection(9); store.requestDeleteSelection()
        XCTAssertEqual(store.confirmation, .deleteSelection(2)); XCTAssertEqual(store.confirmation?.title, "彻底删除选中的 2 项？")
        store.cancelConfirmation(); store.confirmDeleteSelection(); XCTAssertFalse(bridge.calls.contains { $0.0 == "empty" })
        store.requestDeleteSelection(); bridge.result.items.insert(item(12), at: 0); store.reload(); store.toggleSelection(12)
        store.confirmDeleteSelection()
        XCTAssertEqual(bridge.calls.last?.0, "empty"); XCTAssertEqual(bridge.calls.last?.1, [9, 4]); XCTAssertFalse(store.selecting)
    }
    // 产品保证：批量彻底删除返回错误或抛错时保留选中并显示原文，不把失败当成功。
    func testBatchDeleteFailuresPreserveSelection() {
        for throwing in [false, true] {
            let bridge = TrashBridgeFake(); bridge.result.items = [item(9), item(4)]
            let store = TrashStore(bridge: bridge); store.activate(); store.beginSelection(); store.toggleSelectAll(); store.requestDeleteSelection()
            if throwing { bridge.actionError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "删除失败"]) }
            else { bridge.actionResult = TrashActionResult(error: "删除失败") }
            store.confirmDeleteSelection()
            XCTAssertEqual(store.selection, [9, 4]); XCTAssertTrue(store.selecting); XCTAssertEqual(store.actionError, "删除失败")
            XCTAssertNil(store.confirmation)
        }
    }
    // 产品保证：批量删除确认出现后，取消操作会通知订阅确认状态的界面关闭面板。
    func testBatchConfirmationCancellationIsObservable() {
        let bridge = TrashBridgeFake(); bridge.result.items = [item(9)]
        let store = TrashStore(bridge: bridge); store.activate(); store.beginSelection(); store.toggleSelectAll()
        store.requestDeleteSelection(); XCTAssertEqual(store.confirmation, .deleteSelection(1))
        // Observation 的回调在同一主线程写入时同步执行，本用例不跨线程读写这个标志。
        final class Flag: @unchecked Sendable { var changed = false }
        let flag = Flag()
        withObservationTracking({ _ = store.confirmation }) { flag.changed = true }
        store.cancelConfirmation()
        XCTAssertNil(store.confirmation); XCTAssertTrue(flag.changed)
    }
}
