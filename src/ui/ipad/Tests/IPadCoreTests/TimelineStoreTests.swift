import Foundation
import XCTest
@testable import IPadCore

@MainActor final class TimelineStoreTests: XCTestCase {
    @MainActor private struct Fixture {
        let shell = ShellStore(bridge: ShellBridgeFake())
        let deletion = PendingDeletionBridgeFake()
        let history = FocusHistoryBridgeFake()
        let statistics = StatisticsBridgeFake()
        let logicalDay = LogicalDayBridgeFake()
        let pending: PendingDeletionStore
        let store: TimelineStore
        init() {
            pending = PendingDeletionStore(bridge: deletion, tasks: TaskBridgeFake(), shell: shell)
            logicalDay.today = "2026-10-09"
            logicalDay.relations["2026-10-09/2026-10-09"] = .same
            store = TimelineStore(history: history, statistics: statistics, pendingDeletion: pending,
                                  logicalDay: logicalDay, date: "2026-10-09")
        }
    }
    // 产品保证：休息转为专注时把用户新选的任务交给字段级接口，时间精度仍保持原值。
    func testRestConversionForwardsSelectedTask() {
        let f = Fixture(); var row = SessionValue(); row.id = 7; row.isRest = true
        row.durationSeconds = 301; row.startTime = "2026-10-09T08:00:05.123"
        var draft = SessionEditorDraft(original: row); draft.isRest = false; draft.taskID = 41
        XCTAssertTrue(row.isRest); XCTAssertEqual(row.taskID, -1)
        XCTAssertTrue(f.store.updateSession(draft, original: row))
        XCTAssertEqual(f.history.submittedChanges.last?.1, true)
        XCTAssertEqual(f.history.submittedChanges.last?.2.task, .selected(41))
        XCTAssertNil(f.history.submittedChanges.last?.2.startTime)
        XCTAssertNil(f.history.submittedChanges.last?.2.durationSeconds)
    }
    // 产品保证：补录把表单选择原样交服务，冲突失败保留输入和服务原因，重试成功只新增一次。
    func testManualSubmissionForwardsFieldsAndPreservesConflict() {
        let f = Fixture(); let start = "2026-10-09T09:15:00.123"
        XCTAssertTrue(f.store.canAddManualSession)
        f.history.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "与 09:00–10:00 专注重叠"])
        XCTAssertFalse(f.store.addManualSession(taskID: 41, startTime: start, durationMinutes: 45))
        XCTAssertEqual(f.store.error, "与 09:00–10:00 专注重叠")
        XCTAssertEqual(f.history.calls.last?.1, [41, 45]); XCTAssertEqual(f.history.calls.last?.2, [start])
        f.history.error = nil
        XCTAssertTrue(f.store.addManualSession(taskID: 41, startTime: start, durationMinutes: 45))
        XCTAssertEqual(f.history.calls.filter { $0.0 == "addManualSession" }.count, 2)
    }
    // 产品保证：今日页随日界转到新逻辑今日，用户主动查看历史日期时保持该日期。
    func testDayBoundaryFollowsTodayButRetainsHistorySelection() {
        let f = Fixture()
        f.logicalDay.relations["2026-10-10/2026-10-10"] = .same
        f.logicalDay.today = "2026-10-10"
        XCTAssertEqual(f.store.selectedDate, "2026-10-10")
        f.logicalDay.relations["2026-10-08/2026-10-10"] = .earlier
        f.store.selectDate("2026-10-08")
        f.logicalDay.relations["2026-10-08/2026-10-11"] = .earlier
        f.logicalDay.today = "2026-10-11"
        XCTAssertEqual(f.store.selectedDate, "2026-10-08")
    }
    // 产品保证：导航跨月与闰日仍发有效公历日期，同号专注和休息保持独立列表身份。
    func testDateNavigationAndTimelineIdentity() {
        XCTAssertEqual(LogicalDateNavigation.shifted("2024-03-01", days: -1), "2024-02-29")
        XCTAssertEqual(LogicalDateNavigation.shifted("2026-12-31", days: 1), "2027-01-01")
        XCTAssertNil(LogicalDateNavigation.date("2026-02-30"))
        var focus = SessionValue(); focus.id = 7
        var rest = focus; rest.isRest = true
        XCTAssertNotEqual(focus.timelineID, rest.timelineID)
    }
    // 产品保证：控件发送本地墙钟串、不含时区，毫秒精度可以往返保留。
    func testTimestampEmitsLocalWallClockAndRoundTrips() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let wholeSecond = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8, minute: 0, second: 5)))
        let date = wholeSecond.addingTimeInterval(0.123)
        let text = LogicalDateNavigation.timestamp(date)
        XCTAssertEqual(text, "2026-10-09T08:00:05.123")
        let decoded = try XCTUnwrap(LogicalDateNavigation.timestampDate(text))
        XCTAssertEqual(decoded.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
    // 产品保证：桥接输出的本地时间带毫秒或整秒时，读取均保持本地 08:00。
    func testTimestampParsesLocalWallClockWithAndWithoutMilliseconds() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8, minute: 0, second: 5)))
        for (text, fraction) in [("2026-10-09T08:00:05.123", 0.123), ("2026-10-09T08:00:05", 0.0)] {
            let date = try XCTUnwrap(LogicalDateNavigation.timestampDate(text), text)
            XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970 + fraction, accuracy: 0.001)
        }
    }
    // 产品保证：读入仍兼容带偏移或 Z 的时间串，保持它们指向的绝对时刻。
    func testTimestampStillParsesOffsetAndUTC() throws {
        for (offset, utc) in [("2026-10-09T08:00:05.123+08:00", "2026-10-09T00:00:05.123Z"),
                              ("2026-10-09T08:00:05+08:00", "2026-10-09T00:00:05Z")] {
            let date = try XCTUnwrap(LogicalDateNavigation.timestampDate(offset))
            let expected = try XCTUnwrap(LogicalDateNavigation.timestampDate(utc))
            XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        }
    }
    // 产品保证：时间轴真实桥接数据进入编辑草稿后，预填为记录开始时刻，不回退到 9 点。
    func testRealBridgeTimestampPrefillsRecordStart() throws {
        let f = Fixture(); var row = SessionValue(); row.id = 19
        row.startTime = "2026-10-09T08:00:05.123"; row.endTime = "2026-10-09T08:30:05.123"; row.durationSeconds = 1800
        f.history.sessions = [row]; f.store.refresh()
        let loaded = try XCTUnwrap(f.store.sessions.first)
        let draft = SessionEditorDraft(original: loaded)
        XCTAssertEqual(draft.startTime, row.startTime); XCTAssertFalse(draft.startEdited)
        // 与编辑框相同的解析/回退路径，数据层验证真实时间能进入 DatePicker。
        let prefilled = LogicalDateNavigation.timestampDate(draft.startTime)
            ?? LogicalDateNavigation.initialSessionStart(date: f.store.selectedDate)
        XCTAssertEqual(LogicalDateNavigation.timestamp(prefilled), row.startTime)
        XCTAssertTrue(f.store.updateSession(draft, original: loaded))
        XCTAssertNil(f.history.submittedChanges.last?.2.startTime)
    }
    // 产品保证：日期与未来标志只消费服务输入；未来日不能补录，切日重读对应日期。
    func testDateSelectionAndFutureGate() {
        let f = Fixture()
        f.logicalDay.relations["2026-10-10/2026-10-09"] = .later
        f.store.selectDate("2026-10-10")
        XCTAssertEqual(f.history.calls.last(where: { $0.0 == "dayTimeline" })?.2, ["2026-10-10"])
        XCTAssertFalse(f.store.canAddManualSession)
        XCTAssertFalse(f.store.addManualSession(taskID: -1, startTime: "2026-10-10T08:00:00.000", durationMinutes: 30))
        XCTAssertFalse(f.history.calls.contains { $0.0 == "addManualSession" })
        f.logicalDay.relations["2026-10-08/2026-10-09"] = .earlier
        f.store.selectDate("2026-10-08")
        XCTAssertTrue(f.store.canAddManualSession)
    }
    // 产品保证：历史页的日期意图只消费一次；日后打开今日专注不覆盖手动选择，失败仍显示服务原因。
    func testHistoryNavigationConsumesDateOnceAndPreservesFailure() {
        let f = Fixture()
        f.logicalDay.relations["2026-10-07/2026-10-09"] = .earlier
        f.shell.openFocusHistory(date: "2026-10-07")
        XCTAssertEqual(f.shell.requestedFocusDate, "2026-10-07")
        f.store.selectRequestedDate(from: f.shell)
        XCTAssertEqual(f.store.selectedDate, "2026-10-07")
        XCTAssertNil(f.shell.requestedFocusDate)
        f.store.selectDate("2026-10-09")
        f.store.selectRequestedDate(from: f.shell)
        XCTAssertEqual(f.store.selectedDate, "2026-10-09")
        f.logicalDay.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "历史日期读取失败"])
        f.shell.openFocusHistory(date: "2026-10-06")
        f.store.selectRequestedDate(from: f.shell)
        XCTAssertNil(f.shell.requestedFocusDate)
        XCTAssertEqual(f.store.selectedDate, "2026-10-09")
        XCTAssertEqual(f.store.error, "历史日期读取失败")
    }
    // 产品保证：无效日期关系显示服务错误并保留当前日期，Swift 不回退到本机比较。
    func testRelationFailureKeepsDateAndBlocksAdd() {
        let f = Fixture(); f.logicalDay.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "日期无效"])
        f.store.selectDate("bad-date")
        XCTAssertEqual(f.store.selectedDate, "2026-10-09")
        XCTAssertEqual(f.store.error, "日期无效"); XCTAssertFalse(f.store.canAddManualSession)
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
        XCTAssertFalse(f.store.addManualSession(taskID: 3, startTime: "2026-10-09T08:00:00.000", durationMinutes: 30))
        XCTAssertFalse(f.history.calls.contains { $0.0 == "addManualSession" })
        XCTAssertTrue(f.pending.requestSession(id: 8, isRest: true)); XCTAssertTrue(f.deletion.state.active)
        var draft = SessionEditorDraft(original: row); draft.taskID = 5
        XCTAssertFalse(f.store.updateSession(draft, original: row))
        XCTAssertTrue(f.history.submittedChanges.isEmpty); XCTAssertEqual(f.deletion.calls.filter { $0.name == "commit" }.count, 2)
    }
    // 产品保证：只改归属或类型保留原始秒数和时间；明确不关联任务仍交服务，失败原文保留。
    func testPartialChangesAndClearTaskFailure() {
        let f = Fixture(); var row = SessionValue(); row.id = 19; row.taskID = 5
        row.startTime = "2026-10-09T08:00:05.123"; row.durationSeconds = 181
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
        draft.durationMinutes = 4; draft.startEdited = true; draft.startTime = "2026-10-09T09:00:00.000"
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
