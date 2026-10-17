import Observation
import XCTest
@testable import IPadCore

@MainActor private final class FakeShellBridge: ShellBridgeProtocol {
    var onChanged: (() -> Void)?
    var onTimerChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var snapshot = ShellSnapshot()
    var timerSnapshot = ShellTimerSnapshot()
    var fullReads = 0
    var timerReads = 0
    var timerError: Error?
    var nativeUIError: Error?
    var error: Error?
    var captureResult = 9
    // 写入期间由服务经桥接报上来的失败（真实桥接里服务的失败信号同步转发到 onFailure）。
    var captureFailure: String?
    var calls: [String] = []
    func readTimer() throws -> ShellTimerSnapshot { timerReads += 1; if let timerError { throw timerError }; return timerSnapshot }
    func read() throws -> ShellSnapshot { fullReads += 1; if let error { throw error }; return snapshot }
    func setNativeUI(_ value: Bool) throws { if let nativeUIError { throw nativeUIError }; calls.append("nativeUI:\(value)") }
    func pause() -> Bool { calls.append("pause"); return true }
    func resume() -> Bool { calls.append("resume"); return true }
    func capture(title: String, categoryID: Int, sourceTaskID: Int) -> Int {
        calls.append("capture:\(title):\(categoryID):\(sourceTaskID)")
        if let captureFailure { onFailure?(captureFailure) }
        return captureResult
    }
    func select(page: String) { calls.append("select:\(page)") }
}

