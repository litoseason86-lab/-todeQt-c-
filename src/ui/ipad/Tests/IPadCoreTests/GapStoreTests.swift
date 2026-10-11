import XCTest
@testable import IPadCore

@MainActor final class GapStoreTests: XCTestCase {
    private func row(_ id: Int, status: Int, overdue: Bool = false) -> GapValue {
        var v = GapValue(); v.id = id; v.status = status; v.overdue = overdue; v.overdueDays = 9; v.title = "条目\(id)"; return v
    }
    // 产品保证：三组只看服务状态且保留服务顺序，逾期元信息直接用服务天数。
    func testGroupsPreserveServiceFactsAndOrder() {
        let b = KnowledgeGapFake(); let day = LogicalDayBridgeFake()
        b.rows = [row(8, status: 1, overdue: true), row(3, status: 0), row(2, status: 1), row(6, status: 2, overdue: true)]
        let s = GapStore(bridge: b, logicalDay: day); s.refresh(); XCTAssertEqual(b.filters.first?.0, -2)
        XCTAssertEqual(s.gaps(status: 1).map(\.id), [8, 2]); XCTAssertEqual(s.gaps(status: 2).map(\.id), [6])
        XCTAssertTrue(GapFormat.meta(b.rows[0]).contains("已逾期 9 天"))
    }
    // 产品保证：今天做、排期、解决、重开、新增与删除只走对应接口，删除必须先确认。
    func testActionsAndDeleteConfirmation() {
        let b = KnowledgeGapFake(); let day = LogicalDayBridgeFake(); day.today = "2026-10-09"
        let s = GapStore(bridge: b, logicalDay: day); let gap = row(7, status: 0)
        XCTAssertTrue(s.convert(gap)); XCTAssertEqual(b.dates.last?.1, day.today)
        XCTAssertTrue(s.schedule(ids: [7, 9], date: "2026-10-12")); XCTAssertTrue(s.schedule(gap, date: ""))
        XCTAssertTrue(s.resolve(gap, resolution: "懂了")); XCTAssertTrue(s.reopen(gap))
        XCTAssertTrue(s.add(title: "新", categoryID: 0, detail: "", priority: 1, dueDate: ""))
        s.requestDelete(gap); XCTAssertFalse(b.calls.contains("delete")); s.cancelDelete(); s.confirmDelete(); XCTAssertFalse(b.calls.contains("delete"))
        s.requestDelete(gap); s.confirmDelete(); XCTAssertEqual(b.calls.filter { $0 == "delete" }.count, 1)
    }
    // 产品保证：失败原文保留，转任务被服务拒绝时不改变现有列表与选择。
    func testFailureAndLinkedTaskRejection() {
        let b = KnowledgeGapFake(); b.rows = [row(4, status: 1)]; let s = GapStore(bridge: b, logicalDay: LogicalDayBridgeFake()); s.refresh(); s.selectedID = 4
        b.error = NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "已有未完成关联任务"])
        XCTAssertFalse(s.convert(b.rows[0])); XCTAssertEqual(s.errorMessage, "已有未完成关联任务"); XCTAssertEqual(s.selectedID, 4)
        s.refresh(); XCTAssertEqual(s.items.map(\.id), [4]); XCTAssertFalse(s.errorMessage.isEmpty)
    }
    // 产品保证：编辑只交实际改过字段，无变化不写；搜索与日界变化重读，不在 Swift 算今天。
    func testPartialChangesFiltersAndDayRefresh() {
        let b = KnowledgeGapFake(); let d = LogicalDayBridgeFake(); let s = GapStore(bridge: b, logicalDay: d); let old = row(3, status: 0)
        var edited = old; edited.title = "变更"; XCTAssertTrue(s.update(opened: old, edited: edited)); XCTAssertEqual(b.updates.last?.1, GapChanges(title: "变更"))
        XCTAssertTrue(s.update(opened: old, edited: old)); XCTAssertEqual(b.updates.count, 1)
        s.statusFilter = 2; s.search = "关键词"; s.refresh(); XCTAssertEqual(b.filters.last?.0, 2); XCTAssertEqual(b.filters.last?.2, "关键词")
        s.setActive(true); let n = b.calls.count; s.logicalDayChanged(); XCTAssertGreaterThan(b.calls.count, n)
        s.setActive(false); b.onFailure?("别页错误"); XCTAssertNotEqual(s.errorMessage, "别页错误")
    }
    // 产品保证：关联任务完成只刷新服务事实，界面不会自动解决知识缺口。
    func testCompletedLinkedTaskDoesNotAutoResolve() {
        let b = KnowledgeGapFake(); b.rows = [row(6, status: 1)]
        let s = GapStore(bridge: b, logicalDay: LogicalDayBridgeFake()); s.setActive(true)
        b.rows[0].linkedTaskCompleted = true; b.onChanged?()
        XCTAssertTrue(s.items[0].linkedTaskCompleted); XCTAssertEqual(s.items[0].status, 1)
        XCTAssertFalse(b.calls.contains("resolve"))
    }

    // 产品保证：筛选或同步移走当前条目时收起详情；读取失败继续保留原条目和详情。
    func testSelectionClosesOnlyAfterSuccessfulResultDropsRow() {
        let bridge = KnowledgeGapFake(); bridge.rows = [row(7, status: 0), row(3, status: 0)]
        let store = GapStore(bridge: bridge, logicalDay: LogicalDayBridgeFake()); store.refresh()
        store.select(7); XCTAssertEqual(store.selectedID, 7); XCTAssertTrue(store.detailPresented)
        bridge.rows = [row(3, status: 2)]
        bridge.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])
        store.statusFilter = 2; store.refresh()
        XCTAssertEqual(store.selectedID, 7); XCTAssertTrue(store.detailPresented)
        bridge.error = nil; store.refresh()
        XCTAssertNil(store.selectedID); XCTAssertFalse(store.detailPresented)
        store.select(99); XCTAssertNil(store.selectedID); XCTAssertFalse(store.detailPresented)
    }

    // 产品保证：编辑意图固定打开时的条目，切换选择和同步改名不把草稿移到另一条记录。
    func testFormKeepsOpenedSnapshotAcrossSelectionAndRefresh() {
        let bridge = KnowledgeGapFake(); bridge.rows = [row(7, status: 0), row(3, status: 0)]
        let store = GapStore(bridge: bridge, logicalDay: LogicalDayBridgeFake()); store.refresh()
        let opened = bridge.rows[0]
        store.requestForm(.edit(opened)); XCTAssertEqual(store.form?.gap, opened)
        store.select(3); bridge.rows[0].title = "远端改名"; store.refresh()
        XCTAssertEqual(store.selectedID, 3); XCTAssertEqual(store.form?.gap, opened)
        store.dismissForm(); XCTAssertNil(store.form)
        store.closeDetail(); XCTAssertFalse(store.detailPresented); XCTAssertEqual(store.selectedID, 3)
        XCTAssertFalse(bridge.calls.contains("update"))
    }

    // 产品保证：从全局搜索跳到某条缺口时，清掉页内旧搜索词、状态筛选切到它所在的一类，
    // 重读后它在结果里、被选中并推入详情（窄窗显示详情）；页面随后激活重读也不会把选中清掉。
    func testRevealClearsPageSearchAndOpensDetail() {
        let bridge = KnowledgeGapFake(); bridge.rows = [row(4, status: 0), row(9, status: 2)]
        let store = GapStore(bridge: bridge, logicalDay: LogicalDayBridgeFake())
        store.search = "高数"; store.statusFilter = -2
        XCTAssertNil(store.selectedID); XCTAssertFalse(store.detailPresented)
        store.reveal(row(9, status: 2))
        XCTAssertEqual(store.search, "")
        XCTAssertEqual(bridge.filters.last?.0, 2); XCTAssertEqual(bridge.filters.last?.2, "")
        XCTAssertEqual(store.selectedID, 9); XCTAssertTrue(store.detailPresented)
        store.setActive(true)
        XCTAssertEqual(store.selectedID, 9); XCTAssertTrue(store.detailPresented)
        // 未解决的跳回未解决筛选。
        store.reveal(row(4, status: 0))
        XCTAssertEqual(store.statusFilter, -2); XCTAssertEqual(store.selectedID, 4)
    }
}
