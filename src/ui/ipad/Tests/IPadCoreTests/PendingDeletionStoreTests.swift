import XCTest
@testable import IPadCore

@MainActor final class PendingDeletionStoreTests: XCTestCase {
    private func fixture() -> (ShellStore, PendingDeletionBridgeFake, TaskBridgeFake, PendingDeletionStore) {
        let shell = ShellStore(bridge: ShellBridgeFake()); let deletion = PendingDeletionBridgeFake(); deletion.commitFailureReason = "数据库写入失败：T33-2 blocked"; let tasks = TaskBridgeFake()
        return (shell, deletion, tasks, PendingDeletionStore(bridge: deletion, tasks: tasks, shell: shell))
    }
    // 产品保证：请求删除显示撤销条与待删编号，撤销只调 cancel，不提交。
    func testRequestShowsUndoAndCancelRestoresRow() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestTask(id: 7, title: "甲")); XCTAssertEqual(store.pendingTaskID, 7)
        XCTAssertEqual(shell.toast?.message, "已删除「甲」"); XCTAssertEqual(shell.toast?.actionTitle, "撤销")
        shell.triggerToastAction()
        XCTAssertEqual(bridge.calls.map(\.name), ["requestTask", "cancel"]); XCTAssertEqual(store.pendingTaskID, -1)
    }
    // 产品保证：提前提交只收起自己那条撤销提示，不误收起后来的其它提示。
    func testRetiredDismissesOnlyOwnedToast() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestTask(id: 7, title: "甲")); bridge.onRetired?(); XCTAssertNil(shell.toast)
        XCTAssertTrue(store.requestTask(id: 8, title: "乙"))
        shell.showToast("其它提示"); let otherID = shell.toast?.id
        bridge.onRetired?(); XCTAssertEqual(shell.toast?.id, otherID); XCTAssertEqual(shell.toast?.message, "其它提示")
    }
    // 产品保证：新提示顶掉撤销入口时立即提交一次，提交后隐藏行状态清空。
    func testReplacingToastCommitsFirst() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestTask(id: 7, title: "甲")); XCTAssertTrue(bridge.state.active)
        shell.showToast("新提示")
        XCTAssertEqual(bridge.calls.map(\.name), ["requestTask", "commit"])
        XCTAssertFalse(bridge.state.active); XCTAssertEqual(shell.toast?.message, "新提示")
    }
    // 产品保证：提交失败显示原标题且返回 false，补录或备份流程可以据此停止。
    func testCommitFailureIncludesTitleAndStopsCaller() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestTask(id: 7, title: "要保留的标题"))
        bridge.commitError = NSError(domain: "测试", code: 1)
        XCTAssertFalse(store.commitIfNeeded()); XCTAssertEqual(store.pendingTaskID, -1)
        XCTAssertEqual(shell.toast?.message, "删除「要保留的标题」失败：数据库写入失败：T33-2 blocked")
    }
    // 产品保证：例行任务的撤销文案说明只删除今天的实例。
    func testRoutineMessageExplainsTodayOnly() {
        let (shell, _, tasks, store) = fixture(); tasks.routine = true
        XCTAssertTrue(store.requestTask(id: 7, title: "背词"))
        XCTAssertEqual(shell.toast?.message, "已删除今天的例行任务「背词」")
    }
    // 产品保证：第二次删除先提交旧槽，再显示新撤销条，新任务不会被旧提示的退场回调提交。
    func testSecondDeletionRetiresOldToastBeforeShowingNew() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestTask(id: 7, title: "第一个")); XCTAssertEqual(store.pendingTaskID, 7)
        XCTAssertTrue(store.requestTask(id: 8, title: "第二个"))
        XCTAssertEqual(bridge.calls.filter { $0.name == "commit" }.count, 1)
        XCTAssertTrue(bridge.state.active); XCTAssertEqual(store.pendingTaskID, 8)
        XCTAssertEqual(shell.toast?.message, "已删除「第二个」"); XCTAssertEqual(shell.toast?.actionTitle, "撤销")
        shell.triggerToastAction(); XCTAssertEqual(bridge.calls.last?.name, "cancel")
    }
    // 产品保证：请求失败显示本次原因，不保留无关旧提示，也不制造删除成功提示。
    func testFailedRequestShowsBridgeReason() {
        let (shell, bridge, _, store) = fixture(); shell.showToast("已有提示")
        bridge.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "删除服务未登记或已释放"])
        XCTAssertFalse(store.requestTask(id: 7, title: "甲"))
        XCTAssertEqual(shell.toast?.message, "删除服务未登记或已释放")
        bridge.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "记录编号无效"])
        XCTAssertFalse(store.requestSession(id: 9, isRest: false))
        XCTAssertEqual(shell.toast?.message, "记录编号无效")
        XCTAssertFalse(bridge.state.active)
    }
    // 产品保证：新请求提交旧槽失败时仍只用原条目标题提示，不被随后抛出的通用错误盖掉。
    func testFailedPreviousCommitKeepsSingleTitleFailure() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestTask(id: 7, title: "旧任务"))
        bridge.commitError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "请求删除任务失败"])
        let callback = bridge.onCommitFailed
        var callbackToastID: UUID?
        bridge.onCommitFailed = { title, reason in callback?(title, reason); callbackToastID = shell.toast?.id }
        XCTAssertFalse(store.requestTask(id: 9, title: "新任务"))
        XCTAssertEqual(shell.toast?.message, "删除「旧任务」失败：数据库写入失败：T33-2 blocked")
        XCTAssertNotNil(callbackToastID); XCTAssertEqual(shell.toast?.id, callbackToastID)
        XCTAssertEqual(bridge.calls.filter { $0.name == "commit" }.count, 1)
    }
    // 产品保证：专注与休息编号互不混用，缺省标题是专注记录，撤销不提交。
    func testSessionRequestPreservesKindAndDefaultTitle() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestSession(id: 9, isRest: true)); XCTAssertEqual(store.pendingSessionID, 9)
        XCTAssertEqual(bridge.calls.first?.title, "专注记录"); XCTAssertTrue(bridge.calls.first?.isRest == true)
        XCTAssertEqual(shell.toast?.message, "已删除休息记录「专注记录」")
        shell.triggerToastAction(); XCTAssertEqual(bridge.calls.map(\.name), ["requestSession", "cancel"])
        XCTAssertTrue(store.commitIfNeeded()); XCTAssertEqual(bridge.calls.count, 2)
    }
    // 产品保证：外壳切换旁白状态时，撤销仓库独立转发暂停状态，不夹带任何撤销、提交或取消操作。
    func testSetAutomaticCommitSuspendedForwardsToBridgeWithoutExtraCalls() {
        let (_, bridge, _, store) = fixture()
        store.setAutomaticCommitSuspended(true)
        store.setAutomaticCommitSuspended(false)
        XCTAssertEqual(bridge.automaticCommitSuspensions, [true, false])
        XCTAssertTrue(bridge.calls.isEmpty)
    }
    // 产品保证：Qt 自动到期的提交失败不经过 Store 调用包装，也只显示一条原标题和具体原因。
    func testAutomaticCommitFailureKeepsTitleAndReason() {
        let (shell, bridge, _, store) = fixture()
        XCTAssertTrue(store.requestSession(id: 9, title: "原记录", isRest: true))
        bridge.commitError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "不应覆盖回调的错误"])
        // 模拟 C++ 到期回调直接提交，不能误用 Store.commitIfNeeded 掩盖后台路径。
        try? bridge.commit()
        XCTAssertEqual(shell.toast?.message, "删除「原记录」失败：数据库写入失败：T33-2 blocked")
        XCTAssertFalse(store.state.active)
        XCTAssertEqual(bridge.calls.filter { $0.name == "commit" }.count, 1)
    }

}
