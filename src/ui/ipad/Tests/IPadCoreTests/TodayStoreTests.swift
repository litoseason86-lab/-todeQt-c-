import XCTest
@testable import IPadCore

@MainActor final class TodayStoreTests: XCTestCase {
    // Store 对 ShellStore 只持弱引用，测试自己持有，避免用例中途被释放。
    private var retainedShell: ShellStore?
    private struct Rig {
        let store: TodayStore
        let tasks: TaskBridgeFake
        let interactions: InteractionBridgeFake
        let logicalDay: LogicalDayBridgeFake
        let settings: SettingsBridgeFake
        let statistics: StatisticsBridgeFake
        let gaps: GapReminderBridgeFake
        let pending: PendingDeletionStore
        let shell: ShellStore
    }
    private func rig(_ rows: [TaskValue] = []) -> Rig {
        let tasks = TaskBridgeFake(); tasks.result = rows
        let interactions = InteractionBridgeFake(); let logicalDay = LogicalDayBridgeFake()
        logicalDay.today = "2026-10-09"
        let settings = SettingsBridgeFake(); let statistics = StatisticsBridgeFake(); let gaps = GapReminderBridgeFake()
        let shell = ShellStore(bridge: ShellBridgeFake()); retainedShell = shell
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        let store = TodayStore(tasks: tasks, interactions: interactions, logicalDay: logicalDay, settings: settings,
                               statistics: statistics, gaps: gaps, pendingDeletion: pending, shell: shell)
        store.start()
        return Rig(store: store, tasks: tasks, interactions: interactions, logicalDay: logicalDay, settings: settings,
                   statistics: statistics, gaps: gaps, pending: pending, shell: shell)
    }
    private func task(_ id: Int, completed: Bool = false, title: String? = nil) -> TaskValue {
        var value = TaskValue(); value.id = id; value.title = title ?? "任务\(id)"; value.completed = completed
        value.date = "2026-10-09"; return value
    }
    private func ids(_ rows: [TaskValue]) -> [Int] { rows.map(\.id) }
    private func reads(_ rig: Rig) -> Int { rig.tasks.calls.filter { $0.name == "todayTasks" }.count }
    private func moves(_ rig: Rig) -> [[Int]] { rig.tasks.calls.filter { $0.name == "moveBefore" }.map(\.ids) }

