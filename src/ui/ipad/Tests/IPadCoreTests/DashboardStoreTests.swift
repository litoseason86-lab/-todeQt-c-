import XCTest
@testable import IPadCore

@MainActor final class DashboardStoreTests: XCTestCase {
    private struct Rig {
        let store: DashboardStore
        let tasks: TaskBridgeFake
        let statistics: StatisticsBridgeFake
        let settings: SettingsBridgeFake
        let focus: FocusStore
        let pending: PendingDeletionBridgeFake
        let shell: ShellStore
    }

    private func task(_ id: Int, _ title: String = "") -> TaskValue {
        var value = TaskValue()
        value.id = id
        value.title = title.isEmpty ? "任务\(id)" : title
        value.date = "2026-10-10"
        return value
    }

    private func rig(_ rows: [TaskValue] = [], now: Date = Date(timeIntervalSince1970: 0)) -> Rig {
        let tasks = TaskBridgeFake(); tasks.result = rows
        let statistics = StatisticsBridgeFake()
        let settings = SettingsBridgeFake()
        let focusBridge = FocusBridgeFake()
        let shell = ShellStore(bridge: ShellBridgeFake())
        let pending = PendingDeletionBridgeFake()
        let pendingStore = PendingDeletionStore(bridge: pending, tasks: tasks, shell: shell)
        let actions = TaskActions(tasks: tasks, pendingDeletion: pendingStore, shell: shell)
        let focus = FocusStore(focus: focusBridge, settings: settings, tasks: tasks,
                               pendingDeletion: pendingStore, shell: shell)
        let store = DashboardStore(tasks: tasks, statistics: statistics, settings: settings,
                                   actions: actions, shell: shell, focus: focus,
                                   nowProvider: { now })
        return Rig(store: store, tasks: tasks, statistics: statistics, settings: settings,
                   focus: focus, pending: pending, shell: shell)
    }

    // 产品保证：没有任务新增的日界切换也重读仪表盘今日数据，隐藏页不查询。
    func testLogicalDayRefreshesActiveDashboard() {
        let tasks = TaskBridgeFake(), statistics = StatisticsBridgeFake(), settings = SettingsBridgeFake()
        let shell = ShellStore(bridge: ShellBridgeFake()), day = LogicalDayBridgeFake()
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
        let actions = TaskActions(tasks: tasks, pendingDeletion: pending, shell: shell)
        let focus = FocusStore(focus: FocusBridgeFake(), settings: settings, tasks: tasks, pendingDeletion: pending, shell: shell)
        let store = DashboardStore(tasks: tasks, statistics: statistics, settings: settings,
                                   actions: actions, shell: shell, focus: focus, logicalDay: day)
        store.start(); XCTAssertEqual(store.todayStats.totalDuration, 0)
        statistics.day.totalDuration = 123
        day.today = "2026-10-11"
        XCTAssertEqual(store.todayStats.totalDuration, 123)
        store.stop(); statistics.day.totalDuration = 999; day.today = "2026-10-12"
        XCTAssertEqual(store.todayStats.totalDuration, 123)
    }
    // 产品保证：仪表盘的摘要数字原样来自统计桥，不在 Swift 层重新推算统计口径。
    func testRefreshUsesStatisticsBridgeValues() {
        let r = rig([task(1)])
        r.statistics.day.totalDuration = 3723
        r.statistics.day.completedTasks = 3
        r.statistics.day.totalTasks = 5
        r.statistics.day.completionRate = 0.6
        r.statistics.day.sessionCount = 4
        r.statistics.day.pomodoroCount = 2
        r.statistics.count = 17
        r.settings.result.nickname = "小明"

        r.store.start()

        XCTAssertEqual(r.store.todayStats.totalDuration, 3723)
        XCTAssertEqual(r.store.todayStats.completedTasks, 3)
        XCTAssertEqual(r.store.todayStats.totalTasks, 5)
        XCTAssertEqual(r.store.todayStats.completionRate, 0.6)
        XCTAssertEqual(r.store.todayStats.sessionCount, 4)
        XCTAssertEqual(r.store.todayStats.pomodoroCount, 2)
        XCTAssertEqual(r.store.streakDays, 17)
        XCTAssertEqual(r.store.totalFocusSeconds, 17)
        XCTAssertEqual(r.store.nickname, "小明")
    }

    // 产品保证：仪表盘任务区最多展示今日任务前八条，并保留桥接返回的顺序。
    func testTopTasksOnlyExposesFirstEightRows() {
        let r = rig((1...10).map { task($0) })
        r.store.start()

        XCTAssertEqual(r.store.topTasks.map(\.id), Array(1...8))
        XCTAssertEqual(r.store.topTasks.count, 8)
    }

    // 产品保证：某一路刷新失败时保留旧快照，同时显示对应错误，不用成功读取的空值覆盖旧数据。
    func testRefreshFailurePreservesPreviousDataAndError() {
        let r = rig([task(1)])
        r.statistics.day.totalDuration = 900
        r.statistics.day.completedTasks = 1
        r.statistics.day.totalTasks = 2
        r.statistics.day.completionRate = 0.5
        r.statistics.day.sessionCount = 2
        r.statistics.day.pomodoroCount = 1
        r.statistics.count = 6
        r.store.start()
        let oldTasks = r.store.tasks
        let oldStats = r.store.todayStats
        let oldStreak = r.store.streakDays
        let oldTotal = r.store.totalFocusSeconds

        r.tasks.failing.insert("todayTasks")
        r.store.refresh()
        XCTAssertEqual(r.store.tasks, oldTasks)
        XCTAssertEqual(r.store.loadError, "任务加载失败，请重试")

        r.tasks.failing.remove("todayTasks")
        r.statistics.error = NSError(domain: "测试", code: 1)
        r.store.refresh()
        XCTAssertEqual(r.store.todayStats, oldStats)
        XCTAssertEqual(r.store.streakDays, oldStreak)
        XCTAssertEqual(r.store.totalFocusSeconds, oldTotal)
        XCTAssertEqual(r.store.loadError, "统计数据加载失败，请重试")
    }

    // 产品保证：仪表盘完成和删除任务都经共用 TaskActions，避免页面另开一条写入路径。
    func testTaskActionsHandleCompletionAndDeletion() {
        let r = rig([task(3, "写报告")])
        r.store.start()
        r.store.complete(task(3, "写报告"))
        XCTAssertEqual(r.tasks.calls.last?.name, "setCompleted")
        XCTAssertEqual(r.tasks.calls.last?.ids, [3])
        XCTAssertEqual(r.tasks.calls.last?.numbers, [1])

        r.store.delete(task(3, "写报告"))
        XCTAssertEqual(r.pending.calls.last?.name, "requestTask")
        XCTAssertEqual(r.pending.calls.last?.id, 3)
        XCTAssertEqual(r.pending.state.title, "写报告")
        r.shell.retireToast()
    }

    // 产品保证：专注完成信号会触发仪表盘重新读取今日统计，停留在仪表盘也能看到新数据。
    func testFocusCompletionRefreshesDashboard() {
        let r = rig([task(1)])
        r.store.start()
        r.statistics.day.totalDuration = 1800
        r.focus.onFocusCompletedForPages?()

        XCTAssertEqual(r.store.todayStats.totalDuration, 1800)
        XCTAssertGreaterThanOrEqual(r.statistics.calls.filter { $0.0 == "todayStats" }.count, 2)
    }
}