@MainActor final class ShellStoreTests: XCTestCase {
    // 产品保证：窄窗记录直达今日专注，本周只从更多进入；宽窗侧栏收起后顶部只有仪表盘、专注、今日专注（按此顺序），
    // 今日任务、本周不放进顶部和侧栏列表，但仍能从侧栏摘要块进入。
    func testR1TabMappingKeepsRecordsDirectAndWeekInMore() {
        XCTAssertEqual(PageID.collapsedBarTabs, [.dashboard, .focus, .todayFocus])
        XCTAssertEqual(PageID.tileOnlyTabs, [.today, .week])
        XCTAssertTrue(Set(PageID.tileOnlyTabs).isSubset(of: PageID.summary))
        XCTAssertTrue(Set(PageID.collapsedBarTabs).isDisjoint(with: PageID.tileOnlyTabs))
        XCTAssertEqual(Set(PageID.regularTabs), Set(PageID.collapsedBarTabs + PageID.tileOnlyTabs))
        XCTAssertEqual(PageID.primary, [.today, .focus, .todayFocus, .dashboard])
        XCTAssertEqual(ShellStore.navigationTarget(for: .todayFocus, size: .compact), .page(.todayFocus))
        XCTAssertEqual(ShellStore.navigationTarget(for: .week, size: .compact), .more(path: [.week]))
        XCTAssertEqual(PageID.todayFocus.tabTitle(size: .compact), "记录")
        XCTAssertEqual(PageID.todayFocus.title, "今日专注")
        let store = ShellStore(bridge: FakeShellBridge())
        XCTAssertTrue(store.morePages.contains(.week))
        XCTAssertFalse(store.morePages.contains(.todayFocus))
        XCTAssertTrue(store.sidebarPages.contains(.knowledgeGap))
        XCTAssertTrue(store.sidebarPages.contains(.countdown))
    }
    // 产品保证：四块摘要用服务读数，第四块是主目标且过期文案与倒计时页一致；无主目标显示破折号并仍能进入倒计时。
    func testR1SummaryTilesProjectGoalAndServiceCounts() {
        let bridge = FakeShellBridge()
        bridge.snapshot.todayPendingCount = 5; bridge.snapshot.weekPendingCount = 12
        bridge.snapshot.todayFocusedSeconds = 3900; bridge.snapshot.dueGapCount = 2
        let store = ShellStore(bridge: bridge)
        var tiles = store.summaryTiles(focusTimeText: "18:42")
        guard tiles.count == 4 else { XCTFail("必须展示四块摘要"); return }
        XCTAssertEqual(tiles.map(\.page), [.today, .focus, .week, .countdown])
        XCTAssertEqual(tiles.map(\.title), ["今日任务", "专注计时", "本周待办", "目标倒计时"])
        // 定稿「专注计时」块是今日累计的「时:分」（1 小时 05 分写成 1:05），整句时长在窄块里会被截断。
        XCTAssertEqual(tiles.map(\.value), ["5", "1:05", "12", "—"])
        bridge.snapshot.hasPrimaryGoal = true; bridge.snapshot.primaryGoalName = "考研初试"
        bridge.snapshot.primaryGoalDaysRemaining = 72; bridge.snapshot.hasTimer = true
        bridge.onChanged?()
        tiles = store.summaryTiles(focusTimeText: "18:42")
        XCTAssertEqual(tiles[1].value, "18:42")
        XCTAssertEqual(tiles[3].title, "考研初试"); XCTAssertEqual(tiles[3].value, "72 天")
        bridge.snapshot.primaryGoalDaysRemaining = -3
        bridge.onChanged?()
        XCTAssertEqual(store.summaryTiles(focusTimeText: "18:42")[3].value, "已过期 3 天")
        XCTAssertEqual(store.sidebarBadge(for: .knowledgeGap), 2)
        XCTAssertNil(store.sidebarBadge(for: .countdown))
        // 没有待复习的缺口时不显示角标，不在侧栏挂一个「0」。
        bridge.snapshot.dueGapCount = 0; bridge.onChanged?()
        XCTAssertNil(store.sidebarBadge(for: .knowledgeGap))
        // 不足一分钟按 0 分，满 10 小时不补零也不进位成天。
        bridge.snapshot.hasTimer = false; bridge.snapshot.todayFocusedSeconds = 59; bridge.onChanged?()
        XCTAssertEqual(store.summaryTiles(focusTimeText: "18:42")[1].value, "0:00")
        bridge.snapshot.todayFocusedSeconds = 36_000 + 9 * 60 + 59; bridge.onChanged?()
        XCTAssertEqual(store.summaryTiles(focusTimeText: "18:42")[1].value, "10:09")
    }
    // 产品保证：原生回退只写下次启动偏好，不切当前页；失败不给成功提示，恢复遮罩时不写入。
    func testLegacyUIRequestSavesOnlyNextLaunchPreference() {
        let bridge = FakeShellBridge(); let store = ShellStore(bridge: bridge)
        store.select(.settings); store.useLegacyUIOnNextLaunch()
        XCTAssertEqual(store.selection, .settings); XCTAssertEqual(bridge.calls.last, "nativeUI:false")
        XCTAssertEqual(store.toast?.message, "下次启动将使用旧版界面")
        store.retireToast()
        bridge.nativeUIError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "偏好写入失败"])
        store.useLegacyUIOnNextLaunch()
        XCTAssertNil(store.toast); XCTAssertEqual(store.errorMessage, "偏好写入失败")
        bridge.nativeUIError = nil; bridge.snapshot.operationBlocksUI = true; bridge.onChanged?()
        let previous = bridge.calls; store.useLegacyUIOnNextLaunch()
        XCTAssertEqual(bridge.calls, previous); XCTAssertNil(store.toast)
    }
    // 产品保证：每秒 tick 只更新计时字段，保留统计摘要、恢复遮罩与此前的读取错误；语义变化仍刷新摘要。
    func testTickDoesNotReadSummaryAndKeepsOtherState() {
        let bridge = FakeShellBridge()
        bridge.snapshot.todayPendingCount = 7
        bridge.snapshot.operationBlocksUI = true
        let store = ShellStore(bridge: bridge)
        XCTAssertEqual(bridge.fullReads, 1)
        bridge.onFailure?("摘要读取失败")
        bridge.snapshot.todayPendingCount = 99
        bridge.timerSnapshot.hasTimer = true; bridge.timerSnapshot.running = true
        bridge.timerSnapshot.elapsedSeconds = 37; bridge.timerSnapshot.currentTaskId = 12
        bridge.timerSnapshot.taskTitle = "计时任务"
        for _ in 0..<60 { bridge.onTimerChanged?() }
        XCTAssertEqual(bridge.fullReads, 1); XCTAssertEqual(bridge.timerReads, 60)
        XCTAssertEqual(store.snapshot.todayPendingCount, 7); XCTAssertTrue(store.snapshot.operationBlocksUI)
        XCTAssertEqual(store.snapshot.elapsedSeconds, 37); XCTAssertEqual(store.snapshot.currentTaskId, 12)
        XCTAssertEqual(store.snapshot.taskTitle, "计时任务"); XCTAssertTrue(store.snapshot.running)
        XCTAssertEqual(store.errorMessage, "摘要读取失败")
        bridge.onChanged?()
        XCTAssertEqual(bridge.fullReads, 2); XCTAssertEqual(store.snapshot.todayPendingCount, 99)
        XCTAssertEqual(store.errorMessage, "")
    }
    // 产品保证：计时快照读取失败时保留上一份计时读数并显示失败原因。
    func testTimerReadFailureKeepsPreviousTimer() {
        let bridge = FakeShellBridge(); let store = ShellStore(bridge: bridge)
        bridge.timerSnapshot.elapsedSeconds = 19; bridge.onTimerChanged?()
        XCTAssertEqual(store.snapshot.elapsedSeconds, 19)
        bridge.timerError = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "计时读取失败"])
        bridge.timerSnapshot.elapsedSeconds = 99; bridge.onTimerChanged?()
        XCTAssertEqual(store.snapshot.elapsedSeconds, 19); XCTAssertEqual(store.errorMessage, "计时读取失败")
    }
    // 产品保证：计时每秒跳动、以及服务通知后读回的内容没变时，只读外观、计数、阻断状态的界面不会被通知重算
    // （10-12 真机测速：原来每跳一次所有页面的外壳都重算，主线程忙约 155 毫秒）；真变了的那一项照常通知，别的项不跟着通知。
    func testTimerTicksAndUnchangedRefreshDoNotInvalidateOtherState() {
        let bridge = FakeShellBridge()
        bridge.snapshot.appearance = "theme"; bridge.snapshot.backgroundTheme = "jiangnan"
        bridge.snapshot.todayPendingCount = 3; bridge.snapshot.dueGapCount = 1
        let store = ShellStore(bridge: bridge)
        // 跟踪期间读过的属性一旦被写就记一笔；onChange 在写入的那一刻同步调用。
        final class Flag: @unchecked Sendable { var value = false }
        func notifies(_ read: @escaping () -> Void, when action: () -> Void) -> Bool {
            let flag = Flag()
            withObservationTracking(read) { flag.value = true }
            action()
            return flag.value
        }
        let others = { _ = store.appearanceState; _ = store.details; _ = store.operationBlocksUI; _ = store.dueGapCount }
        // 前提：跟踪有效，计时读数真变了会通知读计时的地方。
        bridge.timerSnapshot.hasTimer = true; bridge.timerSnapshot.elapsedSeconds = 1
        XCTAssertTrue(notifies({ _ = store.timer }, when: { bridge.onTimerChanged?() }))
        // 计时跳一秒：其它各项都不通知，hasTimer 没变也不通知。
        bridge.timerSnapshot.elapsedSeconds = 2
        XCTAssertFalse(notifies({ others(); _ = store.hasTimer }, when: { bridge.onTimerChanged?() }))
        // 服务通知后整份重读、只有计时秒数不同：外观、其余字段等都不通知。
        bridge.snapshot.hasTimer = true; bridge.snapshot.elapsedSeconds = 3
        XCTAssertFalse(notifies(others, when: { bridge.onChanged?() }))
        // 计数变了只通知其余字段，外观不跟着通知；换主题才通知外观。
        bridge.snapshot.todayPendingCount = 4
        XCTAssertTrue(notifies({ _ = store.details }, when: { bridge.onChanged?() }))
        bridge.snapshot.todayPendingCount = 5
        XCTAssertFalse(notifies({ _ = store.appearanceState }, when: { bridge.onChanged?() }))
        bridge.snapshot.backgroundTheme = "warm"
        XCTAssertTrue(notifies({ _ = store.appearanceState }, when: { bridge.onChanged?() }))
        // 兼容入口仍拼出完整快照。
        XCTAssertEqual(store.snapshot.backgroundTheme, "warm"); XCTAssertEqual(store.snapshot.todayPendingCount, 5)
        XCTAssertEqual(store.snapshot.dueGapCount, 1); XCTAssertEqual(store.snapshot.elapsedSeconds, 3)
    }
    // 产品保证：只有专注页的工具栏捕获才带计时任务，其它页面保持无来源。
    func testCaptureSourceOnlyOnFocusPage() {
        let bridge = FakeShellBridge()
        let store = ShellStore(bridge: bridge)
        var sourceReads = 0
        store.captureSourceProvider = { sourceReads += 1; return ShellCaptureSource(taskID: 41, categoryID: 3) }
        store.select(.dashboard)
        XCTAssertEqual(store.selection, .dashboard)
        store.presentCapture(from: .page(.focus)); store.captureTitle = "来自任务"
        XCTAssertTrue(store.isCapturePresented(at: .page(.focus)))
        XCTAssertEqual(sourceReads, 1)
        XCTAssertTrue(store.capture())
        store.select(.focus)
        XCTAssertEqual(store.selection, .focus)
        for (anchor, title) in [(CaptureAnchor.page(.dashboard), "普通页"), (.search, "搜索"), (.moreRoot, "更多")] {
            store.presentCapture(from: anchor); store.captureTitle = title
            XCTAssertTrue(store.isCapturePresented(at: anchor))
            XCTAssertTrue(store.capture())
        }
        XCTAssertEqual(sourceReads, 1)
        XCTAssertEqual(bridge.calls.filter { $0.hasPrefix("capture:") }, [
            "capture:来自任务:3:41", "capture:普通页:-1:-1", "capture:搜索:-1:-1", "capture:更多:-1:-1"
        ])
    }
    // 产品保证：读取失败保留上一份有效摘要，重试成功再清错并更新，失败不伪装为零任务。
    func testReadFailureKeepsSnapshotAndRetryClearsError() {
        let bridge = FakeShellBridge()
        bridge.snapshot.todayPendingCount = 7
        let store = ShellStore(bridge: bridge)
        XCTAssertEqual(store.snapshot.todayPendingCount, 7)
        bridge.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])
        bridge.onChanged?()
        XCTAssertEqual(store.snapshot.todayPendingCount, 7)
        XCTAssertEqual(store.errorMessage, "读取失败")
        bridge.error = nil
        bridge.snapshot.todayPendingCount = 3
        bridge.onChanged?()
        XCTAssertEqual(store.snapshot.todayPendingCount, 3)
        XCTAssertEqual(store.errorMessage, "")
    }
    // 产品保证：恢复遮罩期间禁止导航和记一笔，什么都不写进桥接。
    func testRestoreBlocksNavigationAndCapture() {
        let bridge = FakeShellBridge()
        bridge.snapshot.operationBlocksUI = true
        let store = ShellStore(bridge: bridge)
        XCTAssertTrue(store.snapshot.operationBlocksUI)
        store.select(.memo); store.presentCapture(from: .page(.today))
        store.captureTitle = "不能写入"
        XCTAssertFalse(store.capture())
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertFalse(store.capturePresented)
    }
    // 产品保证：新提示顶掉撤销条时只通知旧调用方一次，点击新动作不再触发旧提交。
    func testReplacingToastRetiresOldCallbackExactlyOnce() {
        let store = ShellStore(bridge: FakeShellBridge())
        var retired = 0
        var actions = 0
        store.showToast("待撤销", actionTitle: "撤销", action: { actions += 100 }, onRetired: { retired += 1 })
        store.showToast("新提示", actionTitle: "查看", action: { actions += 1 })
        XCTAssertEqual(retired, 1)
        XCTAssertEqual(store.toast?.message, "新提示")
        store.triggerToastAction()
        store.triggerToastAction()
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(retired, 1)
        XCTAssertNil(store.toast)
    }
    // 产品保证：提示超时后调用方收到退场通知，撤销动作执行后不会再被旧计时器提交。
    func testToastTimeoutAndActionCancellation() async throws {
        let store = ShellStore(bridge: FakeShellBridge())
        var retired = 0
        store.showToast("会过期", durationMilliseconds: 10, onRetired: { retired += 1 })
        // 给定时器留等待窗口，只断言最终效果；不把精确调度延迟当产品契约。
        for _ in 0..<100 where store.toast != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.toast)
        XCTAssertEqual(retired, 1)
        store.showToast("撤销", actionTitle: "撤销", durationMilliseconds: 10, action: {}, onRetired: { retired += 1 })
        store.triggerToastAction()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(retired, 1)
    }
    // 产品保证：捕获失败保留文字与浮层，成功只转发标题并关闭，不调用计时操作。
    func testCaptureFailureKeepsInputAndSuccessClosesPopover() {
        let bridge = FakeShellBridge()
        bridge.captureResult = -1
        let store = ShellStore(bridge: bridge)
        store.presentCapture()
        store.captureTitle = " 中文问题 "
        XCTAssertFalse(store.capture())
        XCTAssertEqual(store.captureTitle, " 中文问题 ")
        XCTAssertTrue(store.capturePresented)
        bridge.captureResult = 99
        XCTAssertTrue(store.capture())
        XCTAssertFalse(store.capturePresented)
        XCTAssertEqual(store.captureTitle, "")
        XCTAssertEqual(bridge.calls, ["capture:中文问题:-1:-1", "capture:中文问题:-1:-1"])
    }
    // 产品保证：记一笔失败只显示这次写入期间报上来的原因，之前别处留下的旧错误不会被当成这次失败的原因（062 A039）。
    func testCaptureFailureIgnoresStaleShellError() {
        let bridge = FakeShellBridge()
        bridge.captureResult = -1
        let store = ShellStore(bridge: bridge)
        bridge.onFailure?("早先的同步失败")
        XCTAssertEqual(store.errorMessage, "早先的同步失败", "前提：壳层留着一条与记一笔无关的旧错误")
        store.presentCapture()
        store.captureTitle = "来源编号越界"
        // 桥接拒绝越界编号时只返回 -1、不发失败：这次失败没有具体原因，只能用通用提示。
        XCTAssertFalse(store.capture())
        XCTAssertEqual(store.captureError, "没能存下来，请再试一次")
        // 写入期间服务报了失败：用这条新原因。
        bridge.captureFailure = "知识缺口写入失败"
        XCTAssertFalse(store.capture())
        XCTAssertEqual(store.captureError, "知识缺口写入失败")
    }
    // 产品保证：快捷键选页保存本机状态，更多与侧栏遵循用户顺序且固定入口末尾。
    func testSelectionAndNavigationGroupsUsePreferences() {
        let bridge = FakeShellBridge()
        bridge.snapshot.sidebarOrder = ["memo", "countdown", "stats", "today"]
        bridge.snapshot.selectedPage = "memo"
        let store = ShellStore(bridge: bridge)
        XCTAssertEqual(store.selection, .memo)
        XCTAssertEqual(Array(store.sidebarPages.prefix(3)), [.memo, .countdown, .statistics])
        XCTAssertEqual(Array(store.morePages.suffix(2)), [.trash, .settings])
        store.select(.focus)
        XCTAssertEqual(bridge.calls, ["select:focus"])
    }

    // 产品保证：打开搜索不改当前页面，每次打开都发切换请求；离开搜索时回到原页，
    // 选的仍是同一页也要发请求（否则外壳停在搜索），窄窗返回列表只清标记不切页。
    func testOpenSearchKeepsSelectionAndSamePageLeavesSearch() {
        let store = ShellStore(bridge: FakeShellBridge())
        store.select(.memo)
        let before = store.navigationRequest
        store.openSearch(); store.openSearch()
        XCTAssertEqual(store.navigationRequest, before + 2)
        XCTAssertEqual(store.selection, .memo)
        XCTAssertTrue(store.searchShown)
        store.select(.memo)
        XCTAssertFalse(store.searchShown)
        XCTAssertEqual(store.navigationRequest, before + 3)
        store.openSearch(); store.closeSearch()
        XCTAssertFalse(store.searchShown)
        XCTAssertEqual(store.navigationRequest, before + 4)
        XCTAssertEqual(store.selection, .memo)
    }

    // 产品保证：搜索页上的「记一笔」不带离开前专注页的任务来源；回到专注页后恢复专注页的规则。
    func testSearchShownOverFocusUsesSearchContext() {
        let bridge = FakeShellBridge(); bridge.snapshot.hasTimer = true
        let store = ShellStore(bridge: bridge)
        store.captureSourceProvider = { ShellCaptureSource(taskID: 41, categoryID: 3) }
        store.select(.focus)
        store.openSearch()
        XCTAssertEqual(store.selection, .focus)
        store.presentCapture(); store.captureTitle = "搜索页"
        XCTAssertTrue(store.capture())
        store.select(.focus)
        store.presentCapture(); store.captureTitle = "专注页"
        XCTAssertTrue(store.capture())
        XCTAssertEqual(bridge.calls.filter { $0.hasPrefix("capture") }, ["capture:搜索页:-1:-1", "capture:专注页:3:41"])
    }

    // 产品保证：切页和开关搜索关闭记一笔，未提交的文字保留。
    func testNavigationClosesCaptureAndPreservesDraft() {
        let store = ShellStore(bridge: FakeShellBridge())
        store.select(.today)
        store.captureTitle = "尚未记下的草稿"
        store.presentCapture()
        XCTAssertTrue(store.capturePresented)
        store.select(.dashboard)
        XCTAssertFalse(store.capturePresented)
        XCTAssertEqual(store.captureTitle, "尚未记下的草稿")
        store.presentCapture()
        XCTAssertTrue(store.capturePresented)
        store.openSearch()
        XCTAssertFalse(store.capturePresented)
        XCTAssertEqual(store.captureTitle, "尚未记下的草稿")
        store.presentCapture()
        XCTAssertTrue(store.capturePresented)
        store.closeSearch()
        XCTAssertFalse(store.capturePresented)
        XCTAssertEqual(store.captureTitle, "尚未记下的草稿")
    }

    // 产品保证：记一笔只在打开它的位置显示，关闭后任何位置都不显示。
    func testCaptureOnlyAppearsAtOpeningAnchor() {
        let store = ShellStore(bridge: FakeShellBridge())
        XCTAssertFalse(store.capturePresented)
        store.presentCapture(from: .page(.today))
        XCTAssertTrue(store.capturePresented)
        XCTAssertEqual(store.captureAnchor, .page(.today))
        XCTAssertTrue(store.isCapturePresented(at: .page(.today)))
        XCTAssertFalse(store.isCapturePresented(at: .page(.dashboard)))
        XCTAssertFalse(store.isCapturePresented(at: .search))
        XCTAssertFalse(store.isCapturePresented(at: .moreRoot))
        store.dismissCapture()
        XCTAssertFalse(store.isCapturePresented(at: .page(.today)))
    }

    // 产品保证：旧位置迟到的关闭回调不关闭新位置刚打开的记一笔。
    func testCaptureDismissIgnoresOldAnchor() {
        let store = ShellStore(bridge: FakeShellBridge())
        store.select(.today)
        store.presentCapture(from: .page(.today))
        XCTAssertTrue(store.isCapturePresented(at: .page(.today)))
        store.select(.dashboard)
        XCTAssertFalse(store.capturePresented)
        store.presentCapture(from: .page(.dashboard))
        XCTAssertTrue(store.isCapturePresented(at: .page(.dashboard)))
        store.captureDismissed(at: .page(.today))
        XCTAssertTrue(store.isCapturePresented(at: .page(.dashboard)))
        store.captureDismissed(at: .page(.dashboard))
        XCTAssertFalse(store.capturePresented)
    }

    // 产品保证：同一处的按钮先开后关，取消保留草稿；快捷键在搜索中只打开搜索处的浮层。
    func testCaptureToggleAndDismissPreserveDraft() {
        let store = ShellStore(bridge: FakeShellBridge())
        store.captureTitle = "草稿"
        XCTAssertFalse(store.capturePresented)
        store.toggleCapture(from: .page(.today))
        XCTAssertTrue(store.isCapturePresented(at: .page(.today)))
        store.toggleCapture(from: .page(.today))
        XCTAssertFalse(store.capturePresented)
        XCTAssertEqual(store.captureTitle, "草稿")
        store.toggleCapture(from: .moreRoot)
        XCTAssertTrue(store.isCapturePresented(at: .moreRoot))
        store.dismissCapture()
        XCTAssertFalse(store.capturePresented)
        XCTAssertEqual(store.captureTitle, "草稿")
        store.select(.focus)
        store.openSearch()
        XCTAssertTrue(store.searchShown)
        XCTAssertEqual(store.selection, .focus)
        store.presentCapture()
        XCTAssertEqual(store.captureAnchor, .search)
        XCTAssertTrue(store.isCapturePresented(at: .search))
        store.presentCapture()
        XCTAssertTrue(store.isCapturePresented(at: .search))
    }

    // 产品保证：窄窗口的非主页面只能通过「更多」承载，宽窗口仍直接选中对应页面。
    func testNavigationTargetMapsCompactPagesToMorePath() {
        XCTAssertEqual(ShellStore.navigationTarget(for: .today, size: .compact), .page(.today))
        XCTAssertEqual(ShellStore.navigationTarget(for: .memo, size: .compact), .more(path: [.memo]))
        XCTAssertEqual(ShellStore.navigationTarget(for: .settings, size: .compact), .more(path: [.settings]))
        XCTAssertEqual(ShellStore.navigationTarget(for: .memo, size: .regular), .page(.memo))
    }

    // 产品保证：进后台的保存同步执行，已注销页面不再保存。
    func testEditFlushersCanBeRemoved() {
        let store = ShellStore(bridge: FakeShellBridge())
        var saved: [String] = []
        let removed = store.registerEditFlusher { saved.append("移除") }
        store.registerEditFlusher { saved.append("保留") }
        store.unregisterEditFlusher(removed)
        store.flushEdits()
        XCTAssertEqual(saved, ["保留"])
    }

    // 产品保证：旁白开启时带动作的提示不自动超时退场，用户触发动作执行一次且不调退场回调。
    func testVoiceOverActionToastDoesNotTimeoutAndActionExecutesOnce() async {
        let store = ShellStore(bridge: FakeShellBridge())
        store.setVoiceOverEnabled(true)
        var actionCount = 0
        var retiredCount = 0
        store.showToast("撤销提示", actionTitle: "撤销", durationMilliseconds: 20, action: {
            actionCount += 1
        }, onRetired: {
            retiredCount += 1
        })
        guard let initialID = store.toast?.id else {
            XCTFail("提示必须已建立")
            return
        }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(store.toast?.id, initialID)
        XCTAssertEqual(actionCount, 0)
        XCTAssertEqual(retiredCount, 0)

        store.triggerToastAction()
        XCTAssertNil(store.toast)
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(retiredCount, 0)
    }

    // 产品保证：先展示带动作提示再开启旁白依然暂停超时，重复设置同一状态只通知一次；关闭旁白后重新开始倒计时并正常退场。
    func testVoiceOverTogglingWhileToastActiveRestartsTimeoutOnDisable() async {
        let store = ShellStore(bridge: FakeShellBridge())
        var suspensionChanges: [Bool] = []
        store.onAccessibilityTimeoutSuspensionChanged = { suspended in
            suspensionChanges.append(suspended)
        }
        var retiredCount = 0
        var actionCount = 0
        store.showToast("稍后开启旁白", actionTitle: "撤销", durationMilliseconds: 20, action: {
            actionCount += 1
        }, onRetired: {
            retiredCount += 1
        })
        guard let initialID = store.toast?.id else {
            XCTFail("提示必须已建立")
            return
        }
        store.setVoiceOverEnabled(true)
        store.setVoiceOverEnabled(true)
        XCTAssertEqual(suspensionChanges, [true])

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(store.toast?.id, initialID)
        XCTAssertEqual(retiredCount, 0)

        store.setVoiceOverEnabled(false)
        XCTAssertEqual(suspensionChanges, [true, false])

        var exited = false
        for _ in 0..<300 {
            if store.toast == nil {
                exited = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(exited, "关闭旁白后提示应在重新计时的窗口内退场")
        XCTAssertEqual(retiredCount, 1)
        XCTAssertEqual(actionCount, 0)
    }

    // 产品保证：旁白开启时纯信息提示没有撤销动作，依然按原时长自动超时退场。
    func testVoiceOverInformationalToastStillTimesOut() async {
        let store = ShellStore(bridge: FakeShellBridge())
        store.setVoiceOverEnabled(true)
        var retiredCount = 0
        store.showToast("纯信息提示", durationMilliseconds: 20, onRetired: {
            retiredCount += 1
        })
        XCTAssertNotNil(store.toast)
        var exited = false
        for _ in 0..<300 {
            if store.toast == nil {
                exited = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(exited, "纯信息提示即便在旁白开启时也应正常超时退场")
        XCTAssertEqual(retiredCount, 1)
    }

    // 产品保证：初次传入关闭旁白状态依然向外部转发以恢复潜在的挂起状态，重复设置同一状态不重复触发回调。
    func testVoiceOverInitialFalseIsForwardedAndDuplicatesAreDeduplicated() {
        let store = ShellStore(bridge: FakeShellBridge())
        var records: [Bool] = []
        store.onAccessibilityTimeoutSuspensionChanged = { records.append($0) }
        store.setVoiceOverEnabled(false)
        store.setVoiceOverEnabled(false)
        store.setVoiceOverEnabled(true)
        store.setVoiceOverEnabled(true)
        store.setVoiceOverEnabled(false)
        XCTAssertEqual(records, [false, true, false])
    }
}
