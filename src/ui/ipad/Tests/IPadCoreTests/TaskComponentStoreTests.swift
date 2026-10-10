import XCTest
@testable import IPadCore

@MainActor final class TaskComponentStoreTests: XCTestCase {
    // 测试持有真实宿主生命周期；Store 的弱引用不应因用例省略返回元组一项而提前失效。
    private var retainedShell: ShellStore?
    private func task(completed: Bool = false) -> TaskValue {
        var value = TaskValue(); value.id = 12; value.title = "最新标题"; value.date = "2026-10-08"
        value.categoryID = 8; value.estimatedMinutes = 37; value.notes = "准备备注"
        value.completionNote = "上次记录"; value.completed = completed; return value
    }
    private func category(_ id: Int) -> CategoryValue { var value = CategoryValue(); value.id = id; value.name = "科目\(id)"; return value }
    private func failure(_ text: String) -> Error { NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func editor(completed: Bool = false) -> (TaskEditorStore, TaskBridgeFake, InteractionBridgeFake, TaskFormCategoryFake, ShellStore) {
        let tasks = TaskBridgeFake(); let interactions = InteractionBridgeFake(); interactions.latest = task(completed: completed)
        let categories = TaskFormCategoryFake(); categories.values = [category(8), category(3)]
        let shell = ShellStore(bridge: ShellBridgeFake()); retainedShell = shell
        return (TaskEditorStore(tasks: tasks, interactions: interactions, categories: categories, shell: shell), tasks, interactions, categories, shell)
    }
    private func completion() -> (TaskCompletionNoteStore, TaskBridgeFake, InteractionBridgeFake, ShellStore) {
        let tasks = TaskBridgeFake(); let interactions = InteractionBridgeFake(); interactions.latest = task()
        let shell = ShellStore(bridge: ShellBridgeFake()); retainedShell = shell
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        let actions = TaskActions(tasks: tasks, pendingDeletion: pending, shell: shell)
        return (TaskCompletionNoteStore(interactions: interactions, actions: actions, shell: shell), tasks, interactions, shell)
    }
    // 产品保证：详情表单读取令牌里的最新任务，只改标题时不覆盖其它设备改过的字段。
    func testFreshTaskAndTitleOnlyChange() {
        let (store, tasks, interactions, _, _) = editor()
        XCTAssertTrue(store.begin(id: 12)); XCTAssertTrue(interactions.refreshBlocked)
        XCTAssertEqual(store.title, "最新标题"); XCTAssertEqual(store.date, "2026-10-08")
        XCTAssertEqual(interactions.calls.first?.id, 12)
        store.title = "新标题"; XCTAssertTrue(store.save())
        var expected = TaskChanges(); expected.title = "新标题"
        XCTAssertEqual(tasks.changes.first?.0, 12); XCTAssertEqual(tasks.changes.first?.1, expected)
        XCTAssertFalse(store.active); XCTAssertFalse(interactions.refreshBlocked)
    }
    // 产品保证：明确清空科目、备注、完成记录和预计用时会提交，未改字段不提交。
    func testChangedFieldsIncludeExplicitClearsAndZero() {
        let (store, tasks, _, _, _) = editor(completed: true)
        XCTAssertTrue(store.begin(id: 12)); XCTAssertEqual(store.completionNote, "上次记录")
        store.categoryID = -2; store.date = "2026-10-11"; store.estimatedMinutes = 0; store.notes = ""; store.completionNote = ""
        XCTAssertTrue(store.save())
        var expected = TaskChanges(); expected.category = TaskCategoryChange.none; expected.date = "2026-10-11"
        expected.estimatedMinutes = 0; expected.notes = ""; expected.completionNote = ""
        XCTAssertEqual(tasks.changes.first?.1, expected)
    }
    // 产品保证：未完成表单不提交隐藏的完成记录，存量超上限预计用时未碰过时也不重写。
    func testHiddenCompletionNoteAndUntouchedLegacyEstimate() {
        let (store, tasks, interactions, _, _) = editor(); interactions.latest.estimatedMinutes = 2000
        XCTAssertTrue(store.begin(id: 12)); XCTAssertEqual(store.estimatedMinutes, 2000)
        store.completionNote = "不应提交"; store.title = "只改标题"
        XCTAssertTrue(store.save()); XCTAssertNil(tasks.changes.first?.1.completionNote); XCTAssertNil(tasks.changes.first?.1.estimatedMinutes)
    }
    // 产品保证：保存失败保留所有输入和编辑令牌，成功重试后才释放刷新冻结。
    func testFailedSaveKeepsDraftAndTokenUntilRetry() {
        let (store, tasks, interactions, _, _) = editor()
        XCTAssertTrue(store.begin(id: 12)); store.notes = "未保存草稿"; tasks.error = failure("写库失败原文")
        XCTAssertFalse(store.save()); XCTAssertTrue(store.active); XCTAssertTrue(interactions.refreshBlocked)
        XCTAssertEqual(store.notes, "未保存草稿"); XCTAssertEqual(store.errorMessage, "写库失败原文")
        tasks.error = nil; XCTAssertTrue(store.save()); XCTAssertFalse(interactions.refreshBlocked)
    }
    // 产品保证：beginEdit 失败清楚提示，不展示旧任务，也不执行写入。
    func testBeginEditFailureDoesNotWriteOrOpenStaleTask() {
        let (store, tasks, interactions, _, shell) = editor(); interactions.error = failure("任务已被另一台删除")
        XCTAssertFalse(store.begin(id: 12)); XCTAssertFalse(store.active); XCTAssertNil(store.initialTask)
        XCTAssertEqual(store.errorMessage, "任务已被另一台删除"); XCTAssertEqual(shell.toast?.message, "任务已被另一台删除")
        XCTAssertFalse(store.save()); XCTAssertTrue(tasks.changes.isEmpty)
    }
    // 产品保证：取消和无改动保存均为零写入，退出后解除编辑冻结。
    func testCancelAndUnchangedSaveHaveNoWrites() {
        let (store, tasks, interactions, _, _) = editor()
        XCTAssertTrue(store.begin(id: 12)); store.title = "取消草稿"; store.cancel()
        XCTAssertFalse(interactions.refreshBlocked); XCTAssertTrue(tasks.calls.isEmpty)
        XCTAssertTrue(store.begin(id: 12)); XCTAssertTrue(store.save()); XCTAssertTrue(tasks.calls.isEmpty)
    }
    // 产品保证：表单存活时持有令牌，表单意外释放也通过令牌 owner 解除冻结。
    func testEditorReleaseUnblocksRefresh() {
        let (_, tasks, interactions, categories, shell) = editor()
        var store: TaskEditorStore? = TaskEditorStore(tasks: tasks, interactions: interactions, categories: categories, shell: shell)
        XCTAssertTrue(store!.begin(id: 12)); XCTAssertTrue(interactions.refreshBlocked)
        weak let released = store; store = nil
        XCTAssertNil(released); XCTAssertFalse(interactions.refreshBlocked)
    }
    // 产品保证：科目同步重排按编号保持选中，被删除才退到不设置科目；表单打开期间收到变化会重读，关闭后不再重读。
    func testCategoryReorderRemovalAndOpenCloseLifetime() {
        let (store, _, _, categories, _) = editor()
        XCTAssertNil(categories.onChanged)
        XCTAssertTrue(store.begin(id: 12)); XCTAssertEqual(store.categoryID, 8)
        categories.values = [category(3), category(8)]; categories.onChanged?(); XCTAssertEqual(store.categoryID, 8)
        XCTAssertEqual(store.categories.values.map(\.id), [3, 8])
        categories.values = [category(3)]; categories.onChanged?(); XCTAssertEqual(store.categoryID, -1)
        let stale = categories.onChanged; store.cancel(); XCTAssertNil(categories.onChanged)
        // 即使旧回调被别处持有，关闭后也不再重读。
        categories.values = [category(3), category(9)]; stale?()
        XCTAssertEqual(store.categories.values.map(\.id), [3])
    }
    // 产品保证：内联新建先同步刷新再返回编号仍能选中新科目，取消不会留下哨兵科目。
    func testInlineCreationUsesReturnedIDAfterSynchronousSignal() {
        let (store, _, _, categories, _) = editor(); XCTAssertTrue(store.begin(id: 12))
        let picker = store.categories; picker.beginNewCategory(); picker.cancelNewCategory(); XCTAssertEqual(store.categoryID, 8)
        picker.beginNewCategory(); picker.newName = "  新科目  "
        XCTAssertTrue(picker.createCategory()); XCTAssertEqual(store.categoryID, 55)
        XCTAssertEqual(categories.writes.first?.0, "新科目"); XCTAssertEqual(categories.writes.first?.1, "#be8568")
        XCTAssertEqual(picker.values.first?.id, 55); XCTAssertFalse(picker.newCategoryPresented)
        store.cancel()
    }
    // 产品保证：科目读取失败保留旧列表和选择，写入失败保留科目名并允许重试。
    func testCategoryFailuresPreserveSelectionListAndDraft() {
        let (store, _, _, categories, _) = editor(); XCTAssertTrue(store.begin(id: 12))
        let picker = store.categories; let old = picker.values; categories.readError = failure("读取失败")
        picker.reload(); XCTAssertEqual(picker.values, old); XCTAssertEqual(store.categoryID, 8); XCTAssertEqual(picker.errorMessage, "读取失败")
        categories.readError = nil; picker.reload(); XCTAssertEqual(picker.errorMessage, "")
        picker.beginNewCategory(); picker.newName = "失败的科目"; categories.writeError = failure("新增失败")
        XCTAssertFalse(picker.createCategory()); XCTAssertEqual(picker.newName, "失败的科目"); XCTAssertTrue(picker.newCategoryPresented)
        XCTAssertEqual(store.categoryID, 8); XCTAssertEqual(picker.errorMessage, "新增失败"); store.cancel()
    }
    // 产品保证：完成记录从最新任务预填，保存和撤销沿用共用 TaskActions，撤销只改完成态。
    func testCompletionNoteAndUndoUseSharedActions() {
        let (store, tasks, interactions, shell) = completion(); XCTAssertTrue(store.begin(id: 12))
        XCTAssertEqual(store.note, "上次记录"); XCTAssertEqual(store.task?.title, "最新标题"); XCTAssertTrue(interactions.refreshBlocked)
        store.note = "这次完成"; XCTAssertTrue(store.save()); XCTAssertEqual(tasks.calls.first?.name, "complete")
        XCTAssertEqual(tasks.calls.first?.text, ["这次完成"]); XCTAssertFalse(interactions.refreshBlocked)
        shell.triggerToastAction(); XCTAssertEqual(tasks.calls.last?.name, "setCompleted"); XCTAssertEqual(tasks.calls.last?.numbers, [0])
    }
    // 产品保证：完成失败不清输入、不关表单、不释放令牌，取消才解除冻结。
    func testCompletionFailureAndCancelPreserveDraftWithoutFalseSuccess() {
        let (store, tasks, interactions, _) = completion(); XCTAssertTrue(store.begin(id: 12))
        store.note = "完成草稿"; tasks.error = failure("完成失败原文")
        XCTAssertFalse(store.save()); XCTAssertEqual(store.note, "完成草稿"); XCTAssertEqual(store.errorMessage, "完成失败原文")
        XCTAssertTrue(store.active); XCTAssertTrue(interactions.refreshBlocked)
        let writes = tasks.calls.count; store.cancel(); XCTAssertFalse(interactions.refreshBlocked); XCTAssertEqual(tasks.calls.count, writes)
    }
    // 产品保证：恢复备份的阻断状态会拦住详情与完成表单写入，并保留当前草稿。
    func testRestoreBlocksFormWritesAndOpening() {
        let bridge = ShellBridgeFake(); let shell = ShellStore(bridge: bridge); let tasks = TaskBridgeFake()
        let interactions = InteractionBridgeFake(); interactions.latest = task(); let categories = TaskFormCategoryFake()
        categories.values = [category(8)]; let editor = TaskEditorStore(tasks: tasks, interactions: interactions, categories: categories, shell: shell)
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        let note = TaskCompletionNoteStore(interactions: interactions, actions: TaskActions(tasks: tasks, pendingDeletion: pending, shell: shell), shell: shell)
        XCTAssertTrue(editor.begin(id: 12)); editor.title = "保留标题"
        bridge.snapshot.operationBlocksUI = true; shell.refresh()
        XCTAssertFalse(editor.save()); XCTAssertEqual(editor.title, "保留标题"); XCTAssertTrue(tasks.calls.isEmpty)
        XCTAssertFalse(note.begin(id: 12)); editor.cancel()
        bridge.snapshot.operationBlocksUI = false; shell.refresh(); XCTAssertTrue(note.begin(id: 12))
        bridge.snapshot.operationBlocksUI = true; shell.refresh(); XCTAssertFalse(note.save()); XCTAssertTrue(tasks.calls.isEmpty); note.cancel()
    }
    // 产品保证：科目已经创建成功但刷新读取失败时保留真实选择编号、旧列表和重试错误。
    func testCreatedCategoryKeepsReadFailureVisible() {
        let (store, _, _, categories, _) = editor(); XCTAssertTrue(store.begin(id: 12))
        let picker = store.categories; let oldValues = picker.values
        picker.beginNewCategory(); picker.newName = "已创建科目"
        categories.readError = failure("创建后的读取失败")
        XCTAssertTrue(picker.createCategory()); XCTAssertEqual(picker.selectedID, categories.createdID)
        XCTAssertEqual(picker.values, oldValues); XCTAssertEqual(picker.errorMessage, "创建后的读取失败")
        XCTAssertFalse(picker.newCategoryPresented)
        categories.readError = nil; picker.reload()
        XCTAssertEqual(picker.selectedID, categories.createdID); XCTAssertEqual(picker.errorMessage, "")
        XCTAssertTrue(picker.values.contains { $0.id == categories.createdID }); store.cancel()
    }

    // 产品保证：打开时科目已不在下拉里，只改标题不会把旧科目写成未分类。
    func testMissingCategoryAtOpenIsNotRewritten() {
        let (store, tasks, interactions, _, _) = editor(); interactions.latest.categoryID = 99
        XCTAssertTrue(store.begin(id: 12)); XCTAssertEqual(store.categoryID, -1)
        store.title = "改标题"; XCTAssertTrue(store.save())
        var expected = TaskChanges(); expected.title = "改标题"
        XCTAssertEqual(tasks.changes.first?.1, expected)
    }
    // 产品保证：详情表单仅在文本改过时交规范化输入，首尾空白去除而中间换行保留。
    func testChangedTextIsTrimmedWithoutOverwritingUntouchedFields() {
        let (store, tasks, _, _, _) = editor(completed: true); XCTAssertTrue(store.begin(id: 12))
        store.notes = "  准备一\n准备二  "; store.completionNote = "  完成一\n完成二  "
        XCTAssertTrue(store.save()); XCTAssertEqual(tasks.changes.first?.1.notes, "准备一\n准备二")
        XCTAssertEqual(tasks.changes.first?.1.completionNote, "完成一\n完成二"); XCTAssertNil(tasks.changes.first?.1.title)
    }
    // 产品保证：完成记录去掉首尾空白但保留段落，空记录也可完成，成功后重复提交不再写。
    func testCompletionTrimsNoteAllowsEmptyAndPreventsSecondWrite() {
        let (store, tasks, _, shell) = completion(); XCTAssertTrue(store.begin(id: 12))
        store.note = "  完成一\n完成二  "; XCTAssertTrue(store.save())
        XCTAssertEqual(tasks.calls.first?.text, ["完成一\n完成二"])
        let count = tasks.calls.count; XCTAssertFalse(store.save()); XCTAssertEqual(tasks.calls.count, count)
        shell.retireToast(); XCTAssertTrue(store.begin(id: 12)); store.note = "  "
        XCTAssertTrue(store.save()); XCTAssertEqual(tasks.calls.last?.text, [""])
    }

}