    // 产品保证：未完成与已完成分两组，组内保持服务给的顺序，不按编号或标题另排。
    func testGroupsKeepServiceOrderWithinEachGroup() {
        let r = rig([task(5), task(2, completed: true), task(9), task(1, completed: true), task(7)])
        XCTAssertEqual(ids(r.store.unfinished), [5, 9, 7])
        XCTAssertEqual(ids(r.store.finished), [2, 1])
    }
    // 产品保证：向下拖到某位置，只发一次「把 X 移到下一项之前」；传的是落点后面那项的编号。
    func testDragDownSendsOneMoveBeforeNextItem() {
        let r = rig([task(10), task(20), task(30), task(40), task(50, completed: true)])
        XCTAssertTrue(r.store.commitDrag(taskID: 10, toIndex: 2))
        XCTAssertEqual(moves(r), [[10, 40]])
    }
    // 产品保证：向上拖时传落点上原有那项的编号。
    func testDragUpSendsTargetItemAsBefore() {
        let r = rig([task(10), task(20), task(30), task(40)])
        XCTAssertTrue(r.store.commitDrag(taskID: 40, toIndex: 1))
        XCTAssertEqual(moves(r), [[40, 20]])
    }
    // 产品保证：拖到未完成组末位时，后面有已完成项就传它的编号（由服务夹到组尾），没有就传 0 表示末尾。
    func testDragToGroupEndPassesFirstFinishedOrZero() {
        let with = rig([task(10), task(20), task(30, completed: true), task(40, completed: true)])
        XCTAssertTrue(with.store.commitDrag(taskID: 10, toIndex: 1))
        XCTAssertEqual(moves(with), [[10, 30]])
        let without = rig([task(10), task(20)])
        XCTAssertTrue(without.store.commitDrag(taskID: 10, toIndex: 1))
        XCTAssertEqual(moves(without), [[10, 0]])
    }
    // 产品保证：拖动开始就冻结刷新，取消拖动零写入，并释放冻结。
    func testCancelledDragWritesNothingAndReleasesFreeze() {
        let r = rig([task(10), task(20), task(30)])
        XCTAssertTrue(r.store.beginDrag(taskID: 20)); XCTAssertTrue(r.interactions.refreshBlocked)
        XCTAssertEqual(r.interactions.calls.last?.name, "drag")
        r.store.cancelDrag()
        XCTAssertTrue(moves(r).isEmpty); XCTAssertFalse(r.interactions.refreshBlocked)
    }
    // 产品保证：落点在已完成组、列表外、或原位时不写库；落点只能是未完成组里的位置。
    func testDropOutsideUnfinishedGroupWritesNothing() {
        let r = rig([task(10), task(20), task(30, completed: true), task(40, completed: true)])
        XCTAssertFalse(r.store.commitDrag(taskID: 10, toIndex: 2))   // 已完成组
        XCTAssertFalse(r.store.commitDrag(taskID: 10, toIndex: 3))
        XCTAssertFalse(r.store.commitDrag(taskID: 10, toIndex: -1))
        XCTAssertFalse(r.store.commitDrag(taskID: 20, toIndex: 1))   // 原位
        XCTAssertTrue(moves(r).isEmpty)
    }
    // 产品保证：已完成的任务不能被拿起来拖，也不登记交互。
    func testCompletedTaskCannotBeDragged() {
        let r = rig([task(10), task(30, completed: true)])
        XCTAssertFalse(r.store.beginDrag(taskID: 30))
        XCTAssertTrue(r.interactions.calls.isEmpty)
    }
    // 产品保证：撤销条挂着（有待删任务）时不开放排序，也不写库。
    func testReorderDisabledWhilePendingDeletion() {
        let r = rig([task(10), task(20), task(30)])
        XCTAssertTrue(r.pending.requestTask(id: 30, title: "任务30"))
        XCTAssertFalse(r.store.beginDrag(taskID: 10))
        XCTAssertFalse(r.store.commitDrag(taskID: 10, toIndex: 1))
        XCTAssertTrue(moves(r).isEmpty)
    }
    // 产品保证：排序写入失败要提示重试，并释放拖动冻结。
    func testMoveFailureShowsRetryAndReleasesFreeze() {
        let r = rig([task(10), task(20), task(30)])
        r.tasks.failing = ["moveBefore"]
        XCTAssertTrue(r.store.beginDrag(taskID: 10))
        XCTAssertFalse(r.store.commitDrag(taskID: 10, toIndex: 2))
        XCTAssertEqual(r.store.loadError, "任务排序保存失败，请重试"); XCTAssertFalse(r.interactions.refreshBlocked)
    }
    // 产品保证：编辑期间收到任务变化不重读（以免销毁正在编辑的行），令牌释放后只补读一次。
    func testEditFreezesRefreshAndCatchesUpOnce() throws {
        let r = rig([task(1), task(2)]); let before = reads(r)
        r.interactions.latest = task(1)
        let token = try r.interactions.beginEdit(id: 1, source: "test")
        r.tasks.result = [task(2), task(1), task(3)]
        r.tasks.onChanged?(); r.tasks.onChanged?()
        XCTAssertEqual(reads(r), before); XCTAssertEqual(ids(r.store.unfinished), [1, 2])
        token.end()
        XCTAssertEqual(reads(r), before + 1); XCTAssertEqual(ids(r.store.unfinished), [2, 1, 3])
    }
    // 产品保证：拖动期间同样冻结刷新，结束后补读一次。
    func testDragFreezesRefreshLikeEdit() {
        let r = rig([task(1), task(2)]); let before = reads(r)
        XCTAssertTrue(r.store.beginDrag(taskID: 1))
        r.tasks.onChanged?()
        XCTAssertEqual(reads(r), before)
        r.store.cancelDrag()
        XCTAssertEqual(reads(r), before + 1)
    }
    // 产品保证：待删任务立刻从列表隐藏，「已排」也排除它；撤销后恢复。
    func testPendingDeletionHidesRowAndExcludesItFromPlanned() {
        let r = rig([task(1), task(2), task(3)])
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "plannedMinutes" })?.ids, [-1])
        XCTAssertTrue(r.pending.requestTask(id: 2, title: "任务2"))
        r.store.pendingDeletionChanged()
        XCTAssertEqual(ids(r.store.unfinished), [1, 3])
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "plannedMinutes" })?.ids, [2])
        r.pending.commitIfNeeded()
        r.store.pendingDeletionChanged()
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "plannedMinutes" })?.ids, [-1])
    }
    // 产品保证：逾期未完成任务单独列出，「全部结转」按列表顺序把它们全部移到今天。
    func testRolloverListsOverdueAndMovesAllToToday() {
        let r = rig([task(1)]); r.tasks.overdue = [task(8), task(3)]; r.store.refresh()
        XCTAssertEqual(ids(r.store.overdue), [8, 3]); XCTAssertTrue(r.store.rolloverBannerActive)
        r.tasks.overdue = []
        r.store.moveOverdueToToday()
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "moveToday" })?.ids, [8, 3])
        XCTAssertFalse(r.store.rolloverBannerActive)
    }
    // 产品保证：结转失败要说出来，列表和提示条保持原样。
    func testRolloverFailureKeepsBannerAndSaysSo() {
        let r = rig([]); r.tasks.overdue = [task(8)]; r.store.refresh()
        r.tasks.failing = ["moveToday"]
        r.store.moveOverdueToToday()
        XCTAssertEqual(r.store.loadError, "结转失败，请重试"); XCTAssertTrue(r.store.rolloverBannerActive)
    }
    // 产品保证：「忽略」把逻辑今日写进设置，当天不再提示；到了新的一天再次提示。
    func testIgnoreRolloverWritesLogicalTodayAndReturnsNextDay() {
        let r = rig([]); r.tasks.overdue = [task(8)]; r.store.refresh()
        r.store.ignoreOverdueForToday()
        XCTAssertEqual(r.settings.calls.last(where: { $0.0 == "setRolloverIgnoredDate" })?.1, .string("2026-10-09"))
        XCTAssertFalse(r.store.rolloverBannerActive)
        r.store.refresh(); XCTAssertFalse(r.store.rolloverBannerActive)
        r.logicalDay.today = "2026-10-10"
        XCTAssertTrue(r.store.rolloverBannerActive)
    }
    // 产品保证：没有逾期任务时不显示结转提示。
    func testNoOverdueMeansNoRolloverBanner() {
        let r = rig([task(1)]); r.tasks.overdue = []; r.store.refresh()
        XCTAssertFalse(r.store.rolloverBannerActive); XCTAssertEqual(r.store.overdue, [])
    }
    // 产品保证：知识缺口提示的条数文案；有逾期时带逾期数和最久天数，只有当天到期时写「今天到期」，没有到期项不显示。
    func testGapBannerCountsAndText() {
        let r = rig([])
        r.gaps.summary.dueToday = 2; r.gaps.summary.overdue = 3; r.gaps.summary.oldestOverdueDays = 5; r.store.refresh()
        XCTAssertTrue(r.store.gapBannerActive)
        XCTAssertEqual(r.store.gapBannerText, "5 条知识缺口到期 · 3 条已逾期 · 最久 5 天")
        r.gaps.summary.overdue = 0; r.store.refresh()
        XCTAssertEqual(r.store.gapBannerText, "2 条知识缺口今天到期")
        r.gaps.summary.dueToday = 0; r.store.refresh()
        XCTAssertFalse(r.store.gapBannerActive)
    }
    // 产品保证：摘要读取失败时提示条保持安静（不显示「0 条」），也不把它算成页面读取错误。
    func testGapSummaryReadFailureIsQuiet() {
        let r = rig([]); r.gaps.summary.dueToday = 2; r.store.refresh(); XCTAssertTrue(r.store.gapBannerActive)
        r.gaps.failing = ["reminderSummary"]; r.store.refresh()
        XCTAssertFalse(r.store.gapBannerActive); XCTAssertEqual(r.store.loadError, "")
    }
    // 产品保证：「全部加到今天」只调用服务一次；全成功给提示条，部分失败带数量和原因，没有原因写「未知原因」。
    func testGapConversionOutcomeMessages() {
        let ok = rig([]); ok.gaps.summary.dueToday = 3
        ok.gaps.conversion.converted = 3
        ok.store.refresh(); ok.store.convertDueGaps()
        XCTAssertEqual(ok.gaps.calls.filter { $0.name == "convertDueGapsToTasks" }.count, 1)
        XCTAssertEqual(ok.store.gapConvertMessage, ""); XCTAssertEqual(ok.shell.toast?.message, "已把 3 条知识缺口加到今天的任务")

        let partial = rig([]); partial.gaps.summary.dueToday = 3
        partial.gaps.conversion.converted = 2; partial.gaps.conversion.failed = 1; partial.gaps.conversion.reason = "磁盘已满"
        partial.store.refresh(); partial.store.convertDueGaps()
        XCTAssertEqual(partial.store.gapConvertMessage, "有 1 条知识缺口没加上：磁盘已满")
        XCTAssertEqual(partial.shell.toast?.message, "已把 2 条知识缺口加到今天的任务")

        let none = rig([]); none.gaps.summary.dueToday = 4
        none.gaps.conversion.failed = 4
        none.store.refresh(); none.store.convertDueGaps()
        XCTAssertEqual(none.store.gapConvertMessage, "4 条知识缺口没能加到今天：未知原因")
        XCTAssertNil(none.shell.toast)
    }
    // 产品保证：转换后要重读提示条和任务；失败说明在提示条安静之前不被刷新抹掉，安静后清空。
    func testGapFailureMessageSurvivesRefreshUntilBannerQuiet() {
        let r = rig([]); r.gaps.summary.dueToday = 3; r.gaps.conversion.failed = 3; r.gaps.conversion.reason = "原因"
        r.store.refresh(); r.store.convertDueGaps()
        let reads = r.gaps.calls.filter { $0.name == "reminderSummary" }.count
        r.store.refresh()
        XCTAssertGreaterThan(r.gaps.calls.filter { $0.name == "reminderSummary" }.count, reads)
        XCTAssertEqual(r.store.gapConvertMessage, "3 条知识缺口没能加到今天：原因")
        r.gaps.summary.dueToday = 0; r.store.refresh()
        XCTAssertEqual(r.store.gapConvertMessage, "")
    }
    // 产品保证：新任务落在逻辑今日（不是系统日期），标题去首尾空白；回车后输入清空但仍保持输入状态。
    func testNewTaskLandsOnLogicalTodayAndKeepsComposing() {
        let r = rig([]); r.logicalDay.today = "2031-02-03"
        r.store.newTitle = "  写作业 "
        XCTAssertTrue(r.store.submitNewTask())
        let call = r.tasks.calls.last(where: { $0.name == "create" })
        XCTAssertEqual(call?.text, ["写作业", "2031-02-03", ""]); XCTAssertEqual(call?.numbers, [-1, 0])
        XCTAssertEqual(r.store.newTitle, ""); XCTAssertTrue(r.store.newTaskFocusRequested)
    }
    // 产品保证：空标题不建任务；建任务失败保留输入并显示原因。
    func testNewTaskEmptyIsIgnoredAndFailureKeepsInput() {
        let r = rig([])
        r.store.newTitle = "   "; XCTAssertFalse(r.store.submitNewTask())
        XCTAssertTrue(r.tasks.calls.filter { $0.name == "create" }.isEmpty)
        r.store.newTitle = "甲"; r.tasks.failing = ["create"]
        XCTAssertFalse(r.store.submitNewTask())
        XCTAssertEqual(r.store.newTitle, "甲"); XCTAssertEqual(r.store.loadError, "create 失败")
    }
    // 产品保证：⌘N 只请求一次输入焦点，页面确认后清除请求。
    func testNewTaskRequestIsConsumedOnce() {
        let r = rig([]); XCTAssertFalse(r.store.newTaskFocusRequested)
        r.store.requestNewTask(); XCTAssertTrue(r.store.newTaskFocusRequested)
        r.store.acknowledgeNewTaskRequest(); XCTAssertFalse(r.store.newTaskFocusRequested)
    }
    // 产品保证：过了日界后按新日期重读任务、目标和「已排」。
    func testLogicalDayChangeRereadsWithNewDate() {
        let r = rig([task(1)]); let before = reads(r)
        r.logicalDay.today = "2026-10-10"
        XCTAssertEqual(r.store.today, "2026-10-10"); XCTAssertGreaterThan(reads(r), before)
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "plannedMinutes" })?.text, ["2026-10-10"])
        XCTAssertEqual(r.settings.calls.last(where: { $0.0 == "dailyFocusGoal" })?.1, .string("2026-10-10"))
    }
    // 产品保证：读取失败时保留上一份数据并提示重试，而不是清空成「没有任务」；其它读取不受拖累。
    func testReadFailureKeepsOldDataAndSaysRetry() {
        let r = rig([task(1), task(2)]); r.statistics.day.totalDuration = 600; r.store.refresh()
        XCTAssertEqual(r.store.focusedSeconds, 600)
        r.tasks.failing = ["todayTasks"]; r.statistics.day.totalDuration = 900
        r.store.refresh()
        XCTAssertEqual(ids(r.store.unfinished), [1, 2]); XCTAssertEqual(r.store.loadError, "任务加载失败，请重试")
        XCTAssertEqual(r.store.focusedSeconds, 900)
        r.tasks.failing = []; r.store.refresh()
        XCTAssertEqual(r.store.loadError, "")
    }
    // 产品保证：统计读取失败也保留旧数字并提示。
    func testStatisticsFailureKeepsOldFocusedTime() {
        let r = rig([]); r.statistics.day.totalDuration = 600; r.store.refresh()
        r.statistics.error = NSError(domain: "测试", code: 1); r.store.refresh()
        XCTAssertEqual(r.store.focusedSeconds, 600); XCTAssertEqual(r.store.loadError, "统计数据加载失败，请重试")
    }
    // 产品保证：副标题依次给目标、已排、已专注；已排和已专注的数字来自服务，格式走统一时长口径，没设目标写「未设目标」。
    func testSubtitleParts() {
        let r = rig([]); r.settings.goal = 90; r.tasks.planned = [150]; r.statistics.day.totalDuration = 3700; r.store.refresh()
        XCTAssertEqual(r.store.subtitleParts, ["目标 1 小时 30 分", "已排 2 小时 30 分", "已专注 1 小时 1 分"])
        r.settings.goal = 0; r.tasks.planned = []; r.statistics.day.totalDuration = 0; r.store.refresh()
        XCTAssertEqual(r.store.subtitleParts, ["未设目标", "已排 0 分钟", "已专注 0 分钟"])
    }
    // 产品保证：每日目标写在逻辑今日名下；写入失败保留原目标并提示。
    func testGoalSavedForLogicalToday() {
        let r = rig([])
        XCTAssertTrue(r.store.saveGoal(minutes: 120))
        XCTAssertEqual(r.settings.calls.last(where: { $0.0 == "setDailyFocusGoal" })?.1, .goal("2026-10-09", 120))
        XCTAssertEqual(r.store.goalMinutes, 120)
        r.settings.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "写不进去"])
        XCTAssertFalse(r.store.saveGoal(minutes: 30))
        XCTAssertEqual(r.store.goalMinutes, 120); XCTAssertEqual(r.store.loadError, "写不进去")
    }
    // 产品保证：页面不在前台时不重读，也不响应任何桥接信号；回到前台后恢复，离开后回调槽被清空。
    func testInactivePageDoesNotReadOrListen() {
        let tasks = TaskBridgeFake(); let shell = ShellStore(bridge: ShellBridgeFake()); retainedShell = shell
        let logicalDay = LogicalDayBridgeFake(); let gaps = GapReminderBridgeFake()
        let store = TodayStore(tasks: tasks, interactions: InteractionBridgeFake(), logicalDay: logicalDay,
                               settings: SettingsBridgeFake(), statistics: StatisticsBridgeFake(), gaps: gaps,
                               pendingDeletion: PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell), shell: shell)
        XCTAssertNil(tasks.onChanged); XCTAssertNil(logicalDay.onChanged); XCTAssertTrue(tasks.calls.isEmpty)
        store.start(); let started = tasks.calls.count
        XCTAssertGreaterThan(started, 0)
        tasks.onChanged?(); XCTAssertGreaterThan(tasks.calls.count, started)
        let handler = tasks.onChanged, dayHandler = logicalDay.onChanged, gapHandler = gaps.onTasksAffected
        store.stop()
        XCTAssertNil(tasks.onChanged); XCTAssertNil(logicalDay.onChanged); XCTAssertNil(gaps.onTasksAffected)
        let stopped = tasks.calls.count
        // 即使旧回调被别处持有，页面离开后也不读。
        handler?(); dayHandler?(); gapHandler?(); store.refresh()
        XCTAssertEqual(tasks.calls.count, stopped)
    }
    // 产品保证：结转提示写明回看天数（来自服务常量），拿不到时退回不带天数的说法。
    func testRolloverBannerTextNamesLookbackDays() {
        let r = rig([]); r.tasks.overdue = [task(8), task(3)]; r.tasks.overdueRolloverDays = 7; r.store.refresh()
        XCTAssertEqual(r.store.rolloverBannerText, "最近 7 天还有 2 个未完成任务")
        r.tasks.overdueRolloverDays = 0
        XCTAssertEqual(r.store.rolloverBannerText, "之前还有 2 个未完成任务")
    }
    // 产品保证：复制到今天用逻辑今日，改期用所选日期，均只调用一次。
    func testCopyAndRescheduleUseServiceDates() {
        let r = rig([task(4)]); r.logicalDay.today = "2031-02-03"
        XCTAssertTrue(r.store.copyToToday(id: 4))
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "duplicate" })?.ids, [4])
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "duplicate" })?.text, ["2031-02-03"])
        XCTAssertTrue(r.store.reschedule(id: 4, date: "2031-03-04"))
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "moveDate" })?.text, ["2031-03-04"])
    }

    // MARK: 搜索与批量改期
    private func searchRows() -> [TaskValue] { [task(1, title: "数学"), task(2, completed: true, title: "英语"), task(3, title: "物理")] }
    // 产品保证：批量改期把所选编号和日期交给服务，成功后清空勾选并说明数量。
    func testBatchRescheduleSendsSelectionAndClearsIt() {
        let r = rig([]); r.tasks.result = searchRows()
        r.store.tools.open(); r.store.tools.search()
        r.store.tools.toggle(id: 3); r.store.tools.toggle(id: 1)
        XCTAssertTrue(r.store.tools.applyDate("2026-11-01"))
        let call = r.tasks.calls.last(where: { $0.name == "moveDates" })
        XCTAssertEqual(call?.ids, [3, 1]); XCTAssertEqual(call?.text, ["2026-11-01"])
        XCTAssertEqual(r.store.tools.selectedIDs, []); XCTAssertEqual(r.store.tools.message, "已将 2 项任务移到 2026-11-01")
    }
    // 产品保证：改期失败保留勾选并提示，不当作成功。
    func testBatchRescheduleFailureKeepsSelection() {
        let r = rig([]); r.tasks.result = searchRows()
        r.store.tools.open(); r.store.tools.search(); r.store.tools.toggle(id: 1)
        r.tasks.failing = ["moveDates"]
        XCTAssertFalse(r.store.tools.applyDate("2026-11-01"))
        XCTAssertEqual(r.store.tools.selectedIDs, [1]); XCTAssertEqual(r.store.tools.message, "改期失败，未修改任务，请刷新重试")
    }
    // 产品保证：结果刷新时保留仍在结果里的勾选，丢掉已消失的；全选可切换。
    func testSelectionSurvivesReloadAndDropsMissingRows() {
        let r = rig([]); r.tasks.result = searchRows()
        r.store.tools.open(); r.store.tools.search(); r.store.tools.toggleAll()
        XCTAssertEqual(r.store.tools.selectedIDs, [1, 2, 3])
        r.tasks.result = [searchRows()[0], searchRows()[2]]; r.store.refresh()
        XCTAssertEqual(r.store.tools.selectedIDs, [1, 3])
        r.store.tools.toggleAll(); XCTAssertEqual(r.store.tools.selectedIDs, [])
    }
    // 产品保证：「选择逾期」只选服务认定的逾期任务，且只在当前结果里选。
    func testSelectOverdueFollowsServiceDefinition() {
        let r = rig([]); r.tasks.result = searchRows(); r.tasks.overdue = [task(1), task(99)]
        r.store.tools.open(); r.store.tools.search(); r.store.tools.selectOverdue()
        XCTAssertEqual(r.store.tools.selectedIDs, [1])
    }
    // 产品保证：待删任务不出现在搜索结果里；重新搜索清空勾选。
    func testPendingDeletionAndNewSearchClearTools() {
        let r = rig([]); r.tasks.result = searchRows()
        r.store.tools.open(); r.store.tools.search(); r.store.tools.toggle(id: 1)
        XCTAssertTrue(r.pending.requestTask(id: 1, title: "数学")); r.store.pendingDeletionChanged()
        XCTAssertEqual(ids(r.store.tools.rows), [2, 3]); XCTAssertEqual(r.store.tools.selectedIDs, [])
        r.store.tools.toggle(id: 2); r.store.tools.query = "英"; r.store.tools.search()
        XCTAssertEqual(r.store.tools.selectedIDs, [])
        let call = r.tasks.calls.last(where: { $0.name == "search" })
        XCTAssertEqual(call?.text, ["英"]); XCTAssertEqual(call?.numbers, [-1, 200])
    }
    // 产品保证：状态筛选交给服务（全部 -1、未完成 0、已完成 1）；结果满额时提供「加载更多」，每次多 200 条。
    func testStatusFilterAndLoadMore() {
        let r = rig([]); r.tasks.result = (1...200).map { task($0) }
        r.store.tools.open(); r.store.tools.status = .finished; r.store.tools.search()
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "search" })?.numbers, [1, 200])
        XCTAssertTrue(r.store.tools.hasMore)
        r.store.tools.loadMore()
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "search" })?.numbers, [1, 400])
    }
    // 产品保证：搜索结果里的「复制到今天」用逻辑今日。
    func testToolsCopyToTodayUsesLogicalToday() {
        let r = rig([]); r.logicalDay.today = "2031-02-03"
        XCTAssertTrue(r.store.tools.copyToToday(id: 2))
        XCTAssertEqual(r.tasks.calls.last(where: { $0.name == "duplicate" })?.text, ["2031-02-03"])
        XCTAssertEqual(r.store.tools.message, "已复制到今天，完成状态与计时从零开始")
    }
    // 产品保证：一段专注完成后，今日页的「已专注」立刻跟着变，不必等下次进页；离开页面后不再监听。
    func testFocusCompletedRefreshesFocusedTimeWhileActive() {
        let tasks = TaskBridgeFake(); let statistics = StatisticsBridgeFake(); let focus = FocusBridgeFake()
        let shell = ShellStore(bridge: ShellBridgeFake()); retainedShell = shell
        let logicalDay = LogicalDayBridgeFake(); logicalDay.today = "2026-10-09"
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        let store = TodayStore(tasks: tasks, interactions: InteractionBridgeFake(), logicalDay: logicalDay,
                               settings: SettingsBridgeFake(), statistics: statistics, gaps: GapReminderBridgeFake(),
                               pendingDeletion: pending, shell: shell, focus: focus)
        statistics.day.totalDuration = 600
        store.start()
        XCTAssertEqual(store.focusedSeconds, 600)
        statistics.day.totalDuration = 2100   // 服务里多了一段 25 分钟的专注
        focus.onFocusCompleted?(1500)
        XCTAssertEqual(store.focusedSeconds, 2100)
        store.stop()
        statistics.day.totalDuration = 9000
        XCTAssertNil(focus.onFocusCompleted)
        XCTAssertEqual(store.focusedSeconds, 2100)
    }
}
