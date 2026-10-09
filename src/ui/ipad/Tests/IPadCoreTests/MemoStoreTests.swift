import XCTest
@testable import IPadCore

@MainActor final class MemoStoreTests: XCTestCase {
    private func memo(_ id: Int, category: Int = 0, title: String = "", body: String = "") -> MemoValue {
        var v = MemoValue(); v.id = id; v.categoryID = category; v.title = title; v.body = body; return v
    }
    private func subject(_ id: Int) -> CategoryValue { var v = CategoryValue(); v.id = id; v.name = "科目\(id)"; return v }
    private func setup() -> (MemoStore, MemoFake, CategoryBridgeFake) {
        let b = MemoFake(); b.rows = [memo(2, category: 1, title: "二"), memo(5, category: 1, body: "五"), memo(8, category: 2, title: "八")]
        let c = CategoryBridgeFake(); c.result = [subject(2), subject(1), subject(3)]
        let s = MemoStore(bridge: b, categories: c); s.setActive(true); return (s, b, c)
    }
    private let failure = NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "写入失败"])
    // 产品保证：分类只来自已使用科目，保持科目顺序；分组列表保持服务顺序。
    func testUsedCategoriesAndGroups() {
        let (s, _, _) = setup(); XCTAssertEqual(s.categoryFilters, [-1, 2, 1]); XCTAssertEqual(s.unusedCategories.map(\.id), [3]); XCTAssertEqual(s.rows(categoryID: 1).map(\.id), [2, 5])
        XCTAssertEqual(s.moveCategoryIDs, [0, 2, 1]); XCTAssertEqual(s.newCategoryColor, "#b37562"); XCTAssertTrue(s.selectFilter(1)); XCTAssertEqual(s.visibleItems.map(\.id), [2, 5])
    }
    // 产品保证：新建当场写库、选中新编号，默认分类跟随筛选且连点产生独立记录。
    func testImmediateCreationDefaultsAndRepeatedNew() {
        let (s, b, _) = setup(); XCTAssertTrue(s.selectFilter(1)); XCTAssertTrue(s.createNew()); let first = s.selectedID
        XCTAssertEqual(b.creates.last?.2, 1); XCTAssertEqual(s.editorTitle, ""); XCTAssertFalse(s.dirty)
        XCTAssertTrue(s.createNew()); XCTAssertNotEqual(s.selectedID, first); XCTAssertEqual(b.creates.count, 2)
        XCTAssertTrue(s.selectFilter(-1)); XCTAssertTrue(s.createNew()); XCTAssertEqual(b.creates.last?.2, 0)
        s.setActive(false); s.setActive(true); XCTAssertTrue(b.rows.contains { $0.id == s.selectedID })
    }
    // 产品保证：新建前先保存；保存失败不新建，新建失败不改选中、筛选或输入。
    func testNewSavesFirstAndFailuresKeepSelection() {
        let (s, b, _) = setup(); s.editBody("修改"); XCTAssertTrue(s.createNew()); XCTAssertLessThan(b.calls.firstIndex(of: "update")!, b.calls.firstIndex(of: "create")!)
        let selected = s.selectedID; s.editBody("留下"); b.writeError = failure
        XCTAssertFalse(s.createNew()); XCTAssertEqual(s.selectedID, selected); XCTAssertEqual(s.editorBody, "留下"); XCTAssertEqual(b.creates.count, 1)
    }
    // 产品保证：新建后的重读失败保留新空编辑会话及重试，不能把上一条正文写入新编号。
    func testNewReadFailureKeepsNewEditorAndRetry() {
        let (s, b, _) = setup(); let old = s.selectedID; b.failReadAfterCreate = true; XCTAssertTrue(s.createNew())
        XCTAssertNotEqual(s.selectedID, old); XCTAssertEqual(s.editorBody, ""); XCTAssertFalse(s.readFailure.isEmpty); XCTAssertTrue(s.errorFromRead)
        b.readError = nil; s.refresh(); XCTAssertTrue(s.errorMessage.isEmpty)
    }
    // 产品保证：一秒防抖只存最后一次输入，字段级保存不发未改标题或分类。
    func testOneSecondDebounceAndPartialChanges() async throws {
        let (s, b, _) = setup(); s.editBody("第一版")
        try await Task.sleep(for: .milliseconds(550)); XCTAssertTrue(b.updates.isEmpty)
        s.editBody("最后版"); try await Task.sleep(for: .milliseconds(550)); XCTAssertTrue(b.updates.isEmpty)
        try await Task.sleep(for: .milliseconds(650)); XCTAssertEqual(b.updates.count, 1); XCTAssertEqual(b.updates[0].1, MemoChanges(body: "最后版")); XCTAssertFalse(s.dirty)
    }
    // 产品保证：只看不写、编辑后回到原文不写，正文 NBSP 原样保留，不套 Qt 的规范化。
    func testViewingAndUnchangedTextDoesNotWrite() {
        let (s, b, _) = setup(); let initial = s.editorBody; XCTAssertTrue(s.flush()); s.editBody("中\u{00a0}文"); s.editBody(initial); XCTAssertTrue(s.flush()); XCTAssertTrue(b.updates.isEmpty)
        b.rows[0].body = "\u{00a0}"; s.refresh(); XCTAssertEqual(s.editorBody, "\u{00a0}"); XCTAssertTrue(s.flush()); XCTAssertTrue(b.updates.isEmpty)
    }
    // 产品保证：切换条目、筛选、回列表前同步保存；失败拦住切换，正文不丢。
    func testSwitchFilterAndBackSaveOrBlock() {
        let (s, b, _) = setup(); s.editBody("要保存"); XCTAssertTrue(s.selectMemo(5)); XCTAssertEqual(b.updates.count, 1)
        s.editBody("存不上"); b.writeError = failure; XCTAssertFalse(s.selectMemo(8)); XCTAssertFalse(s.selectFilter(2)); XCTAssertFalse(s.leaveDetail()); XCTAssertEqual(s.selectedID, 5); XCTAssertEqual(s.editorBody, "存不上")
    }
    // 产品保证：切页不拦导航但保留失败草稿，后台和退出由外壳同步保存。
    func testPageSwitchAndShellFlushPreserveDraft() {
        let b = MemoFake(); b.rows = [memo(1)]; let shell = ShellStore(bridge: ShellBridgeFake()); let s = MemoStore(bridge: b, categories: CategoryBridgeFake(), shell: shell)
        s.setActive(true); s.editBody("切页草稿"); b.writeError = failure; s.setActive(false); XCTAssertEqual(s.editorBody, "切页草稿"); XCTAssertTrue(s.dirty)
        s.setActive(true); XCTAssertEqual(s.editorBody, "切页草稿"); b.writeError = nil; shell.flushEdits(); XCTAssertEqual(b.updates.last?.1.body, "切页草稿"); XCTAssertFalse(s.dirty)
    }
    // 产品保证：组合中的文字不进入保存，选字上屏后重新启动一秒保存。
    func testCompositionNeverSavesHalfText() async throws {
        let (s, b, _) = setup(); s.editBody("已上屏"); s.setBodyComposing(true)
        try await Task.sleep(for: .milliseconds(1150)); XCTAssertTrue(b.updates.isEmpty); XCTAssertFalse(s.flush())
        s.setBodyComposing(false); s.editBody("选字完成"); try await Task.sleep(for: .milliseconds(1150)); XCTAssertEqual(b.updates.last?.1.body, "选字完成")
    }
    // 产品保证：标题组合也不保存或切换，标题上屏后可保存完整内容。
    func testTitleCompositionBlocksSwitch() {
        let (s, b, _) = setup(); s.setTitleComposing(true); XCTAssertFalse(s.selectMemo(5)); XCTAssertTrue(b.updates.isEmpty)
        s.setTitleComposing(false); s.editTitle("中文标题"); XCTAssertTrue(s.selectMemo(5)); XCTAssertEqual(b.updates.last?.1.title, "中文标题")
    }
    // 产品保证：远端修改替换干净会话，未保存本机修改受保护。
    func testRemoteRefreshProtectsDirtyEditor() {
        let (s, b, _) = setup(); b.rows[0].body = "远端"; b.onChanged?(); XCTAssertEqual(s.editorBody, "远端")
        s.editBody("本机"); b.rows[0].body = "更新的远端"; b.onChanged?(); XCTAssertEqual(s.editorBody, "本机"); XCTAssertTrue(s.dirty)
    }
    // 产品保证：远端删除干净会话选邻项，最后一条科目消失后筛选回全部。
    func testRemoteDeleteCleanAndFilterReset() {
        let (s, b, _) = setup(); XCTAssertTrue(s.selectFilter(2)); XCTAssertEqual(s.selectedID, 8)
        b.rows.removeAll { $0.id == 8 }; b.onChanged?(); XCTAssertEqual(s.filterCategoryID, -1); XCTAssertEqual(s.selectedID, 5); XCTAssertFalse(s.remoteDeleted)
    }
    // 产品保证：远端删除脏会话保留文字；明确放弃后选择邻项且不写库。
    func testRemoteDeleteDirtyAndDiscard() {
        let (s, b, _) = setup(); XCTAssertTrue(s.selectMemo(5)); s.editBody("草稿")
        b.rows.removeAll { $0.id == 5 }; b.onChanged?(); XCTAssertTrue(s.remoteDeleted); XCTAssertEqual(s.editorBody, "草稿"); XCTAssertFalse(s.flush()); XCTAssertNil(s.pendingDelete)
        s.discardDeleted(); XCTAssertEqual(s.selectedID, 8); XCTAssertTrue(b.updates.isEmpty); XCTAssertTrue(b.creates.isEmpty)
    }
    // 产品保证：远端删除后另存生成新身份；科目也删了则归未分类，失败时保留两个出口。
    func testDeletedMemoAndCategorySaveAsNewOrFail() {
        let (s, b, c) = setup(); s.editBody("保留内容"); b.rows.removeAll { $0.id == 2 }; c.result.removeAll { $0.id == 1 }; s.refresh()
        XCTAssertTrue(s.remoteDeleted); XCTAssertEqual(s.editorCategoryID, 0)
        b.writeError = failure; XCTAssertFalse(s.saveDeletedAsNew()); XCTAssertTrue(s.remoteDeleted); XCTAssertEqual(s.editorBody, "保留内容")
        b.writeError = nil; XCTAssertTrue(s.saveDeletedAsNew()); XCTAssertFalse(s.remoteDeleted); XCTAssertNotEqual(s.selectedID, 2); XCTAssertEqual(b.creates.last?.2, 0)
    }
    // 产品保证：读取失败不当成空列表或科目被删，保留草稿和旧分类；成功重读只清读错误。
    func testReadFailuresKeepEditorAndCategories() {
        let (s, b, c) = setup(); s.editBody("草稿"); c.error = failure; s.refresh(); XCTAssertEqual(s.editorCategoryID, 1); XCTAssertEqual(s.items.count, 3); XCTAssertTrue(s.errorFromRead)
        c.error = nil; b.readError = failure; s.refresh(); XCTAssertEqual(s.editorBody, "草稿"); b.readError = nil; s.refresh(); XCTAssertTrue(s.errorMessage.isEmpty)
        b.writeError = failure; XCTAssertFalse(s.flush()); b.writeError = nil; s.refresh(); XCTAssertEqual(s.errorMessage, "写入失败"); XCTAssertFalse(s.errorFromRead)
    }
    // 产品保证：初次读取失败提供重试，真实空库没有编辑器和说明状态。
    func testInitialFailureVersusEmptyLibrary() {
        let b = MemoFake(); b.readError = failure; let s = MemoStore(bridge: b, categories: CategoryBridgeFake()); s.setActive(true)
        XCTAssertTrue(s.errorFromRead); XCTAssertNil(s.selectedID); b.readError = nil; s.refresh(); XCTAssertTrue(s.errorMessage.isEmpty); XCTAssertNil(s.selectedID); XCTAssertTrue(s.items.isEmpty)
    }
    // 产品保证：删除只删确认时的编号，远端删掉目标后不能误删自动选中的邻项。
    func testDeleteConfirmationNeverDeletesNeighbor() {
        let (s, b, _) = setup(); s.requestDelete(); XCTAssertEqual(s.pendingDelete?.id, 2); XCTAssertTrue(b.deletes.isEmpty)
        b.rows.removeAll { $0.id == 2 }; s.refresh(); XCTAssertNil(s.pendingDelete); s.confirmDelete(); XCTAssertTrue(b.deletes.isEmpty)
        s.requestDelete(); let id = s.selectedID; s.confirmDelete(); XCTAssertEqual(b.deletes, [id!])
    }
    // 产品保证：空新备忘离开仍在，删除也要确认；写失败保留未保存输入。
    func testEmptyNewDeleteAndFailedDelete() {
        let (s, b, _) = setup(); XCTAssertTrue(s.createNew()); let id = s.selectedID!; s.setActive(false); XCTAssertTrue(b.rows.contains { $0.id == id }); s.setActive(true)
        s.requestDelete(); s.cancelDelete(); XCTAssertTrue(b.deletes.isEmpty)
        s.editBody("留下"); b.writeError = failure; s.requestDelete(); s.confirmDelete(); XCTAssertEqual(s.editorBody, "留下"); XCTAssertTrue(s.dirty)
    }
    // 产品保证：拖动只在同科目内发完整编号集合，远端刷新取消旧拖动，不覆盖新顺序。
    func testDragFullListRejectsCrossCategoryAndRefreshCancels() {
        let (s, b, _) = setup(); XCTAssertTrue(s.beginDrag(2)); XCTAssertFalse(s.drop(before: 8)); XCTAssertTrue(b.orders.isEmpty)
        XCTAssertTrue(s.beginDrag(2)); XCTAssertTrue(s.drop(before: 5)); XCTAssertEqual(b.orders.last?.1, [5, 2])
        XCTAssertTrue(s.beginDrag(2)); b.onChanged?(); XCTAssertNil(s.draggingID); XCTAssertFalse(s.drop(before: 5)); XCTAssertEqual(b.orders.count, 1)
    }
    // 产品保证：改分类选中目标后立刻保存，只交分类；目标消失或保存失败不移动邻项。
    func testMoveCategoryTracksTargetAndSavesImmediately() {
        let (s, b, _) = setup(); XCTAssertTrue(s.moveCategory(id: 5, to: 2)); XCTAssertEqual(b.updates.last?.0, 5); XCTAssertEqual(b.updates.last?.1, MemoChanges(categoryID: 2))
        XCTAssertFalse(s.moveCategory(id: 999, to: 1)); XCTAssertEqual(b.updates.count, 1)
    }
    // 产品保证：新分类从未使用科目挑选或建科目并立即建空备忘，不在改分类菜单新建。
    func testNewCategoryCreatesMemoAndResetsFilter() {
        let (s, b, c) = setup(); XCTAssertTrue(s.selectFilter(1)); XCTAssertTrue(s.createNew(categoryID: 3)); XCTAssertEqual(s.filterCategoryID, -1); XCTAssertEqual(b.creates.last?.2, 3)
        c.createdID = 7; XCTAssertTrue(s.createCategory(name: "新科目", color: "#123456")); XCTAssertEqual(b.creates.last?.2, 7)
    }
    // 产品保证：长正文与标题用 UTF-16 现有口径拒绝保存，内容留在框中；不私自修字形计数。
    func testUTF16LimitsAndLongTextRetention() {
        let (s, b, _) = setup(); let long = String(repeating: "🍅", count: 5001); s.editBody(long); XCTAssertFalse(s.flush()); XCTAssertEqual(s.editorBody, long); XCTAssertTrue(b.updates.isEmpty)
        s.editBody(""); s.editTitle(String(repeating: "🍅", count: 31)); XCTAssertFalse(s.flush()); XCTAssertTrue(b.updates.isEmpty)
        s.editTitle(String(repeating: "🍅", count: 30)); XCTAssertTrue(s.flush()); XCTAssertEqual(b.updates.count, 1)
    }
    // 产品保证：长段落和撤销文字原样保存，纯文本不吞换行或解析富文本。
    func testParagraphsAndUndoTextRemainPlain() {
        let (s, b, _) = setup(); let text = String(repeating: "<b>纯文本</b>\n", count: 100); s.editBody(text); XCTAssertTrue(s.flush()); XCTAssertEqual(b.updates.last?.1.body, text)
    }
    // 产品保证：重新进页刷新时间标签基准，非当前页不展示其它调用的失败。
    func testActivationRefreshesDisplayClockAndIgnoresForeignFailure() {
        let (s, b, _) = setup(); let date = Date(timeIntervalSince1970: 123); s.refresh(now: date); XCTAssertEqual(s.displayNow, date)
        s.setActive(false); b.onFailure?("别页失败"); XCTAssertNotEqual(s.errorMessage, "别页失败")
    }
    // 产品保证：新建本身失败时筛选、选中、编辑内容保持原样，不把失败当作已创建。
    func testCreateFailureKeepsFilterAndCleanSelection() {
        let (s, b, _) = setup(); XCTAssertTrue(s.selectFilter(2)); XCTAssertFalse(s.dirty)
        let selected = s.selectedID, body = s.editorBody, title = s.editorTitle
        b.writeError = failure; XCTAssertFalse(s.createNew(categoryID: 3))
        XCTAssertEqual(s.filterCategoryID, 2); XCTAssertEqual(s.selectedID, selected)
        XCTAssertEqual(s.editorBody, body); XCTAssertEqual(s.editorTitle, title); XCTAssertEqual(s.items.count, 3)
        XCTAssertEqual(s.errorMessage, "写入失败")
    }
    // 产品保证：超长正文拦住新建、筛选与切换，拒绝写入前保留完整输入。
    func testOverLimitBlocksNewAndFilterWithoutWrites() {
        let (s, b, _) = setup(); s.editBody(String(repeating: "甲", count: 10037))
        XCTAssertTrue(s.dirty); XCTAssertFalse(s.createNew()); XCTAssertFalse(s.selectFilter(2))
        XCTAssertTrue(b.creates.isEmpty); XCTAssertTrue(b.updates.isEmpty)
        XCTAssertEqual(s.selectedID, 2); XCTAssertEqual(s.editorBody.utf16.count, 10037)
        XCTAssertEqual(s.errorMessage, "正文超出 37 字，没有保存。")
    }

}
