import XCTest
@testable import IPadCore

@MainActor final class TaskActionsTests: XCTestCase {
    private func fixture(bridge: ShellBridgeFake = ShellBridgeFake()) -> (ShellStore, TaskBridgeFake, TaskActions) {
        let shell = ShellStore(bridge: bridge); let tasks = TaskBridgeFake()
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
    // 产品保证：撤销完成失败与 Mac 文案一致，不把桥接的技术错误直接交给用户。
    func testFailedUncompleteUsesMacMessageForDirectAndToastActions() {
        let (shell, tasks, actions) = fixture()
        XCTAssertTrue(actions.complete(id: 7, title: "甲"))
        tasks.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据库技术错误"])
        shell.triggerToastAction()
        XCTAssertEqual(shell.toast?.message, "撤销完成失败，请重试")
        XCTAssertEqual(tasks.calls.last?.numbers, [0])
        XCTAssertFalse(actions.uncomplete(id: 7))
        XCTAssertEqual(shell.toast?.message, "撤销完成失败，请重试")
    }

    // 产品保证：批量完成一次写库，只有正在专注项补文案，撤销一次取消整批完成。
    func testBatchCompletionAndUndoUseOneWrite() {
        let (shell, tasks, actions) = fixture(); let hook = FocusFlowHookFake(); actions.focusHook = hook
        hook.outcomes[4] = .ended(discarded: false)
        XCTAssertTrue(actions.complete(ids: [9, 4, 7]))
        XCTAssertEqual(tasks.calls.count, 1); XCTAssertEqual(tasks.calls.first?.name, "setCompletedBatch")
        XCTAssertEqual(tasks.calls.first?.ids, [9, 4, 7]); XCTAssertEqual(tasks.calls.first?.numbers, [1])
        XCTAssertEqual(hook.completed, [9, 4, 7]); XCTAssertEqual(shell.toast?.message, "已完成 3 项任务，专注已结束")
        shell.triggerToastAction()
        XCTAssertEqual(tasks.calls.count, 2); XCTAssertEqual(tasks.calls.last?.ids, [9, 4, 7]); XCTAssertEqual(tasks.calls.last?.numbers, [0])
        XCTAssertEqual(hook.completed, [9, 4, 7])
    }
    // 产品保证：批量删除只写一次，提示的查看动作切到废纸篓。
    func testBatchDeleteOpensTrash() {
        let (shell, tasks, actions) = fixture()
        XCTAssertTrue(actions.delete(ids: [9, 4])); XCTAssertEqual(tasks.calls.count, 1)
        XCTAssertEqual(tasks.calls.first?.name, "deleteBatch"); XCTAssertEqual(tasks.calls.first?.ids, [9, 4])
        XCTAssertEqual(shell.toast?.actionTitle, "查看"); shell.triggerToastAction(); XCTAssertEqual(shell.selection, .trash)
    }
    // 产品保证：空批次、操作阻断都不写库；服务失败显示原文且不调用专注钩子。
    func testBatchFailuresAndGuards() {
        let bridge = ShellBridgeFake()
        let (shell, tasks, actions) = fixture(bridge: bridge); let hook = FocusFlowHookFake(); actions.focusHook = hook
        XCTAssertFalse(actions.complete(ids: [])); XCTAssertFalse(actions.delete(ids: [])); XCTAssertTrue(tasks.calls.isEmpty)
        tasks.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "不可写"])
        XCTAssertFalse(actions.complete(ids: [9])); XCTAssertFalse(actions.delete(ids: [9]))
        XCTAssertEqual(shell.toast?.message, "不可写"); XCTAssertTrue(hook.completed.isEmpty)
        tasks.error = nil
        bridge.snapshot.operationBlocksUI = true; shell.refresh()
        let count = tasks.calls.count
        XCTAssertFalse(actions.complete(ids: [9])); XCTAssertFalse(actions.delete(ids: [9])); XCTAssertEqual(tasks.calls.count, count)
    }
    // 产品保证：批量完成只有非空专注结果补文案，需要确认时切到专注页，未关联项不污染提示。
    func testBatchFocusOutcomes() {
        let cases: [(TaskCompletionFocusOutcome, String, PageID)] = [
            (.none, "已完成 3 项任务", .dashboard),
            (.ended(discarded: true), "已完成 3 项任务，专注不足 3 分钟，未计入记录", .dashboard),
            (.failed, "已完成 3 项任务，但结束专注失败，计时仍在继续", .dashboard),
            (.needsConfirmation, "已完成 3 项任务", .focus)
        ]
        for (outcome, message, page) in cases {
            let (shell, _, actions) = fixture(); let hook = FocusFlowHookFake(); actions.focusHook = hook; hook.outcomes[4] = outcome
            XCTAssertTrue(actions.complete(ids: [9, 4, 7])); XCTAssertEqual(hook.completed, [9, 4, 7])
            XCTAssertEqual(shell.toast?.message, message); XCTAssertEqual(shell.selection, page)
        }
    }
}
