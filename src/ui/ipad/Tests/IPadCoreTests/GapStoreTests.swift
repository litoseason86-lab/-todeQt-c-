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
        let s = GapStore(bridge: b, logicalDay: day); s.refresh()
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
}
