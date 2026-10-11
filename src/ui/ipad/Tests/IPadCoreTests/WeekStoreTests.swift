import XCTest
@testable import IPadCore

@MainActor final class WeekStoreTests: XCTestCase {
    private func fixture() -> (TaskBridgeFake, LogicalDayBridgeFake, PendingDeletionStore, WeekStore) {
        let tasks = TaskBridgeFake(); tasks.planned = [20, -1, 35, 0, 10, 0, 5]
        let day = LogicalDayBridgeFake(); day.today = "2026-10-09"
        day.relations["2026-10-08/2026-10-09"] = .earlier
        day.relations["2026-10-09/2026-10-09"] = .same
        day.relations["2026-10-10/2026-10-09"] = .later
        let shell = ShellStore(bridge: ShellBridgeFake()); let deletion = PendingDeletionBridgeFake(); let pending = PendingDeletionStore(bridge: deletion, tasks: tasks, shell: shell)
        let store = WeekStore(tasks: tasks, logicalDay: day, pendingDeletion: pending, interactions: InteractionBridgeFake(), weekStart: "2026-10-05") { _ in (5...11).map { String(format: "2026-10-%02d", $0) } }
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
    // 产品保证：添加只允许今天及未来日；服务失败保留原因，不报告创建成功。
    func testCreateUsesSelectedDayAndServiceFailure() {
        let (tasks, _, _, store) = fixture()
        XCTAssertFalse(store.addTask(title: "过去", date: "2026-10-08"))
        XCTAssertTrue(store.addTask(title: "今天", date: "2026-10-09"))
        XCTAssertEqual(tasks.calls.first(where: { $0.name == "create" })?.text, ["今天", "2026-10-09", ""])
        tasks.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "创建失败"])
        XCTAssertFalse(store.addTask(title: "失败", date: "2026-10-10")); XCTAssertEqual(store.error, "创建失败")
    }
    // 产品保证：待删任务编号传入 C++ 排除参数；删除槽变化后重新读取整周。
    func testPendingDeletionExclusionAndReadFailure() {
        let (tasks, _, pending, store) = fixture(); XCTAssertEqual(tasks.calls.last?.ids, [-1]); XCTAssertTrue(pending.requestTask(id: 31, title: "删")); store.refresh(); XCTAssertEqual(tasks.calls.last?.ids, [31])
        tasks.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "周读取失败"]); store.refresh(); XCTAssertEqual(store.groups.map(\.plannedMinutes), [20, 0, 35, 0, 10, 0, 5]); XCTAssertEqual(store.error, "周读取失败")
    }
    // 产品保证：逻辑日关系服务失败时过去日默认不可添加，不用字符串排序越权放行。
    func testRelationFailureBlocksPastDay() {
        let (_, day, _, store) = fixture(); day.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "日期无效"])
        XCTAssertFalse(store.canAdd(on: "2026-10-10"))
    }

    // 产品保证：翻周读服务换算出的那一周；翻回本周后重新跟随服务的本周，不停在手动记下的日期上。
    func testShiftWeekReadsServicePeriodAndReturnsToCurrent() {
        let (tasks, day, _, store) = fixture()
        day.periodHandler = { _, _, shift, _ in
            var value = PeriodDates(); value.start = shift > 0 ? "2026-10-12" : "2026-10-05"; return value
        }
        XCTAssertTrue(store.showsCurrentWeek)
        store.shiftWeek(1)
        XCTAssertEqual(day.periodCalls.last?.0, "2026-10-05"); XCTAssertEqual(day.periodCalls.last?.1, "week")
        XCTAssertEqual(tasks.calls.last(where: { $0.name == "plannedMinutes" })?.text.first, "2026-10-12")
        XCTAssertEqual(store.weekStart, "2026-10-12"); XCTAssertFalse(store.showsCurrentWeek)
        store.shiftWeek(-1)
        XCTAssertTrue(store.showsCurrentWeek); XCTAssertEqual(store.weekStart, "2026-10-05")
    }

    // 产品保证：翻到别的周后跨过逻辑周日界（服务的本周前进一周），「本周」标识按显示的周与服务本周是否相同判断，
    // 再点上一周仍移动到前一周；翻回到服务本周后恢复跟随。
    func testShiftWeekAfterServiceWeekAdvances() {
        let tasks = TaskBridgeFake(); tasks.planned = Array(repeating: 0, count: 7)
        let day = LogicalDayBridgeFake(); day.today = "2026-10-09"
        day.periodHandler = { anchor, _, shift, _ in
            var value = PeriodDates(); value.start = LogicalDateNavigation.shifted(anchor, days: 7 * shift) ?? anchor; return value
        }
        var serviceWeek = "2026-10-05"
        let shell = ShellStore(bridge: ShellBridgeFake())
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        let store = WeekStore(tasks: tasks, logicalDay: day, pendingDeletion: pending, interactions: InteractionBridgeFake(),
                              weekStart: "2026-10-05",
                              weekDates: { start in (0..<7).compactMap { LogicalDateNavigation.shifted(start, days: $0) } },
                              weekStartProvider: { serviceWeek })
        store.shiftWeek(1)
        XCTAssertEqual(store.weekStart, "2026-10-12"); XCTAssertFalse(store.showsCurrentWeek)
        // 跨过逻辑周日界：服务的本周变成 10-12，正在显示的就是本周。
        serviceWeek = "2026-10-12"; day.today = "2026-10-12"
        store.refresh()
        XCTAssertEqual(store.weekStart, "2026-10-12"); XCTAssertTrue(store.showsCurrentWeek)
        store.shiftWeek(-1)
        XCTAssertEqual(store.weekStart, "2026-10-05"); XCTAssertFalse(store.showsCurrentWeek)
        store.shiftWeek(1)
        XCTAssertEqual(store.weekStart, "2026-10-12"); XCTAssertTrue(store.showsCurrentWeek)
        // 回到跟随后，下一次周日界自动前进。
        serviceWeek = "2026-10-19"; day.today = "2026-10-19"
        store.refresh()
        XCTAssertEqual(store.weekStart, "2026-10-19"); XCTAssertTrue(store.showsCurrentWeek)
    }

    private func row(_ id: Int, date: String = "2026-10-09", completed: Bool = false) -> TaskValue {
        var value = TaskValue(); value.id = id; value.title = "任务 \(id)"; value.date = date; value.completed = completed
        return value
    }
    private func interactionFixture() -> (TaskBridgeFake, InteractionBridgeFake, LogicalDayBridgeFake, ShellStore, WeekStore, TaskActions) {
        let tasks = TaskBridgeFake(); tasks.result = [row(9), row(4), row(23, date: "2026-10-11")]; tasks.planned = Array(repeating: 0, count: 7)
        let interactions = InteractionBridgeFake(); let day = LogicalDayBridgeFake(); day.today = "2026-10-09"
        day.relations["2026-10-09/2026-10-09"] = .same
        day.relations["2026-10-11/2026-10-09"] = .later
        let shell = ShellStore(bridge: ShellBridgeFake())
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        let store = WeekStore(tasks: tasks, logicalDay: day, pendingDeletion: pending, interactions: interactions,
                              weekStart: "2026-10-05", weekDates: { _ in (5...11).map { String(format: "2026-10-%02d", $0) } })
        return (tasks, interactions, day, shell, store, TaskActions(tasks: tasks, pendingDeletion: pending, shell: shell))
    }
    // 产品保证：拖动期间同步刷新延后，取消零写入；最后一个令牌结束时补一次最新读取。
    func testDragFreezesRefreshAndCancelHasNoWrites() throws {
        let (tasks, interactions, _, _, store, _) = interactionFixture()
        let session = try XCTUnwrap(store.beginDrag(id: 9)); XCTAssertTrue(interactions.refreshBlocked)
        let reads = tasks.calls.filter { $0.name == "weekTasks" }.count
        tasks.result = [row(31)]; tasks.onChanged?(); tasks.onChanged?()
        XCTAssertEqual(store.groups.flatMap(\.tasks).map(\.id), [9, 4, 23])
        XCTAssertEqual(tasks.calls.filter { $0.name == "weekTasks" }.count, reads)
        store.endDrag(session: session)
        XCTAssertFalse(interactions.refreshBlocked)
        XCTAssertEqual(store.groups.flatMap(\.tasks).map(\.id), [31])
        XCTAssertEqual(tasks.calls.filter { $0.name == "weekTasks" }.count, reads + 1)
        XCTAssertFalse(tasks.calls.contains { $0.name == "moveDate" || $0.name == "moveBefore" })
    }
    // 产品保证：放下只写一次，跨日落到目标日末尾，同日走 moveBefore，重复落点和回原日不写。
    func testDropDispatchesOneWriteAndIgnoresDuplicateCallbacks() throws {
        let (tasks, interactions, _, _, store, _) = interactionFixture()
        _ = try XCTUnwrap(store.beginDrag(id: 9))
        XCTAssertTrue(store.drop(taskID: 9, to: "2026-10-11", before: 23))
        XCTAssertFalse(store.drop(taskID: 9, to: "2026-10-11", before: 23))
        XCTAssertEqual(tasks.calls.filter { $0.name == "moveDate" }.count, 1)
        XCTAssertFalse(tasks.calls.contains { $0.name == "moveBefore" }); XCTAssertFalse(interactions.refreshBlocked)
        _ = try XCTUnwrap(store.beginDrag(id: 4))
        XCTAssertTrue(store.drop(taskID: 4, to: "2026-10-09", before: 9))
        XCTAssertEqual(tasks.calls.last(where: { $0.name == "moveBefore" })?.ids, [4, 9])
        _ = try XCTUnwrap(store.beginDrag(id: 9))
        let writes = tasks.calls.filter { $0.name == "moveDate" || $0.name == "moveBefore" }.count
        XCTAssertTrue(store.drop(taskID: 9, to: "2026-10-09"))
        XCTAssertEqual(tasks.calls.filter { $0.name == "moveDate" || $0.name == "moveBefore" }.count, writes)
    }
    // 产品保证：拖放改期失败的服务原文保留，解除冻结后的成功读取不能把失败提示清空。
    func testFailedDropRetainsWriteErrorAfterDeferredRefresh() throws {
        let (tasks, interactions, _, _, store, _) = interactionFixture()
        _ = try XCTUnwrap(store.beginDrag(id: 9))
        XCTAssertTrue(interactions.refreshBlocked)
        tasks.onChanged?()
        let previousChanged = interactions.onChanged
        // 模拟仅写入失败、解除冻结后读取恢复，区分写失败和读取失败两条路径。
        interactions.onChanged = {
            if !interactions.refreshBlocked { tasks.error = nil }
            previousChanged?()
        }
        tasks.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "改期被服务拒绝"])
        let reads = tasks.calls.filter { $0.name == "weekTasks" }.count
        XCTAssertFalse(store.drop(taskID: 9, to: "2026-10-11"))
        XCTAssertFalse(interactions.refreshBlocked)
        XCTAssertEqual(tasks.calls.filter { $0.name == "weekTasks" }.count, reads + 1)
        XCTAssertEqual(store.error, "改期被服务拒绝")
        XCTAssertEqual(store.groups.flatMap(\.tasks).map(\.id), [9, 4, 23])
    }
    // 产品保证：改期菜单从交互令牌读取最新任务，未提交时同步不替换列表，取消不写日期。
    func testRescheduleUsesLatestSnapshotAndReleasesOnCancel() {
        let (tasks, interactions, _, _, store, _) = interactionFixture()
        interactions.latest = row(9, date: "2026-10-10")
        XCTAssertEqual(store.beginReschedule(id: 9)?.date, "2026-10-10")
        XCTAssertTrue(interactions.refreshBlocked)
        tasks.result = [row(31)]; tasks.onChanged?()
        XCTAssertEqual(store.groups.flatMap(\.tasks).map(\.id), [9, 4, 23])
        store.endReschedule(); XCTAssertFalse(interactions.refreshBlocked)
        XCTAssertEqual(store.groups.flatMap(\.tasks).map(\.id), [31])
        XCTAssertFalse(tasks.calls.contains { $0.name == "moveDate" })
    }
    // 产品保证：键盘游标按编号跳过空日、到首尾停止；完成沉底后的刷新仍选同一编号。
    func testKeyboardCursorUsesServiceOrderAcrossEmptyDays() {
        let (tasks, _, _, shell, store, actions) = interactionFixture()
        store.moveCursor(1); XCTAssertEqual(store.cursorTaskID, 9)
        store.moveCursor(1); XCTAssertEqual(store.cursorTaskID, 4)
        XCTAssertTrue(store.toggleCursorCompletion(using: actions))
        XCTAssertEqual(tasks.calls.last(where: { $0.name == "setCompleted" })?.ids, [4])
        tasks.result = [row(9), row(4, completed: true), row(23, date: "2026-10-11")]; tasks.onChanged?()
        XCTAssertEqual(store.cursorTaskID, 4)
        XCTAssertFalse(store.startCursorFocus(using: actions)); XCTAssertEqual(shell.selection, .dashboard)
        store.moveCursor(1); XCTAssertEqual(store.cursorTaskID, 23)
        store.moveCursor(1); XCTAssertEqual(store.cursorTaskID, 23)
        XCTAssertFalse(store.startCursorFocus(using: actions))
        store.moveCursor(-1); store.moveCursor(-1); store.moveCursor(-1); XCTAssertEqual(store.cursorTaskID, 9)
        XCTAssertTrue(store.startCursorFocus(using: actions)); XCTAssertEqual(shell.selection, .focus)
        tasks.result = [row(23, date: "2026-10-11")]; tasks.onChanged?(); XCTAssertEqual(store.cursorTaskID, -1)
    }
    // 产品保证：日界通知同时到达本周和其它页面，不因后订阅者覆盖回调而丢失整周刷新。
    func testIndependentLogicalDayAdaptersRefreshWeekAndOtherReceiver() {
        let (tasks, _, day, _, store, _) = interactionFixture()
        var anotherObserverCalls = 0
        let otherDay = LogicalDayBridgeFake()
        otherDay.onChanged = { anotherObserverCalls += 1 }
        let reads = tasks.calls.filter { $0.name == "weekTasks" }.count
        day.today = "2026-10-10"; otherDay.today = "2026-10-10"
        XCTAssertEqual(anotherObserverCalls, 1)
        XCTAssertEqual(store.logicalToday, "2026-10-10")
        XCTAssertEqual(tasks.calls.filter { $0.name == "weekTasks" }.count, reads + 1)
    }
    // 产品保证：待删槽立即隐藏任务，下一轮读取由服务重算已排；撤销后恢复任务和服务合计。
    func testPendingSlotRefreshesPlannedMinutesAndUndo() async throws {
        let tasks = TaskBridgeFake(); tasks.result = [row(31)]; tasks.planned = [0, 0, 0, 0, 45, 0, 0]
        let shell = ShellStore(bridge: ShellBridgeFake()); let deletion = PendingDeletionBridgeFake()
        let pending = PendingDeletionStore(bridge: deletion, tasks: tasks, shell: shell)
        let store = WeekStore(tasks: tasks, logicalDay: LogicalDayBridgeFake(), pendingDeletion: pending,
                              interactions: InteractionBridgeFake(), weekStart: "2026-10-05",
                              weekDates: { _ in (5...11).map { String(format: "2026-10-%02d", $0) } })
        XCTAssertEqual(store.groups[4].tasks.map(\.id), [31]); XCTAssertEqual(store.groups[4].plannedMinutes, 45)
        tasks.planned[4] = 0; XCTAssertTrue(pending.requestTask(id: 31, title: "任务"))
        XCTAssertTrue(store.groups[4].tasks.isEmpty)
        // 让 Observation 的主队列回读完成，不把 willSet 时序误当作状态已经更新。
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(tasks.calls.last?.ids, [31]); XCTAssertEqual(store.groups[4].plannedMinutes, 0)
        tasks.planned[4] = 45; shell.triggerToastAction()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(store.groups[4].tasks.map(\.id), [31]); XCTAssertEqual(store.groups[4].plannedMinutes, 45)
        XCTAssertEqual(tasks.calls.last?.ids, [-1])
    }
    // 产品保证：跨周日界完全消费服务给的新周一与七天日期；周起点读取失败保留整份快照。
    func testWeekStartProviderFailureRetainsSnapshot() {
        let tasks = TaskBridgeFake(); tasks.planned = Array(repeating: 0, count: 7)
        let day = LogicalDayBridgeFake(); day.today = "2026-10-09"
        let shell = ShellStore(bridge: ShellBridgeFake())
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        var start = "2026-10-05"; var readError: Error?
        let store = WeekStore(tasks: tasks, logicalDay: day, pendingDeletion: pending, interactions: InteractionBridgeFake(),
                              weekStart: "", weekDates: { value in [value, "d2", "d3", "d4", "d5", "d6", "d7"] },
                              weekStartProvider: { if let readError { throw readError }; return start })
        XCTAssertEqual(store.weekStart, start)
        start = "2026-10-12"; day.today = "2026-10-12"
        XCTAssertEqual(store.weekStart, start); XCTAssertEqual(store.groups[0].date, start)
        let snapshot = store.groups
        readError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "周起点读取失败"])
        start = "2026-10-19"; day.today = "2026-10-19"
        XCTAssertEqual(store.groups, snapshot); XCTAssertEqual(store.weekStart, "2026-10-12")
        XCTAssertEqual(store.error, "周起点读取失败")
    }
    // 产品保证：窄窗星期分段的今天标记直接用逻辑今日，不能由系统日期推断。
    @MainActor func testR2TodayMarkerUsesLogicalDay() {
        let (_, day, _, store) = fixture()
        XCTAssertTrue(store.isToday(day.today)); XCTAssertFalse(store.isToday("2026-10-08"))
        day.today = "2026-10-10"; store.updateLogicalDay()
        XCTAssertTrue(store.isToday("2026-10-10")); XCTAssertFalse(store.isToday("2026-10-09"))
    }
    // 产品保证：窄窗默认逻辑今日，切换星期只改展示组；日界跟随今日，手选历史日保留。
    @MainActor func testR2SelectedDayDefaultsAndRetainsManualSelection() {
        let (_, day, _, store) = fixture()
        XCTAssertEqual(store.selectedGroup?.date, "2026-10-09")
        store.selectDay("2026-10-07")
        XCTAssertEqual(store.selectedGroup?.date, "2026-10-07")
        day.today = "2026-10-10"; store.updateLogicalDay()
        XCTAssertEqual(store.selectedGroup?.date, "2026-10-07")
        store.selectDay(day.today)
        XCTAssertEqual(store.addTitle, "添加到周六")
        day.today = "2026-10-11"; store.updateLogicalDay()
        XCTAssertEqual(store.selectedGroup?.date, "2026-10-11")
    }
}
