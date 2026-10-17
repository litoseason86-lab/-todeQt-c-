import Foundation
import XCTest
@testable import IPadCore

@MainActor final class FailureRoutingStoreTests: XCTestCase {
    private func failure(_ message: String) -> NSError {
        NSError(domain: "FailureRoutingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func shell() -> ShellStore { ShellStore(bridge: ShellBridgeFake()) }
    private func pending(_ tasks: TaskBridgeFake, _ shell: ShellStore) -> PendingDeletionStore {
        PendingDeletionStore(bridge: PendingDeletionBridgeFake(), tasks: tasks, shell: shell)
    }

    // 产品保证：今日页不把后台任务和统计失败重复写进横幅，但自己读取抛错仍显示在页内。
    func testTodayBackgroundFailureDoesNotReplaceOwnedReadError() {
        let tasks = TaskBridgeFake(), statistics = StatisticsBridgeFake(), shell = shell()
        let store = TodayStore(tasks: tasks, interactions: InteractionBridgeFake(), logicalDay: LogicalDayBridgeFake(),
                               settings: SettingsBridgeFake(), statistics: statistics, gaps: GapReminderBridgeFake(),
                               pendingDeletion: pending(tasks, shell), shell: shell)
        store.start()
        XCTAssertEqual(store.loadError, "")
        tasks.onFailure?("后台任务失败"); statistics.onFailure?("后台统计失败")
        XCTAssertEqual(store.loadError, "")
        tasks.error = failure("今日读取失败"); store.refresh()
        XCTAssertEqual(store.loadError, "任务加载失败，请重试")
        statistics.onFailure?("另一条后台失败")
        XCTAssertEqual(store.loadError, "任务加载失败，请重试")
        store.stop()
    }

    // 产品保证：仪表盘不重复展示后台任务和统计失败，调用方自己的读取错误仍保留。
    func testDashboardBackgroundFailureDoesNotReplaceOwnedReadError() {
        let tasks = TaskBridgeFake(), statistics = StatisticsBridgeFake(), settings = SettingsBridgeFake(), shell = shell()
        let pending = pending(tasks, shell)
        let focus = FocusStore(focus: FocusBridgeFake(), settings: settings, tasks: tasks, pendingDeletion: pending, shell: shell)
        let actions = TaskActions(tasks: tasks, pendingDeletion: pending, shell: shell)
        let store = DashboardStore(tasks: tasks, statistics: statistics, settings: settings, actions: actions, shell: shell, focus: focus)
        store.start()
        XCTAssertEqual(store.loadError, "")
        tasks.onFailure?("后台任务失败"); statistics.onFailure?("后台统计失败")
        XCTAssertEqual(store.loadError, "")
        tasks.error = failure("仪表盘读取失败"); store.refresh()
        XCTAssertEqual(store.loadError, "任务加载失败，请重试")
        tasks.onFailure?("另一条后台失败")
        XCTAssertEqual(store.loadError, "任务加载失败，请重试")
        store.stop()
    }

    // 产品保证：统计页只显示本页读取抛错，后台统计失败交给外壳且不覆盖已有页内错误。
    func testStatsBackgroundFailureDoesNotReplaceOwnedReadError() {
        let statistics = StatisticsBridgeFake()
        let store = StatsStore(statistics: statistics, logicalDay: LogicalDayBridgeFake())
        store.setActive(true)
        XCTAssertEqual(store.errorMessage, "")
        statistics.onFailure?("后台统计失败")
        XCTAssertEqual(store.errorMessage, "")
        statistics.error = failure("统计读取失败"); store.refresh()
        XCTAssertEqual(store.errorMessage, "统计读取失败")
        statistics.onFailure?("另一条后台失败")
        XCTAssertEqual(store.errorMessage, "统计读取失败")
        store.setActive(false)
    }

    // 产品保证：时间轴的后台统计失败不落入页面，直接读取失败仍由时间轴显示。
    func testTimelineBackgroundFailureDoesNotReplaceOwnedReadError() {
        let tasks = TaskBridgeFake(), statistics = StatisticsBridgeFake(), shell = shell(), day = LogicalDayBridgeFake()
        let store = TimelineStore(history: FocusHistoryBridgeFake(), statistics: statistics,
                                  pendingDeletion: pending(tasks, shell), logicalDay: day, date: day.today)
        XCTAssertEqual(store.error, "")
        statistics.onFailure?("后台统计失败")
        XCTAssertEqual(store.error, "")
        statistics.error = failure("时间轴读取失败"); store.refresh()
        XCTAssertEqual(store.error, "时间轴读取失败")
        statistics.onFailure?("另一条后台失败")
        XCTAssertEqual(store.error, "时间轴读取失败")
    }

    // 产品保证：知识缺口后台失败只由外壳提示，本页调用失败仍显示且不被后台消息替换。
    func testGapBackgroundFailureDoesNotReplaceOwnedReadError() {
        let bridge = KnowledgeGapFake()
        let store = GapStore(bridge: bridge, logicalDay: LogicalDayBridgeFake())
        store.setActive(true)
        XCTAssertEqual(store.errorMessage, "")
        bridge.onFailure?("后台缺口失败")
        XCTAssertEqual(store.errorMessage, "")
        bridge.error = failure("缺口读取失败"); store.refresh()
        XCTAssertEqual(store.errorMessage, "缺口读取失败")
        bridge.onFailure?("另一条后台失败")
        XCTAssertEqual(store.errorMessage, "缺口读取失败")
    }

    // 产品保证：专注后台 operationFailed 不再额外弹 toast，调用方动作抛错仍显示在专注页。
    func testFocusBackgroundFailureDoesNotShowAnotherToast() {
        let focus = FocusBridgeFake(), settings = SettingsBridgeFake(), tasks = TaskBridgeFake(), shell = shell()
        let store = FocusStore(focus: focus, settings: settings, tasks: tasks, pendingDeletion: pending(tasks, shell), shell: shell)
        store.start()
        XCTAssertNil(shell.toast)
        focus.onFailure?("后台专注失败")
        XCTAssertNil(shell.toast)
        focus.error = failure("专注动作失败")
        XCTAssertFalse(store.createTaskAndStart(title: "故障任务"))
        XCTAssertFalse(store.errorText.isEmpty)
        XCTAssertNil(shell.toast)
    }
}
