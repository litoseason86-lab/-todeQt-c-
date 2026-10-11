import Foundation
import XCTest
@testable import IPadCore

@MainActor final class SearchStoreTests: XCTestCase {
    private func task(_ id: Int, _ title: String) -> TaskValue { var value = TaskValue(); value.id = id; value.title = title; return value }
    private func gap(_ id: Int, _ title: String) -> GapValue { var value = GapValue(); value.id = id; value.title = title; return value }

    // 产品保证：侧栏搜索同时查任务和知识缺口，两边都交给服务现成的搜索，任务取全部状态、最多 50 条，缺口取全部状态。
    func testSearchQueriesTasksAndGapsWithServiceFilters() {
        let tasks = TaskBridgeFake(), gaps = KnowledgeGapFake()
        tasks.result = [task(3, "线代 第 4 讲"), task(9, "线代 第 3 讲")]
        gaps.rows = [gap(5, "线代 特征值")]
        let store = SearchStore(tasks: tasks, gaps: gaps)
        store.query = "  线代 "
        store.search()
        XCTAssertEqual(tasks.calls.last?.name, "search")
        XCTAssertEqual(tasks.calls.last?.text, ["线代"])
        XCTAssertEqual(tasks.calls.last?.numbers, [-1, 50])
        XCTAssertEqual(gaps.filters.last?.0, -1)
        XCTAssertEqual(gaps.filters.last?.2, "线代")
        // 结果顺序原样来自服务，界面不重排。
        XCTAssertEqual(store.tasks.map(\.id), [3, 9])
        XCTAssertEqual(store.gaps.map(\.id), [5])
        XCTAssertTrue(store.searched)
    }

    // 产品保证：空白查询不打扰服务，并清掉上一次的结果。
    func testBlankQueryClearsWithoutCallingService() {
        let tasks = TaskBridgeFake(), gaps = KnowledgeGapFake()
        tasks.result = [task(1, "旧结果")]
        let store = SearchStore(tasks: tasks, gaps: gaps)
        store.query = "旧"; store.search()
        XCTAssertEqual(store.tasks.count, 1)
        let before = tasks.calls.count
        store.query = "   "; store.search()
        XCTAssertEqual(tasks.calls.count, before)
        XCTAssertTrue(store.tasks.isEmpty); XCTAssertTrue(store.gaps.isEmpty); XCTAssertFalse(store.searched)
    }

    // 产品保证：读取失败时保留上一次成功的结果并显示服务给的原因，不把列表清空成「没有结果」。
    func testFailureKeepsPreviousResultsAndShowsReason() {
        let tasks = TaskBridgeFake(), gaps = KnowledgeGapFake()
        tasks.result = [task(1, "高数")]
        let store = SearchStore(tasks: tasks, gaps: gaps)
        store.query = "高"; store.search()
        tasks.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据库忙"])
        store.query = "高数"; store.search()
        XCTAssertEqual(store.tasks.map(\.id), [1])
        XCTAssertEqual(store.errorMessage, "数据库忙")
        tasks.error = nil; store.search()
        XCTAssertEqual(store.errorMessage, "")
    }

    // 产品保证：任务或缺口在别处改动（详情里改名、同步进来）后，已显示的结果按当前查询重读，
    // 改名后不再匹配的条目消失；还没搜索过时变更不触发读取。
    func testDataChangeRerunsCurrentQuery() {
        let tasks = TaskBridgeFake(), gaps = KnowledgeGapFake()
        let store = SearchStore(tasks: tasks, gaps: gaps)
        tasks.onChanged?(); gaps.onChanged?()
        XCTAssertFalse(tasks.calls.contains { $0.name == "search" })
        tasks.result = [task(3, "线代 第 4 讲"), task(9, "线代 第 3 讲")]
        store.query = "线代"; store.search()
        XCTAssertEqual(store.tasks.map(\.id), [3, 9])
        tasks.result = [task(9, "线代 第 3 讲")]
        tasks.onChanged?()
        XCTAssertEqual(store.tasks.map(\.id), [9])
        gaps.rows = [gap(5, "线代 特征值")]
        gaps.onChanged?()
        XCTAssertEqual(store.gaps.map(\.id), [5])
        XCTAssertEqual(tasks.calls.last?.text, ["线代"])
    }

    // 产品保证：科目改名或删除后（任务搜索也匹配科目名，结果行显示科目），已显示的结果按当前查询重读，
    // 不再匹配的任务消失。
    func testCategoryChangeRerunsCurrentQuery() {
        let tasks = TaskBridgeFake(), gaps = KnowledgeGapFake(), categories = CategoryBridgeFake()
        let store = SearchStore(tasks: tasks, gaps: gaps, categories: categories)
        tasks.result = [task(3, "微积分 第 2 章")]
        store.query = "数学"; store.search()
        XCTAssertEqual(store.tasks.map(\.id), [3])
        tasks.result = []
        categories.onChanged?()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(tasks.calls.last?.text, ["数学"])
    }
}
