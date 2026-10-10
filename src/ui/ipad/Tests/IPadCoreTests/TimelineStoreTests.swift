import Foundation
import XCTest
@testable import IPadCore

@MainActor final class TimelineStoreTests: XCTestCase {
    @MainActor private struct Fixture {
        let shell = ShellStore(bridge: ShellBridgeFake())
        let deletion = PendingDeletionBridgeFake()
        let history = FocusHistoryBridgeFake()
        let statistics = StatisticsBridgeFake()
        let pending: PendingDeletionStore
        let store: TimelineStore
        init() {
            pending = PendingDeletionStore(bridge: deletion, tasks: TaskBridgeFake(), shell: shell)
            store = TimelineStore(history: history, statistics: statistics, pendingDeletion: pending,
                                  selection: TimelineDateSelection(date: "2026-10-09", isFuture: false))
        }
    }
    // 产品保证：日期与未来标志只消费服务输入；未来日不能补录，切日重读对应日期。
    func testDateSelectionAndFutureGate() {
        let f = Fixture()
        f.store.selectDate(TimelineDateSelection(date: "2026-10-10", isFuture: true))
        XCTAssertEqual(f.history.calls.last(where: { $0.0 == "dayTimeline" })?.2, ["2026-10-10"])
        XCTAssertFalse(f.store.canAddManualSession)
        XCTAssertFalse(f.store.addManualSession(taskID: -1, startTime: "2026-10-10T08:00:00.000+08:00", durationMinutes: 30))
        XCTAssertFalse(f.history.calls.contains { $0.0 == "addManualSession" })
        f.store.selectDate(TimelineDateSelection(date: "2026-10-08", isFuture: false))
        XCTAssertTrue(f.store.canAddManualSession)
    }
    // 产品保证：汇总数字和时长文案来自服务，不对时间轴条目自行累加或筛统计门槛。
    func testSummaryUsesServiceValues() {
        let f = Fixture(); var row = SessionValue(); row.durationSeconds = 1
        f.history.sessions = [row]; f.history.count = 4321; f.history.formattedDuration = "服务时长"
        f.statistics.day.totalDuration = 8765; f.statistics.day.sessionCount = 31; f.statistics.day.pomodoroCount = 7
        f.store.refresh()
        XCTAssertEqual(f.store.totalSeconds, 4321); XCTAssertEqual(f.store.statistics.totalDuration, 8765)
        XCTAssertEqual(f.store.statistics.sessionCount, 31); XCTAssertEqual(f.store.statistics.pomodoroCount, 7)
        XCTAssertEqual(f.store.formatDuration(999), "服务时长")
        XCTAssertEqual(f.history.calls.last?.1, [999])
    }
    // 产品保证：补录和修改先提交待删项；提交失败则两种保存都不调用历史服务。
    func testPendingCommitFailurePreventsWrites() {
        let f = Fixture(); var row = SessionValue(); row.id = 19
        XCTAssertTrue(f.pending.requestSession(id: 7, isRest: false)); XCTAssertTrue(f.deletion.state.active)
        f.deletion.commitError = NSError(domain: "test", code: 1)
        XCTAssertFalse(f.store.addManualSession(taskID: 3, startTime: "2026-10-09T08:00:00.000+08:00", durationMinutes: 30))
        XCTAssertFalse(f.history.calls.contains { $0.0 == "addManualSession" })
        XCTAssertTrue(f.pending.requestSession(id: 8, isRest: true)); XCTAssertTrue(f.deletion.state.active)
        var draft = SessionEditorDraft(original: row); draft.taskID = 5
        XCTAssertFalse(f.store.updateSession(draft, original: row))
        XCTAssertTrue(f.history.submittedChanges.isEmpty); XCTAssertEqual(f.deletion.calls.filter { $0.name == "commit" }.count, 2)
    }
    // 产品保证：只改归属或类型保留原始秒数和时间；明确不关联任务仍交服务，失败原文保留。
    func testPartialChangesAndClearTaskFailure() {
        let f = Fixture(); var row = SessionValue(); row.id = 19; row.taskID = 5
        row.startTime = "2026-10-09T08:00:05.123+08:00"; row.durationSeconds = 181
        var draft = SessionEditorDraft(original: row); draft.taskID = -1
        f.history.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "NOT NULL 原始服务原因"])
        XCTAssertFalse(f.store.updateSession(draft, original: row))
        let changes = f.history.submittedChanges.last!.2
        XCTAssertEqual(changes.task, SessionTaskChange.none); XCTAssertNil(changes.startTime); XCTAssertNil(changes.durationSeconds)
        XCTAssertEqual(f.store.error, "NOT NULL 原始服务原因"); XCTAssertEqual(draft.taskID, -1)
        f.history.error = nil; draft.taskID = 5; draft.isRest = true
        XCTAssertTrue(f.store.updateSession(draft, original: row))
        XCTAssertEqual(f.history.submittedChanges.last?.2.isRest, true)
        XCTAssertNil(f.history.submittedChanges.last?.2.task)
    }
    // 产品保证：编辑休息记录按原类型寻址；秒数只在用户改动分钟数后提交。
    func testRestAddressingAndDurationEdit() {
        let f = Fixture(); var row = SessionValue(); row.id = 19; row.isRest = true; row.durationSeconds = 181
        var draft = SessionEditorDraft(original: row); draft.isRest = false; draft.taskID = 5
        draft.durationEdited = true; draft.durationMinutes = 3
        XCTAssertTrue(f.store.updateSession(draft, original: row))
        XCTAssertEqual(f.history.submittedChanges.last?.1, true); XCTAssertNil(f.history.submittedChanges.last?.2.durationSeconds)
        draft.durationMinutes = 4; draft.startEdited = true; draft.startTime = "2026-10-09T09:00:00.000+08:00"
        XCTAssertTrue(f.store.updateSession(draft, original: row))
        XCTAssertEqual(f.history.submittedChanges.last?.2.durationSeconds, 240)
        XCTAssertEqual(f.history.submittedChanges.last?.2.startTime, draft.startTime)
    }
    // 产品保证：同号专注和休息分别隐藏；撤销共用槽恢复该行，删除只请求一次。
    func testDeletionKindAndUndo() {
        let f = Fixture(); var focus = SessionValue(); focus.id = 7; focus.taskTitle = "任务"
        var rest = focus; rest.isRest = true
        f.history.sessions = [rest, focus]; f.store.refresh()
        XCTAssertEqual(f.store.visibleSessions.count, 2)
        XCTAssertTrue(f.store.deleteSession(focus)); XCTAssertEqual(f.store.visibleSessions.map(\.isRest), [true])
        XCTAssertEqual(f.deletion.calls.filter { $0.name == "requestSession" }.count, 1)
        f.shell.triggerToastAction(); XCTAssertEqual(f.store.visibleSessions.count, 2)
        XCTAssertTrue(f.store.deleteSession(rest)); XCTAssertEqual(f.store.visibleSessions.map(\.isRest), [false])
    }
    // 产品保证：旧任务归属仍可选，任务候选读取失败保留草稿；同日刷新失败保留整份快照。
    func testOriginalTaskOptionAndReadFailure() throws {
        let f = Fixture(); var row = SessionValue(); row.id = 19; row.taskID = 71; row.taskTitle = "旧任务"
        f.history.sessions = [row]; f.store.refresh()
        let options = try f.store.taskOptions(original: row)
        XCTAssertEqual(options.map(\.taskID), [71])
        f.statistics.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "统计读取失败"])
        f.history.sessions = []; f.history.onChanged?()
        XCTAssertEqual(f.store.sessions.map(\.id), [19]); XCTAssertEqual(f.store.error, "统计读取失败")
        f.statistics.error = nil; f.store.refresh(); XCTAssertTrue(f.store.sessions.isEmpty)
    }
}
