import XCTest
@testable import IPadCore

@MainActor final class TaskActionsTests: XCTestCase {
    private func fixture() -> (ShellStore, TaskBridgeFake, TaskActions) {
        let shell = ShellStore(bridge: ShellBridgeFake()); let tasks = TaskBridgeFake()
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        return (shell, tasks, TaskActions(tasks: tasks, pendingDeletion: pending, shell: shell))
    }
    // 产品保证：专注钩子的四类结果决定准确文案，需要确认时只切页，不伪称结束。
    func testCompletionOutcomeMessagesAndNavigation() {
        let cases: [(TaskCompletionFocusOutcome, String, PageID)] = [
            (.none, "已完成「甲」", .dashboard),
            (.ended(discarded: false), "已完成「甲」，专注已结束", .dashboard),
            (.ended(discarded: true), "已完成「甲」，专注不足 3 分钟，未计入记录", .dashboard),
            (.failed, "已完成「甲」，但结束专注失败，计时仍在继续", .dashboard),
            (.needsConfirmation, "已完成「甲」", .focus)
        ]
        for (outcome, message, page) in cases {
            let (shell, tasks, actions) = fixture(); let hook = FocusFlowHookFake(); hook.outcome = outcome; actions.focusHook = hook
            XCTAssertTrue(actions.complete(id: 7, title: "甲")); XCTAssertEqual(tasks.calls.first?.numbers, [1])
            XCTAssertEqual(hook.completed, [7]); XCTAssertEqual(shell.toast?.message, message); XCTAssertEqual(shell.selection, page)
            shell.retireToast()
        }
    }
    // 产品保证：撤销完成只取消完成态，不重新启动已经结束的专注。
    func testUndoCompletionOnlyChangesCompletedFlag() {
        let (shell, tasks, actions) = fixture(); let hook = FocusFlowHookFake(); actions.focusHook = hook
        XCTAssertTrue(actions.complete(id: 7, title: "甲", note: "完成记录"))
        XCTAssertEqual(tasks.calls.first?.name, "complete"); XCTAssertEqual(tasks.calls.first?.text, ["完成记录"])
        shell.triggerToastAction()
        XCTAssertEqual(tasks.calls.last?.name, "setCompleted"); XCTAssertEqual(tasks.calls.last?.ids, [7]); XCTAssertEqual(tasks.calls.last?.numbers, [0])
        XCTAssertEqual(hook.completed, [7])
    }
    // 产品保证：任务完成失败显示服务原文，不调用专注钩子、不切页。
    func testFailedCompletionNeverCallsHook() {
        let (shell, tasks, actions) = fixture(); let hook = FocusFlowHookFake(); actions.focusHook = hook
        tasks.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据库不可写"])
        XCTAssertFalse(actions.complete(id: 7, title: "甲")); XCTAssertTrue(hook.completed.isEmpty)
        XCTAssertEqual(shell.toast?.message, "数据库不可写"); XCTAssertEqual(shell.selection, .dashboard)
    }
    // 产品保证：P4-1 未装配钩子时完成仍可用，去专注页只切页。
    func testNilHookCompletesAndNavigates() {
        let (shell, _, actions) = fixture(); XCTAssertNil(actions.focusHook)
        XCTAssertTrue(actions.complete(id: 7, title: "甲")); XCTAssertEqual(shell.toast?.message, "已完成「甲」")
        actions.openFocus(id: 7, title: "甲"); XCTAssertEqual(shell.selection, .focus)
    }
    // 产品保证：任务入口先经外壳切到专注页，再交给钩子，不把业务判断放在页面。
    func testOpenFocusForwardsTask() {
        let (shell, _, actions) = fixture(); let hook = FocusFlowHookFake(); actions.focusHook = hook
        actions.openFocus(id: 13, title: "乙"); XCTAssertEqual(shell.selection, .focus)
        XCTAssertEqual(hook.opened.first?.0, 13); XCTAssertEqual(hook.opened.first?.1, "乙")
    }
    // 产品保证：所有任务入口的删除走同一个撤销 Store，恢复遮罩期间不写任务或改变专注。
    func testDeleteUsesPendingStoreAndRestoreBlocksActions() {
        let (shell, _, actions) = fixture()
        XCTAssertTrue(actions.delete(id: 7, title: "甲")); XCTAssertEqual(actions.pendingDeletion.pendingTaskID, 7)
        let blocked = ShellBridgeFake(); blocked.snapshot.operationBlocksUI = true
        let blockedShell = ShellStore(bridge: blocked); let tasks = TaskBridgeFake()
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: blockedShell)
        let blockedActions = TaskActions(tasks: tasks, pendingDeletion: pending, shell: blockedShell)
        XCTAssertFalse(blockedActions.complete(id: 7, title: "甲")); XCTAssertFalse(blockedActions.uncomplete(id: 7))
        XCTAssertFalse(blockedActions.delete(id: 7, title: "甲")); blockedActions.openFocus(id: 7, title: "甲")
        XCTAssertTrue(tasks.calls.isEmpty); XCTAssertEqual(blockedShell.selection, .dashboard)
        shell.retireToast()
    }
}
