import XCTest
@testable import IPadCore

@MainActor final class WeekStoreTests: XCTestCase {
    private func fixture() -> (TaskBridgeFake, LogicalDayBridgeFake, PendingDeletionStore, WeekStore) {
        let tasks = TaskBridgeFake(); tasks.planned = [20, -1, 35, 0, 10, 0, 5]
        let day = LogicalDayBridgeFake(); day.today = "2026-10-09"
        let shell = ShellStore(bridge: ShellBridgeFake()); let deletion = PendingDeletionBridgeFake(); let pending = PendingDeletionStore(bridge: deletion, tasks: tasks, shell: shell)
        let store = WeekStore(tasks: tasks, logicalDay: day, pendingDeletion: pending, weekStart: "2026-10-05") { start, offset in "2026-10-0\(5 + offset)" }
        return (tasks, day, pending, store)
    }
    // 产品保证：七天分组和「已排」分钟由 C++ 返回，Swift 不自行累加且负值归零只在接口结果投影。
    func testGroupsUseServicePlannedMinutesAndLogicalToday() {
        let (tasks, day, _, store) = fixture()
        XCTAssertEqual(store.groups.map(\.plannedMinutes), [20, 0, 35, 0, 10, 0, 5]); XCTAssertFalse(store.canAdd(on: "2026-10-08")); XCTAssertTrue(store.canAdd(on: "2026-10-09"))
        XCTAssertEqual(tasks.calls.last?.name, "plannedMinutes")
        day.today = "2026-10-10"; day.onChanged?(); XCTAssertEqual(store.logicalToday, "2026-10-10")
    }
    // 产品保证：改期只写一次；拖回原日不写，同日排序走 moveBefore。
    func testMoveAndReorderCalls() {
        let (tasks, _, _, store) = fixture(); var task = TaskValue(); task.id = 7; task.date = "2026-10-06"; var before = task; before.id = 8
        XCTAssertTrue(store.move(task: task, to: "2026-10-07")); XCTAssertEqual(tasks.calls.filter { $0.name == "moveDate" }.count, 1)
        XCTAssertTrue(store.move(task: task, to: task.date)); XCTAssertEqual(tasks.calls.filter { $0.name == "moveDate" }.count, 1)
        XCTAssertTrue(store.reorder(task: task, before: before)); XCTAssertTrue(tasks.calls.contains { $0.name == "moveBefore" })
    }
    // 产品保证：待删任务编号传入 C++ 排除参数；删除槽变化后重新读取整周。
    func testPendingDeletionExclusionAndReadFailure() {
        let (tasks, _, pending, store) = fixture(); XCTAssertEqual(tasks.calls.last?.ids, [-1]); XCTAssertTrue(pending.requestTask(id: 31, title: "删")); store.refresh(); XCTAssertEqual(tasks.calls.last?.ids, [31])
        tasks.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "周读取失败"]); store.refresh(); XCTAssertEqual(store.groups.map(\.plannedMinutes), [20, 0, 35, 0, 10, 0, 5]); XCTAssertEqual(store.error, "周读取失败")
    }
}
