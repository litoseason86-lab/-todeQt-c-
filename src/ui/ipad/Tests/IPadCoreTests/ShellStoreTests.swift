import XCTest
@testable import IPadCore

@MainActor private final class FakeShellBridge: ShellBridgeProtocol {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var snapshot = ShellSnapshot()
    var error: Error?
    var captureResult = 9
    var calls: [String] = []
    func read() throws -> ShellSnapshot { if let error { throw error }; return snapshot }
    func pause() -> Bool { calls.append("pause"); return true }
    func resume() -> Bool { calls.append("resume"); return true }
    func capture(title: String, categoryID: Int, sourceTaskID: Int) -> Int {
        calls.append("capture:\(title):\(categoryID):\(sourceTaskID)")
        return captureResult
    }
    func select(page: String) { calls.append("select:\(page)") }
}

@MainActor final class ShellStoreTests: XCTestCase {
    // 产品保证：只有专注页的工具栏捕获才带计时任务，其它页面保持无来源。
    func testCaptureSourceOnlyOnFocusPage() {
        let bridge = FakeShellBridge()
        let store = ShellStore(bridge: bridge)
        store.captureSourceProvider = { ShellCaptureSource(taskID: 41, categoryID: 3) }
        store.select(.dashboard); store.presentCapture(); store.captureTitle = "无来源"
        XCTAssertTrue(store.capture())
        store.select(.focus); store.presentCapture(); store.captureTitle = "来自任务"
        XCTAssertTrue(store.capture())
        XCTAssertTrue(bridge.calls.contains("capture:无来源:-1:-1"))
        XCTAssertTrue(bridge.calls.contains("capture:来自任务:3:41"))
    }
    // 产品保证：读取失败保留上一份有效摘要，重试成功再清错并更新，失败不伪装为零任务。
    func testReadFailureKeepsSnapshotAndRetryClearsError() {
        let bridge = FakeShellBridge()
        bridge.snapshot.todayPendingCount = 7
        let store = ShellStore(bridge: bridge)
        XCTAssertEqual(store.snapshot.todayPendingCount, 7)
        bridge.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])
        bridge.onChanged?()
        XCTAssertEqual(store.snapshot.todayPendingCount, 7)
        XCTAssertEqual(store.errorMessage, "读取失败")
        bridge.error = nil
        bridge.snapshot.todayPendingCount = 3
        bridge.onChanged?()
        XCTAssertEqual(store.snapshot.todayPendingCount, 3)
        XCTAssertEqual(store.errorMessage, "")
    }
    // 产品保证：恢复遮罩期间禁止导航、计时和记一笔，解除后计时动作按显示状态转发。
    func testRestoreBlocksActionsAndTimerIntentUsesSnapshot() {
        let bridge = FakeShellBridge()
        bridge.snapshot.operationBlocksUI = true
        let store = ShellStore(bridge: bridge)
        store.select(.memo); store.toggleTimer(); store.presentCapture()
        store.captureTitle = "不能写入"
        XCTAssertFalse(store.capture())
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertFalse(store.capturePresented)
        bridge.snapshot.operationBlocksUI = false
        bridge.snapshot.running = true
        bridge.onChanged?()
        store.toggleTimer()
        bridge.snapshot.running = false
        bridge.onChanged?()
        store.toggleTimer()
        XCTAssertEqual(bridge.calls, ["pause", "resume"])
    }
    // 产品保证：新提示顶掉撤销条时只通知旧调用方一次，点击新动作不再触发旧提交。
    func testReplacingToastRetiresOldCallbackExactlyOnce() {
        let store = ShellStore(bridge: FakeShellBridge())
        var retired = 0
        var actions = 0
        store.showToast("待撤销", actionTitle: "撤销", action: { actions += 100 }, onRetired: { retired += 1 })
        store.showToast("新提示", actionTitle: "查看", action: { actions += 1 })
        XCTAssertEqual(retired, 1)
        XCTAssertEqual(store.toast?.message, "新提示")
        store.triggerToastAction()
        store.triggerToastAction()
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(retired, 1)
        XCTAssertNil(store.toast)
    }
    // 产品保证：提示超时后调用方收到退场通知，撤销动作执行后不会再被旧计时器提交。
    func testToastTimeoutAndActionCancellation() async throws {
        let store = ShellStore(bridge: FakeShellBridge())
        var retired = 0
        store.showToast("会过期", durationMilliseconds: 10, onRetired: { retired += 1 })
        // 给定时器留等待窗口，只断言最终效果；不把精确调度延迟当产品契约。
        for _ in 0..<100 where store.toast != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.toast)
        XCTAssertEqual(retired, 1)
        store.showToast("撤销", actionTitle: "撤销", durationMilliseconds: 10, action: {}, onRetired: { retired += 1 })
        store.triggerToastAction()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(retired, 1)
    }
    // 产品保证：捕获失败保留文字与浮层，成功只转发标题并关闭，不调用计时操作。
    func testCaptureFailureKeepsInputAndSuccessClosesPopover() {
        let bridge = FakeShellBridge()
        bridge.captureResult = -1
        let store = ShellStore(bridge: bridge)
        store.presentCapture()
        store.captureTitle = " 中文问题 "
        XCTAssertFalse(store.capture())
        XCTAssertEqual(store.captureTitle, " 中文问题 ")
        XCTAssertTrue(store.capturePresented)
        bridge.captureResult = 99
        XCTAssertTrue(store.capture())
        XCTAssertFalse(store.capturePresented)
        XCTAssertEqual(store.captureTitle, "")
        XCTAssertEqual(bridge.calls, ["capture:中文问题:-1:-1", "capture:中文问题:-1:-1"])
    }
    // 产品保证：快捷键选页保存本机状态，更多与侧栏遵循用户顺序且固定入口末尾。
    func testSelectionAndNavigationGroupsUsePreferences() {
        let bridge = FakeShellBridge()
        bridge.snapshot.sidebarOrder = ["memo", "countdown", "stats", "today"]
        bridge.snapshot.selectedPage = "memo"
        let store = ShellStore(bridge: bridge)
        XCTAssertEqual(store.selection, .memo)
        XCTAssertEqual(Array(store.sidebarPages.prefix(3)), [.memo, .countdown, .statistics])
        XCTAssertEqual(Array(store.morePages.suffix(2)), [.trash, .settings])
        store.select(.focus)
        XCTAssertEqual(bridge.calls, ["select:focus"])
    }
    // 产品保证：进后台的保存同步执行，已注销页面不再保存。
    func testEditFlushersCanBeRemoved() {
        let store = ShellStore(bridge: FakeShellBridge())
        var saved: [String] = []
        let removed = store.registerEditFlusher { saved.append("移除") }
        store.registerEditFlusher { saved.append("保留") }
        store.unregisterEditFlusher(removed)
        store.flushEdits()
        XCTAssertEqual(saved, ["保留"])
    }
}
