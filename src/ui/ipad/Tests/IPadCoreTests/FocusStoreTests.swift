import XCTest
@testable import IPadCore

@MainActor final class FocusStoreTests: XCTestCase {
    // 自动衔接的延迟调度替身：记录每次调度的延迟，测试手动触发；cancel 只打标记，
    // 触发时可选择无视标记，用来验证「迟到的旧回调」自己也会再验前提。
    @MainActor private final class Scheduler {
        struct Item { var delay: Double; var action: @MainActor () -> Void; var cancelled = false; var fired = false }
        var items: [Item] = []
        var delayFn: FocusDelay {
            { [unowned self] delay, action in
                items.append(Item(delay: delay, action: action))
                let index = items.count - 1
                return { [unowned self] in items[index].cancelled = true }
            }
        }
        func fire(_ index: Int, ignoringCancel: Bool = false) {
            guard index < items.count, ignoringCancel || !items[index].cancelled else { return }
            items[index].fired = true
            items[index].action()
        }
        var live: [Int] { items.indices.filter { !items[$0].cancelled } }
    }
    @MainActor private final class Flag { var reduceMotion = false }
    private struct Rig {
        let store: FocusStore
        let focus: FocusBridgeFake
        let settings: SettingsBridgeFake
        let tasks: TaskBridgeFake
        let shell: ShellStore
        let shellBridge: ShellBridgeFake
        let pending: PendingDeletionStore
        let pendingBridge: PendingDeletionBridgeFake
        let scheduler: Scheduler
        let flag: Flag
    }
    private var retained: [AnyObject] = []

    private func task(_ id: Int, _ title: String? = nil, category: Int = -1, notes: String = "") -> TaskValue {
        var value = TaskValue(); value.id = id; value.title = title ?? "任务\(id)"; value.categoryID = category
        value.notes = notes; value.date = "2026-10-09"; return value
    }
    private func rig(_ rows: [TaskValue] = [], configure: (FocusBridgeFake, SettingsBridgeFake) -> Void = { _, _ in }) -> Rig {
        let focus = FocusBridgeFake(); let settings = SettingsBridgeFake(); let tasks = TaskBridgeFake()
        tasks.result = rows; tasks.tasksByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let shellBridge = ShellBridgeFake(); let shell = ShellStore(bridge: shellBridge)
        let pendingBridge = PendingDeletionBridgeFake()
        let pending = PendingDeletionStore(bridge: pendingBridge, tasks: tasks, shell: shell)
        let scheduler = Scheduler(); let flag = Flag()
        configure(focus, settings)
        let store = FocusStore(focus: focus, settings: settings, tasks: tasks, pendingDeletion: pending, shell: shell,
                               reduceMotion: { flag.reduceMotion }, delay: scheduler.delayFn)
        store.start()
        retained += [shell, pending, scheduler, flag]
        return Rig(store: store, focus: focus, settings: settings, tasks: tasks, shell: shell, shellBridge: shellBridge,
                   pending: pending, pendingBridge: pendingBridge, scheduler: scheduler, flag: flag)
    }
    // 把计时器置成指定状态并让 Store 读到（模拟 C++ 发出变化信号）。
    private func setTimer(_ r: Rig, mode: Int = 0, phase: Int = 0, running: Bool = true, active: Bool = false,
                          taskID: Int = -1, title: String = "", elapsed: Int = 0, remaining: Int = 0, target: Int = 0) {
        var s = r.focus.focusSnapshot
        s.mode = mode; s.phase = phase; s.running = running; s.hasActiveSession = active
        s.currentTaskID = taskID; s.currentTaskTitle = title
        s.elapsedSeconds = elapsed; s.remainingSeconds = remaining; s.targetSeconds = target
        r.focus.focusSnapshot = s
        r.focus.onModeChanged?()
    }
    private func entry(_ kind: String, pomodoro: Bool = false, autoStart: Bool = false) -> FocusTaskEntry {
        var e = FocusTaskEntry(); e.kind = kind; e.usePomodoro = pomodoro; e.autoStart = autoStart; return e
    }
    private func names(_ r: Rig) -> [String] { r.focus.calls.map(\.name) }
    private func count(_ r: Rig, _ name: String) -> Int { r.focus.calls.filter { $0.name == name }.count }
    private func last(_ r: Rig, _ name: String) -> (name: String, taskID: Int, title: String, seconds: Int)? {
        r.focus.calls.last { $0.name == name }
    }
    private func lastMode(_ r: Rig) -> [Int] {
        r.settings.calls.compactMap { if $0.0 == "setLastMode", case .integer(let v) = $0.1 { v } else { nil } }
    }

    // MARK: 入口分流（openTask / FocusFlowHook）

    // 产品保证：入口信息无效时给出可见原因，且不启动任何计时。
    func testOpenTaskInvalidShowsReasonAndStartsNothing() {
        let r = rig([task(1)])
        r.focus.focusTaskEntry = entry("invalid", pomodoro: true, autoStart: true)
        r.store.openTask(taskId: 1, title: "任务1")
        XCTAssertEqual(r.store.errorText, "任务信息无效，无法开始计时")
        XCTAssertEqual(count(r, "startFree") + count(r, "startPomodoro"), 0)
    }
    // 产品保证：点的正是正在计时的任务时回到当前计时，不弹确认、不停表、选中项以计时器为准。
    func testOpenTaskReturnToCurrentSyncsWithoutStopping() {
        let r = rig([task(1), task(7)])
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 7, title: "任务7", remaining: 600, target: 1500)
        r.store.selectTask(id: 1, title: "任务1")
        r.focus.focusTaskEntry = entry("returnToCurrent", pomodoro: false, autoStart: true)
        r.store.openTask(taskId: 7, title: "任务7")
        XCTAssertNil(r.store.switchPrompt)
        XCTAssertEqual(count(r, "stopForSwitch"), 0)
        XCTAssertEqual(r.store.selectedTaskID, 7)
        XCTAssertTrue(r.store.pomodoroModeSelected)
    }
    // 产品保证：计时中点另一个任务先确认，确认之前不停表；框里写明将开始哪个任务和后果。
    func testOpenTaskConfirmSwitchWaitsForUserBeforeStopping() {
        let r = rig([task(1), task(7)])
        setTimer(r, mode: 0, phase: 0, active: true, taskID: 1, title: "任务1", elapsed: 1200)
        r.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: true, autoStart: true)
        r.focus.focusSwitchConsequence.kind = "saved"
        r.store.openTask(taskId: 7, title: "任务7")
        XCTAssertEqual(count(r, "stopForSwitch"), 0)
        XCTAssertEqual(r.store.switchPrompt?.message, "将开始：任务7。当前专注会先保存。")
        XCTAssertEqual(r.store.switchPrompt?.confirmTitle, "结束并开始")
        XCTAssertEqual(count(r, "startPomodoro") + count(r, "startFree"), 0)
    }
    // 产品保证：快速开始开启时按控制器给的模式直接计时，并记住这次的模式；两种模式写的值不同。
    func testOpenTaskApplyWithQuickStartStartsInPlannedModeAndRemembersIt() {
        let r = rig([task(3)])
        r.focus.focusTaskEntry = entry("apply", pomodoro: true, autoStart: true)
        r.store.selectWorkMinutes(45)
        r.store.openTask(taskId: 3, title: "任务3")
        XCTAssertEqual(last(r, "startPomodoro")?.seconds, 45 * 60)
        XCTAssertEqual(last(r, "startPomodoro")?.taskID, 3)
        XCTAssertEqual(lastMode(r), [1])
        let f = rig([task(3)])
        f.focus.focusTaskEntry = entry("apply", pomodoro: false, autoStart: true)
        f.store.openTask(taskId: 3, title: "任务3")
        XCTAssertEqual(last(f, "startFree")?.taskID, 3)
        XCTAssertEqual(lastMode(f), [0])
    }
    // 产品保证：快速开始关闭时只进入待机，不开始；番茄顺带展开时长面板，自由不展开。
    func testOpenTaskApplyWithoutQuickStartEntersStandby() {
        let p = rig([task(3)])
        p.focus.focusTaskEntry = entry("apply", pomodoro: true, autoStart: false)
        p.store.openTask(taskId: 3, title: "任务3")
        XCTAssertEqual(count(p, "startPomodoro"), 0)
        XCTAssertEqual(p.store.state, .pomoIdle)
        XCTAssertEqual(p.store.selectedTaskID, 3)
        XCTAssertTrue(p.store.panelExpanded)
        let f = rig([task(3)])
        f.focus.focusTaskEntry = entry("apply", pomodoro: false, autoStart: false)
        f.store.openTask(taskId: 3, title: "任务3")
        XCTAssertEqual(f.store.state, .free)
        XCTAssertFalse(f.store.panelExpanded)
        XCTAssertEqual(count(f, "startFree"), 0)
    }
    // 产品保证：平台不开放自由计时时，哪怕控制器说自由也一律按番茄处理，且自由入口报明确原因。
    func testPlatformWithoutFreeTimingAlwaysUsesPomodoro() {
        let r = rig([task(3)]) { focus, _ in focus.focusSnapshot.freeTimingAllowed = false }
        XCTAssertFalse(r.store.freeModeAvailable)
        XCTAssertTrue(r.store.pomodoroModeSelected)
        r.focus.focusTaskEntry = entry("apply", pomodoro: false, autoStart: true)
        r.store.openTask(taskId: 3, title: "任务3")
        XCTAssertEqual(count(r, "startFree"), 0)
        XCTAssertEqual(count(r, "startPomodoro"), 1)
        XCTAssertFalse(r.store.startFreeFocus())
        XCTAssertEqual(r.store.errorText, "这台设备暂时只支持番茄专注")
    }

    // MARK: 切换确认

    // 产品保证：三种切换后果各说各的，休息不能说成「专注不足不保存」。
    func testSwitchConsequenceTextsFollowController() {
        let cases: [(String, Int, String)] = [
            ("restKept", 3, "当前休息会保留在时间轴中。"),
            ("notSaved", 5, "当前专注不足 5 分钟，不会保存。"),
            ("saved", 3, "当前专注会先保存。")]
        for (kind, minutes, text) in cases {
            let r = rig([task(7)])
            setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "甲", remaining: 100, target: 1500)
            r.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: false, autoStart: false)
            r.focus.focusSwitchConsequence.kind = kind; r.focus.focusSwitchConsequence.minimumMinutes = minutes
            r.store.openTask(taskId: 7, title: "任务7")
            XCTAssertEqual(r.store.switchPrompt?.message, "将切换到自由专注：任务7，切换后不会自动开始。" + text, kind)
            XCTAssertEqual(r.store.switchPrompt?.confirmTitle, "结束并切换")
        }
    }
    // 产品保证：确认期间计时状态变了就拦下，不停新状态也不开始；确认时比对的是打开确认框那一刻记下的来源。
    func testConfirmSwitchStateChangedIsBlockedAndUsesSourceCapturedAtOpen() {
        let r = rig([task(7)])
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        var original = FocusSwitchSource(); original.taskID = 1; original.mode = 0; original.phase = 0
        r.focus.focusSwitchSource = original
        r.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: true, autoStart: true)
        r.store.openTask(taskId: 7, title: "任务7")
        var changed = original; changed.taskID = 2
        r.focus.focusSwitchSource = changed   // 确认前计时器换了任务
        r.focus.switchResult = "stateChanged"
        r.store.confirmSwitch()
        XCTAssertEqual(r.focus.switchSources, [original])
        XCTAssertEqual(r.store.errorText, "计时状态已变化，请重新选择任务")
        XCTAssertEqual(count(r, "startPomodoro"), 0)
        XCTAssertNil(r.store.switchPrompt)
    }
    // 产品保证：保存失败时不切换；停表成功才按确认前的意图落地；取消则什么都不动。
    func testConfirmSwitchOutcomes() {
        let failed = rig([task(7)])
        setTimer(failed, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        failed.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: true, autoStart: true)
        failed.store.openTask(taskId: 7, title: "任务7")
        failed.focus.switchResult = "stopFailed"; failed.store.confirmSwitch()
        XCTAssertEqual(failed.store.errorText, "当前计时保存失败，未切换")
        XCTAssertEqual(count(failed, "startPomodoro"), 0)

        let ok = rig([task(7)])
        setTimer(ok, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        ok.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: true, autoStart: true)
        ok.store.openTask(taskId: 7, title: "任务7")
        // 停表成功后计时器已空闲。
        ok.focus.switchResult = "stopped"; ok.focus.focusSnapshot = FocusSnapshot()
        ok.store.confirmSwitch()
        XCTAssertEqual(last(ok, "startPomodoro")?.taskID, 7)
        XCTAssertEqual(ok.store.errorText, "")

        let cancelled = rig([task(7)])
        setTimer(cancelled, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        cancelled.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: true, autoStart: true)
        cancelled.store.openTask(taskId: 7, title: "任务7")
        cancelled.store.cancelSwitch()
        XCTAssertNil(cancelled.store.switchPrompt)
        XCTAssertEqual(count(cancelled, "stopForSwitch"), 0)
    }
    // 产品保证：确认后发现是超长自由专注就转去超长确认，并记下确认后要做的动作（开始 / 只切待机两种不同）。
    func testConfirmSwitchLongFreeRemembersFollowUpAction() {
        for (autoStart, expected) in [(true, "startPomodoro"), (false, "enterPomodoro")] {
            let r = rig([task(7)])
            setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 40000)
            r.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: true, autoStart: autoStart)
            r.store.openTask(taskId: 7, title: "任务7")
            r.focus.switchResult = "needsLongFreeConfirmation"
            r.store.confirmSwitch()
            XCTAssertEqual(r.store.longFree?.action, expected)
            XCTAssertEqual(r.store.longFree?.taskID, 7)
            XCTAssertEqual(count(r, "startPomodoro"), 0)
        }
    }
    // 产品保证：页签切换在两个方向都经控制器停表（含超长自由确认），不凭页签自己推断。
    func testTabSwitchStopsThroughControllerInBothDirections() {
        let toPomo = rig()
        setTimer(toPomo, mode: 0, active: true, taskID: -1, title: "", elapsed: 90)
        toPomo.store.requestModeSwitch(usePomodoro: true)
        XCTAssertEqual(count(toPomo, "stopForSwitch"), 1)
        XCTAssertTrue(toPomo.store.pomodoroModeSelected)

        let toFree = rig()
        setTimer(toFree, mode: 1, phase: 1, active: true, taskID: -1, title: "", remaining: 100, target: 1500)
        XCTAssertTrue(toFree.store.pomodoroModeSelected)
        toFree.store.requestModeSwitch(usePomodoro: false)
        XCTAssertEqual(count(toFree, "stopForSwitch"), 1)
        XCTAssertFalse(toFree.store.pomodoroModeSelected)

        // 超长自由：两个方向都先确认，页签先不动。
        let longFree = rig()
        setTimer(longFree, mode: 0, active: true, elapsed: 40000)
        longFree.focus.switchResult = "needsLongFreeConfirmation"
        longFree.store.requestModeSwitch(usePomodoro: true)
        XCTAssertEqual(longFree.store.longFree?.action, "toPomodoro")
        XCTAssertFalse(longFree.store.pomodoroModeSelected)
        let reverse = rig()
        setTimer(reverse, mode: 1, phase: 1, active: true, remaining: 100, target: 1500)
        reverse.focus.switchResult = "needsLongFreeConfirmation"
        reverse.store.requestModeSwitch(usePomodoro: false)
        XCTAssertEqual(reverse.store.longFree?.action, "toFree")
        XCTAssertTrue(reverse.store.pomodoroModeSelected)
    }
    // 产品保证：停表失败时计时和页签都保持原样，并按方向说明失败。
    func testTabSwitchStopFailureKeepsTimerAndTab() {
        let toPomo = rig()
        setTimer(toPomo, mode: 0, active: true, elapsed: 90)
        toPomo.focus.switchResult = "stopFailed"
        toPomo.store.requestModeSwitch(usePomodoro: true)
        XCTAssertEqual(toPomo.store.errorText, "切换番茄失败，请重试")
        XCTAssertFalse(toPomo.store.pomodoroModeSelected)
        let toFree = rig()
        setTimer(toFree, mode: 1, phase: 1, active: true, remaining: 100, target: 1500)
        toFree.focus.switchResult = "stopFailed"
        toFree.store.requestModeSwitch(usePomodoro: false)
        XCTAssertEqual(toFree.store.errorText, "结束当前阶段失败，请重试")
        XCTAssertTrue(toFree.store.pomodoroModeSelected)
    }
    // 产品保证：切模式遇到有可继承任务的计时，先走确认框；确认后停在新模式待机，快速开始也不自动开始。
    func testModeSwitchWithInheritableTaskAsksAndNeverAutoStarts() {
        let r = rig([task(1)])
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        var plan = FocusModeSwitch(); plan.kind = "confirmSwitch"; plan.taskID = 1; plan.title = "任务1"
        r.focus.focusModeSwitch = plan
        r.store.requestModeSwitch(usePomodoro: true)
        XCTAssertEqual(r.store.switchPrompt?.autoStart, false)
        XCTAssertEqual(r.store.switchPrompt?.pomodoro, true)
        XCTAssertEqual(count(r, "stopForSwitch"), 0)
        r.focus.switchResult = "stopped"; r.focus.focusSnapshot = FocusSnapshot()
        r.store.confirmSwitch()
        XCTAssertEqual(count(r, "startPomodoro"), 0)
        XCTAssertEqual(r.store.state, .pomoIdle)
        XCTAssertEqual(r.store.selectedTaskID, 1)
    }

    // MARK: 结束

    // 产品保证：三种模式的结束各走各的入口——番茄页放弃整个循环，自由与休息结束当前会话。
    func testEndUsesEntryPointPerMode() {
        let pomodoro = rig([task(1)])
        setTimer(pomodoro, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 100, target: 1500)
        pomodoro.focus.focusEndResult = FocusEndResult(result: "ended", kind: "pomodoro")
        pomodoro.store.triggerSecondary()
        XCTAssertEqual(names(pomodoro).filter { $0.hasPrefix("end") }, ["endPomodoroCycle"])

        let free = rig([task(1)])
        setTimer(free, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        free.focus.focusEndResult = FocusEndResult(result: "ended", kind: "free")
        free.store.triggerSecondary()
        XCTAssertEqual(names(free).filter { $0.hasPrefix("end") }, ["endCurrent"])

        let rest = rig()
        setTimer(rest, mode: 2, phase: 3, active: true, elapsed: 30)
        rest.focus.focusEndResult = FocusEndResult(result: "ended", kind: "manualRest")
        rest.store.triggerSecondary()
        XCTAssertEqual(names(rest).filter { $0.hasPrefix("end") }, ["endCurrent"])
    }
    // 产品保证：结束成功后清选中、回到今日页；失败则保留选中和计时、不跳页，并显示控制器给的原因。
    func testEndResultsClearSelectionOrKeepItOnFailure() {
        let ok = rig([task(1)])
        setTimer(ok, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        ok.focus.focusEndResult = FocusEndResult(result: "ended", kind: "free")
        ok.store.endFreeFocus()
        XCTAssertEqual(ok.store.selectedTaskID, -1)
        XCTAssertTrue(ok.shellBridge.calls.contains("select:today"))

        let bad = rig([task(1)])
        setTimer(bad, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        bad.focus.focusEndResult = FocusEndResult(result: "failed", error: "保存没成功")
        bad.store.endFreeFocus()
        XCTAssertEqual(bad.store.errorText, "保存没成功")
        XCTAssertEqual(bad.store.selectedTaskID, 1)
        XCTAssertFalse(bad.shellBridge.calls.contains("select:today"))
    }
    // 产品保证：番茄的结束成功后连「刚完成」状态一起清掉，回到起点。
    func testEndPomodoroClearsCompletionState() {
        let r = rig([task(1)])
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 100, target: 1500)
        r.focus.onPhaseCompleted?(1)
        setTimer(r, mode: 0, phase: 0, active: false, taskID: 1, title: "任务1")
        XCTAssertEqual(r.store.state, .workDone)
        r.focus.focusEndResult = FocusEndResult(result: "ended", kind: "pomodoro")
        r.store.endPomodoro()
        XCTAssertEqual(r.store.justCompletedPhase, 0)
        XCTAssertEqual(r.store.selectedTaskID, -1)
    }

    // MARK: 超长自由专注

    // 产品保证：需要确认时只弹确认框，不结束、不丢弃；框里的阈值取自控制器，时长取自计时器，下限取自快照。
    func testNeedsConfirmationOpensLongFreeDialogWithoutEnding() {
        let r = rig([task(1)]) { focus, _ in focus.warningHours = 6 }
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 34200)
        r.focus.focusSnapshot.minimumValidMinutes = 5
        r.focus.focusEndResult = FocusEndResult(result: "needsConfirmation")
        r.store.endFreeFocus()
        XCTAssertEqual(r.store.longFree?.thresholdHours, 6)
        XCTAssertEqual(r.store.longFree?.elapsedSeconds, 34200)
        XCTAssertEqual(r.store.longFree?.minimumMinutes, 5)
        XCTAssertEqual(count(r, "finishLongFree"), 0)
        XCTAssertEqual(r.store.selectedTaskID, 1)
    }
    // 产品保证：确认记录、不记录各自把对应的选择交给控制器，成功后按「结束」收尾；继续计时什么也不交。
    func testLongFreeRecordDiscardContinue() {
        func opened() -> Rig {
            let r = rig([task(1)])
            setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 34200)
            r.focus.focusEndResult = FocusEndResult(result: "needsConfirmation")
            r.store.endFreeFocus()
            r.focus.focusFinishResult = { var f = FocusFinishResult(); f.ok = true; return f }()
            return r
        }
        let record = opened(); record.store.recordLongFree()
        XCTAssertEqual(record.focus.recordedLongFree, [true])
        XCTAssertEqual(last(record, "finishLongFree")?.seconds, -1)
        XCTAssertEqual(record.store.selectedTaskID, -1)
        XCTAssertNil(record.store.longFree)

        let discard = opened(); discard.store.discardLongFree()
        XCTAssertEqual(discard.focus.recordedLongFree, [false])

        let keep = opened(); keep.store.continueLongFree()
        XCTAssertNil(keep.store.longFree)
        XCTAssertEqual(count(keep, "finishLongFree"), 0)
        XCTAssertEqual(keep.store.selectedTaskID, 1)
    }
    // 产品保证：修正时长只接受整分钟、不少于有效下限、不超过实际计时；不合格零写入并留在框里提示，合格后按秒交给控制器。
    func testLongFreeCorrectionValidation() {
        let r = rig([task(1)])
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 34200)   // 9 小时 30 分
        r.focus.focusSnapshot.minimumValidMinutes = 5
        r.focus.focusEndResult = FocusEndResult(result: "needsConfirmation")
        r.store.endFreeFocus()
        r.focus.focusFinishResult.ok = true
        XCTAssertFalse(r.store.recordLongFree(correctedMinutes: nil))
        XCTAssertEqual(r.store.longFree?.adjustmentError, "请输入整分钟数")
        XCTAssertFalse(r.store.recordLongFree(correctedMinutes: 4))
        XCTAssertEqual(r.store.longFree?.adjustmentError, "记录时长不能少于 5 分钟")
        XCTAssertFalse(r.store.recordLongFree(correctedMinutes: 571))
        XCTAssertEqual(r.store.longFree?.adjustmentError, "记录时长不能超过实际计时的 9 小时 30 分钟")
        XCTAssertEqual(count(r, "finishLongFree"), 0)
        XCTAssertTrue(r.store.recordLongFree(correctedMinutes: 570))   // 恰等于实际计时：允许
        XCTAssertEqual(last(r, "finishLongFree")?.seconds, 34200)
        XCTAssertEqual(r.focus.recordedLongFree, [true])
    }
    // 产品保证：保存或丢弃失败时显示控制器给的文案，计时与选中保持原样，不当成已结束。
    func testLongFreeFinishFailureShowsControllerMessage() {
        let r = rig([task(1)])
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 34200)
        r.focus.focusEndResult = FocusEndResult(result: "needsConfirmation")
        r.store.endFreeFocus()
        r.focus.focusFinishResult.ok = false; r.focus.focusFinishResult.error = "磁盘已满"
        r.store.recordLongFree()
        XCTAssertEqual(r.store.errorText, "磁盘已满")
        XCTAssertEqual(r.store.selectedTaskID, 1)
        XCTAssertFalse(r.shellBridge.calls.contains("select:today"))
    }
    // 产品保证：仪表盘专注卡点「结束」而控制器要求超长确认时，切到专注页弹出结束确认，不直接结束；
    // 能直接结束时留在原页，不跳去今日任务页（对照 Mac MainWindow.endFocusFromDashboard）。
    func testDashboardEndSwitchesToFocusPageOnlyWhenConfirmationNeeded() {
        let confirm = rig([task(1)])
        setTimer(confirm, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 34200)
        confirm.focus.focusEndResult = FocusEndResult(result: "needsConfirmation")
        XCTAssertFalse(confirm.shellBridge.calls.contains("select:focus"))
        XCTAssertEqual(confirm.store.endFromDashboard(), .confirming)
        XCTAssertEqual(confirm.shellBridge.calls.last, "select:focus")
        XCTAssertEqual(confirm.store.longFree?.action, "end")
        XCTAssertEqual(count(confirm, "finishLongFree"), 0)
        XCTAssertEqual(confirm.store.selectedTaskID, 1)

        let ended = rig([task(1)])
        setTimer(ended, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        ended.focus.focusEndResult = FocusEndResult(result: "ended", kind: "free")
        XCTAssertEqual(ended.store.endFromDashboard(), .ended)
        XCTAssertFalse(ended.shellBridge.calls.contains("select:focus"))
        XCTAssertFalse(ended.shellBridge.calls.contains("select:today"))
        XCTAssertNil(ended.store.longFree)
    }

    // MARK: 候选、选择器与新建

    // 产品保证：选中项已被删时清掉选中，改用控制器给的候选；选中项有效时保留。
    func testAutoStartCandidateClearsStaleSelection() {
        let r = rig([task(4, "候选")])
        r.store.selectTask(id: 9, title: "已删")
        var stale = FocusCandidate(); stale.taskID = 4; stale.title = "候选"; stale.selectionStale = true
        r.focus.focusCandidate = stale
        let picked = r.store.autoStartCandidate()
        XCTAssertEqual(picked?.id, 4)
        XCTAssertEqual(r.store.selectedTaskID, -1)
        XCTAssertEqual(last(r, "autoStartCandidate")?.taskID, 9)

        let valid = rig([task(9, "仍在")])
        valid.store.selectTask(id: 9, title: "仍在")
        var keep = FocusCandidate(); keep.taskID = 9; keep.title = "仍在"; keep.selectionStale = false
        valid.focus.focusCandidate = keep
        XCTAssertEqual(valid.store.autoStartCandidate()?.id, 9)
        XCTAssertEqual(valid.store.selectedTaskID, 9)
    }
    // 产品保证：选择器里新建并开始，绑定的是服务返回的编号和去空白后的标题，不按标题反查。
    func testPickerCreateAndStartUsesServiceIDAndTrimmedTitle() {
        let r = rig([task(5, "同名")])
        r.focus.createdID = 77
        XCTAssertTrue(r.store.createTaskAndStart(title: "  同名 "))
        XCTAssertEqual(last(r, "startFree")?.taskID, 77)
        XCTAssertEqual(last(r, "startFree")?.title, "同名")
        let p = rig()
        p.store.requestModeSwitch(usePomodoro: true)
        p.focus.createdID = 78
        XCTAssertTrue(p.store.createTaskAndStart(title: "新番茄"))
        XCTAssertEqual(last(p, "startPomodoro")?.taskID, 78)
    }
    // 产品保证：新建失败时不开始任何计时，并说明原因。
    func testPickerCreateFailureStartsNothing() {
        let r = rig()
        r.focus.createdID = -1
        XCTAssertFalse(r.store.createTaskAndStart(title: "x"))
        XCTAssertEqual(r.store.errorText, "新建任务失败，请重试")
        XCTAssertEqual(count(r, "startFree") + count(r, "startPomodoro"), 0)
        let thrown = rig(); thrown.focus.failing = ["createTodayTask"]
        XCTAssertFalse(thrown.store.createTaskAndStart(title: "x"))
        XCTAssertEqual(thrown.store.errorText, "新建任务失败，请重试")
    }
    // 产品保证：待删任务不出现在选择器里；选中项恰是待删任务时先收起，撤销后还回去，真删了就不还。
    func testPendingDeletionHidesFromPickerAndRestoresSelectionOnUndo() {
        let r = rig([task(1), task(2)])
        r.store.selectTask(id: 2, title: "任务2")
        r.pending.requestTask(id: 2, title: "任务2")
        r.store.pendingDeletionChanged()
        XCTAssertEqual(r.store.selectedTaskID, -1)
        XCTAssertEqual(r.store.selectableTasks().map(\.id), [1])
        r.pendingBridge.cancel()
        r.store.pendingDeletionChanged()
        XCTAssertEqual(r.store.selectedTaskID, 2)

        let gone = rig([task(1), task(2)])
        gone.store.selectTask(id: 2, title: "任务2")
        gone.pending.requestTask(id: 2, title: "任务2")
        gone.store.pendingDeletionChanged()
        gone.tasks.tasksByID?[2] = nil      // 提交后任务真的没了
        gone.pendingBridge.cancel()
        gone.store.pendingDeletionChanged()
        XCTAssertEqual(gone.store.selectedTaskID, -1)
    }
    // 产品保证：任务被删或改名后，待启动的选中项跟着更新；只是读取失败时不丢用户的选择。
    func testSelectedTaskReconcilesOnTasksChanged() {
        let r = rig([task(2, "旧名")])
        r.store.selectTask(id: 2, title: "旧名")
        r.tasks.tasksByID?[2] = task(2, "新名")
        r.tasks.onChanged?()
        XCTAssertEqual(r.store.selectedTaskTitle, "新名")
        r.tasks.failing = ["task"]
        r.tasks.onChanged?()
        XCTAssertEqual(r.store.selectedTaskID, 2)
        r.tasks.failing = []; r.tasks.tasksByID?[2] = nil
        r.tasks.onChanged?()
        XCTAssertEqual(r.store.selectedTaskID, -1)
    }

    // MARK: 任务完成联动（FocusFlowHook.taskCompleted）

    // 产品保证：完成任务时的专注结果四种映射各不相同；已结束带上是否因不足而丢弃，失败与需要确认不混淆。
    func testTaskCompletedMapsAllOutcomes() {
        func outcome(_ result: String, discarded: Bool = false, kind: String = "free", error: String = "") -> TaskCompletionFocusOutcome {
            let r = rig([task(1)])
            setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
            r.focus.focusTaskCompletion = FocusTaskCompletion(focusResult: result, kind: kind, discarded: discarded, error: error)
            return r.store.taskCompleted(taskId: 1)
        }
        XCTAssertEqual(outcome("none"), .none)
        XCTAssertEqual(outcome("ended"), .ended(discarded: false))
        XCTAssertEqual(outcome("ended", discarded: true), .ended(discarded: true))
        XCTAssertEqual(outcome("failed", error: "停不掉"), .failed)
        XCTAssertEqual(outcome("needsConfirmation"), .needsConfirmation)
    }
    // 产品保证：完成任务顺带结束专注时留在原页（不跳今日页），失败原因留在专注页错误行，需要确认时弹超长确认。
    func testTaskCompletedEndsInPlaceAndExplainsFailureOrConfirmation() {
        let ended = rig([task(1)])
        setTimer(ended, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        ended.focus.focusTaskCompletion = FocusTaskCompletion(focusResult: "ended", kind: "free", discarded: false, error: "")
        _ = ended.store.taskCompleted(taskId: 1)
        XCTAssertFalse(ended.shellBridge.calls.contains("select:today"))
        XCTAssertEqual(ended.store.selectedTaskID, -1)

        let failed = rig([task(1)])
        setTimer(failed, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        failed.focus.focusTaskCompletion = FocusTaskCompletion(focusResult: "failed", kind: "", discarded: false, error: "停不掉")
        _ = failed.store.taskCompleted(taskId: 1)
        XCTAssertEqual(failed.store.errorText, "停不掉")

        let confirm = rig([task(1)])
        setTimer(confirm, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 40000)
        confirm.focus.focusTaskCompletion = FocusTaskCompletion(focusResult: "needsConfirmation", kind: "", discarded: false, error: "")
        _ = confirm.store.taskCompleted(taskId: 1)
        XCTAssertEqual(confirm.store.longFree?.action, "end")
        XCTAssertEqual(count(confirm, "finishLongFree"), 0)
    }
    // 产品保证：完成任务顺带停表时，计时器同步发出的「不足 3 分钟」不单独弹提示（由完成提示一并说明）；平时照常提示。
    func testDiscardToastSuppressedOnlyWhileEndingForCompletion() {
        let r = rig([task(1)])
        r.focus.onHandleCompleted = { r.focus.onSessionDiscarded?(100) }
        r.focus.focusTaskCompletion = FocusTaskCompletion(focusResult: "ended", kind: "free", discarded: true, error: "")
        _ = r.store.taskCompleted(taskId: 1)
        XCTAssertNil(r.shell.toast)
        r.focus.onSessionDiscarded?(100)
        XCTAssertEqual(r.shell.toast?.message, "本次专注不足 3 分钟，未计入记录")
    }
    // 产品保证：控制器没有可结束的计时（或调用失败）时，完成任务不受影响。
    func testTaskCompletedWithoutTimerIsNone() {
        let r = rig([task(1)])
        XCTAssertEqual(r.store.taskCompleted(taskId: 1), .none)
        r.focus.failing = ["handleTaskCompleted"]
        XCTAssertEqual(r.store.taskCompleted(taskId: 1), .none)
    }

    // MARK: 提示

    // 产品保证：计时相关的提示文案与 Mac 一字不差，空消息有兜底。
    func testToastTexts() {
        let r = rig()
        func toast(_ fire: () -> Void) -> String? { fire(); return r.shell.toast?.message }
        XCTAssertEqual(toast { r.focus.onTaskAutoCompleteFailed?(1) }, "专注记录已保存，但任务自动完成失败，请手动检查")
        XCTAssertEqual(toast { r.focus.onFailure?("") }, "专注操作失败")
        XCTAssertEqual(toast { r.focus.onFailure?("磁盘满") }, "磁盘满")
        XCTAssertEqual(toast { r.focus.onPhaseSettledOffline?(1) }, "离开期间番茄已到点，已记为完成")
        XCTAssertEqual(toast { r.focus.onPhaseSettledOffline?(2) }, "离开期间休息已结束")
        XCTAssertEqual(toast { r.focus.onAlarmUnavailable?("未授权") }, "到点提醒没有预约成功（未授权），离开应用后不会提醒")
        XCTAssertEqual(toast { r.focus.onNotificationDeliveryFailed?("被拒绝") }, "系统通知没有发出（被拒绝）")
    }

    // MARK: 自动衔接与长休息

    private func finishWork(_ r: Rig) {
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 100, target: 1500)
        r.focus.onPhaseCompleted?(1)
        setTimer(r, mode: 0, phase: 0, active: false, taskID: 1, title: "任务1")
    }
    // 产品保证：开关开着时，工作段自然完成后延迟一小会自动开始休息，休息时长取自控制器的长休息判定（≠所选时长）。
    func testAutoAdvanceStartsBreakWithLongBreakMinutes() {
        let r = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true]; focus.longBreakMinutes = 15 }
        finishWork(r)
        XCTAssertEqual(r.store.state, .workDone)
        XCTAssertEqual(r.scheduler.items.count, 1)
        XCTAssertEqual(r.scheduler.items.first?.delay, 0.9)
        r.scheduler.fire(0)
        XCTAssertEqual(last(r, "startBreak")?.seconds, 900)
        XCTAssertEqual(last(r, "startBreak")?.taskID, 1)
        XCTAssertEqual(r.store.justCompletedPhase, 0)
    }
    // 产品保证：开关关着（默认）时只停在完成态，不衔接。
    func testAutoAdvanceOffOnlyShowsCompletion() {
        let r = rig([task(1)])
        finishWork(r)
        XCTAssertEqual(r.store.state, .workDone)
        XCTAssertTrue(r.scheduler.items.isEmpty)
        XCTAssertEqual(count(r, "startBreak"), 0)
    }
    // 产品保证：休息结束后开着「自动开始下一个番茄」就用所选时长开始新一轮，沿用缓存的任务。
    func testAutoAdvanceStartsNextPomodoroAfterBreak() {
        let r = rig([task(1)]) { focus, _ in focus.autoAdvance = [2: true] }
        r.store.selectTask(id: 1, title: "任务1"); r.store.selectWorkMinutes(50)
        setTimer(r, mode: 1, phase: 2, active: true, taskID: -1, title: "", remaining: 10, target: 300)
        r.focus.onPhaseCompleted?(2)
        setTimer(r, mode: 0, phase: 0, active: false)
        XCTAssertEqual(r.store.state, .breakDone)
        r.scheduler.fire(0)
        XCTAssertEqual(last(r, "startPomodoro")?.seconds, 3000)
        XCTAssertEqual(last(r, "startPomodoro")?.taskID, 1)
    }
    // 产品保证：延迟期间用户把开关关了，到点那一刻再问一次，不衔接（不能只看完成时的旧答案）。
    func testAutoAdvanceAsksAgainWhenDelayElapses() {
        let r = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true] }
        finishWork(r)
        r.focus.autoAdvance[1] = false
        r.scheduler.fire(0)
        XCTAssertEqual(count(r, "startBreak"), 0)
        XCTAssertEqual(r.store.state, .workDone)
    }
    // 产品保证：开关变化的信号一到就取消等待中的衔接，不用等到点。
    func testSettingChangeCancelsPendingAutoAdvance() {
        let r = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true] }
        finishWork(r)
        r.focus.autoAdvance[1] = false
        r.settings.onAutoStartBreakChanged?()
        XCTAssertEqual(r.scheduler.live, [])
        let still = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true] }
        finishWork(still)
        still.settings.onAutoStartBreakChanged?()
        XCTAssertEqual(still.scheduler.live, [0])
    }
    // 产品保证：等待期间「刚完成的阶段」变了（例如又完成了别的阶段），旧的衔接不能把新状态带偏。
    func testStaleAutoAdvanceDoesNothingAfterCompletedPhaseChanged() {
        let r = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true, 2: false] }
        finishWork(r)
        r.focus.onPhaseCompleted?(2)           // 新的完成态，且 2 不衔接
        XCTAssertEqual(r.store.justCompletedPhase, 2)
        r.scheduler.fire(0, ignoringCancel: true)
        XCTAssertEqual(count(r, "startBreak"), 0)
    }
    // 产品保证：系统「减少动态效果」打开时立即衔接（延迟为 0），否则留缓冲。
    func testAutoAdvanceDelayFollowsReduceMotion() {
        let r = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true] }
        r.flag.reduceMotion = true
        finishWork(r)
        XCTAssertEqual(r.scheduler.items.first?.delay, 0)
    }
    // 产品保证：用户在别的页时衔接照样发生，并提示一句；盯着专注页时不重复提示。
    func testAutoAdvanceToastOnlyWhenNotOnFocusPage() {
        let away = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true] }
        finishWork(away); away.scheduler.fire(0)
        XCTAssertEqual(away.shell.toast?.message, "专注完成，已自动开始休息")
        let here = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true] }
        here.shell.select(.focus)
        finishWork(here); here.scheduler.fire(0)
        XCTAssertEqual(count(here, "startBreak"), 1)
        XCTAssertNil(here.shell.toast)
    }
    // 产品保证：开始休息失败时保留完成态，用户还能重试，也不假装衔接成功。
    func testFailedBreakStartKeepsCompletionStateForRetry() {
        let r = rig([task(1)]) { focus, _ in focus.autoAdvance = [1: true] }
        finishWork(r)
        r.focus.failing = ["startBreak"]
        r.scheduler.fire(0)
        XCTAssertEqual(r.store.errorText, "休息启动失败")
        XCTAssertEqual(r.store.state, .workDone)
        XCTAssertNil(r.shell.toast)
        r.focus.failing = []
        XCTAssertTrue(r.store.startBreak())
        XCTAssertEqual(r.store.state == .workDone, false)
    }
    // 产品保证：手动开始休息同样使用长休息判定，不是所选时长。
    func testManualBreakUsesLongBreakMinutes() {
        let r = rig([task(1)]) { focus, _ in focus.longBreakMinutes = 20 }
        r.store.selectBreakMinutes(7)
        finishWork(r)
        r.store.triggerPrimary()
        XCTAssertEqual(last(r, "startBreak")?.seconds, 1200)
    }
    // 产品保证：休息结束后「开始专注」用缓存的任务重开一轮；缓存也没有时按钮不可用。
    func testBreakDoneRestartsWithCachedTask() {
        let r = rig([task(1)])
        setTimer(r, mode: 1, phase: 2, active: true, taskID: 1, title: "任务1", remaining: 10, target: 300)
        r.focus.onPhaseCompleted?(2)
        setTimer(r, mode: 0, phase: 0, active: false)
        XCTAssertEqual(r.store.state, .breakDone)
        XCTAssertTrue(r.store.primaryButtonEnabled)
        r.store.triggerPrimary()
        XCTAssertEqual(last(r, "startPomodoro")?.taskID, 1)
        let empty = rig()
        empty.store.requestModeSwitch(usePomodoro: true)
        empty.focus.onPhaseCompleted?(2)
        XCTAssertEqual(empty.store.state, .breakDone)
        XCTAssertFalse(empty.store.primaryButtonEnabled)
    }

    // MARK: 开始、暂停与时长

    // 产品保证：开始失败时不记忆模式也不假装成功。
    func testStartFailureDoesNotRememberMode() {
        let r = rig([task(1)])
        r.store.selectTask(id: 1, title: "任务1")
        r.focus.failing = ["startFree"]
        XCTAssertFalse(r.store.startFreeFocus())
        XCTAssertEqual(r.store.errorText, "自由专注启动失败，请重试")
        r.store.requestModeSwitch(usePomodoro: true)
        r.focus.failing = ["startPomodoro"]
        XCTAssertFalse(r.store.startPomodoro())
        XCTAssertEqual(r.store.errorText, "番茄专注启动失败")
        XCTAssertEqual(lastMode(r), [])
        let none = rig()
        XCTAssertFalse(none.store.startFreeFocus())
        XCTAssertEqual(none.store.errorText, "请先选择要专注的任务")
    }
    // 产品保证：时长只接受范围内的值并写回设置；越界不改选中也不写；设置端的变化会反映到待机选择。
    func testDurationRangesAndSettingsSync() {
        let r = rig()
        r.store.selectWorkMinutes(4); r.store.selectWorkMinutes(181)
        r.store.selectBreakMinutes(0); r.store.selectBreakMinutes(61)
        XCTAssertEqual(r.store.selectedWorkMinutes, 25); XCTAssertEqual(r.store.selectedBreakMinutes, 5)
        XCTAssertTrue(r.settings.calls.filter { $0.0.hasPrefix("setWork") || $0.0.hasPrefix("setBreak") }.isEmpty)
        r.store.selectWorkMinutes(5); r.store.selectWorkMinutes(180); r.store.selectBreakMinutes(1); r.store.selectBreakMinutes(60)
        XCTAssertEqual(r.store.selectedWorkMinutes, 180); XCTAssertEqual(r.store.selectedBreakMinutes, 60)
        XCTAssertEqual(r.settings.result.workMinutes, 180); XCTAssertEqual(r.settings.result.breakMinutes, 60)
        r.settings.result.workMinutes = 30; r.settings.onWorkMinutesChanged?()
        XCTAssertEqual(r.store.selectedWorkMinutes, 30)
        r.settings.result.breakMinutes = 99; r.settings.onBreakMinutesChanged?()
        XCTAssertEqual(r.store.selectedBreakMinutes, 60)
    }
    // 产品保证：启动时恢复上次记住的时长；无效的保存值回落默认。
    func testRestoresRememberedDurations() {
        let r = rig { _, settings in settings.result.workMinutes = 52; settings.result.breakMinutes = 12 }
        XCTAssertEqual(r.store.selectedWorkMinutes, 52); XCTAssertEqual(r.store.selectedBreakMinutes, 12)
        let bad = rig { _, settings in settings.result.workMinutes = 0; settings.result.breakMinutes = 500 }
        XCTAssertEqual(bad.store.selectedWorkMinutes, 25); XCTAssertEqual(bad.store.selectedBreakMinutes, 5)
    }
    // 产品保证：界面创建前就在跑的会话要被读到——自由与番茄各自恢复模式、任务。
    func testRestoredTimerIsReadOnStart() {
        let free = rig([task(7)]) { focus, _ in
            focus.focusSnapshot.hasActiveSession = true; focus.focusSnapshot.mode = 0
            focus.focusSnapshot.currentTaskID = 7; focus.focusSnapshot.currentTaskTitle = "任务7" }
        XCTAssertFalse(free.store.pomodoroModeSelected)
        XCTAssertEqual(free.store.selectedTaskID, 7)
        let pomo = rig([task(7)]) { focus, _ in
            focus.focusSnapshot.hasActiveSession = true; focus.focusSnapshot.mode = 1; focus.focusSnapshot.phase = 1
            focus.focusSnapshot.currentTaskID = 7; focus.focusSnapshot.currentTaskTitle = "任务7" }
        XCTAssertTrue(pomo.store.pomodoroModeSelected)
        XCTAssertEqual(pomo.store.state, .pomoWork)
    }

    // MARK: ⌘↩

    // 产品保证：计时中 ⌘↩ 暂停，再按继续，并各提示一句；休息的措辞不同。
    func testShortcutTogglesRunningTimerWithToast() {
        let r = rig([task(1)])
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 700)
        r.store.startOrPauseFromShortcut()
        XCTAssertEqual(count(r, "pause"), 1)
        XCTAssertEqual(r.shell.toast?.message, "已暂停专注")
        r.store.startOrPauseFromShortcut()
        XCTAssertEqual(count(r, "resume"), 1)
        XCTAssertEqual(r.shell.toast?.message, "已继续专注")
        let rest = rig()
        setTimer(rest, mode: 2, phase: 3, active: true, elapsed: 30)
        rest.store.startOrPauseFromShortcut()
        XCTAssertEqual(rest.shell.toast?.message, "已暂停休息")
    }
    // 产品保证：空闲时 ⌘↩ 切到专注页，用控制器挑的候选按当前模式开始。
    func testShortcutWhenIdleStartsCandidateInCurrentMode() {
        let r = rig([task(4, "候选")])
        var c = FocusCandidate(); c.taskID = 4; c.title = "候选"; r.focus.focusCandidate = c
        r.store.startOrPauseFromShortcut()
        XCTAssertTrue(r.shellBridge.calls.contains("select:focus"))
        XCTAssertEqual(last(r, "startFree")?.taskID, 4)
        let p = rig([task(4, "候选")])
        p.store.requestModeSwitch(usePomodoro: true); p.focus.focusCandidate = c
        p.store.startOrPauseFromShortcut()
        XCTAssertEqual(last(p, "startPomodoro")?.taskID, 4)
    }
    // 产品保证：空闲且取不到候选时展开选择器并提示；取到了但启动失败时不能谎报「没有任务」。
    func testShortcutWithoutCandidateOpensSelectorAndSaysSo() {
        let r = rig()
        r.store.startOrPauseFromShortcut()
        XCTAssertTrue(r.store.taskSelectorPresented)
        XCTAssertEqual(r.shell.toast?.message, "今天还没有可以开始的任务，挑一条或新建一个")
        XCTAssertEqual(count(r, "startFree"), 0)
        let failing = rig([task(4)])
        var c = FocusCandidate(); c.taskID = 4; c.title = "任务4"; failing.focus.focusCandidate = c
        failing.focus.failing = ["startFree"]
        failing.store.startOrPauseFromShortcut()
        XCTAssertFalse(failing.store.taskSelectorPresented)
        XCTAssertNil(failing.shell.toast)
        XCTAssertEqual(failing.store.errorText, "自由专注启动失败，请重试")
    }

    // MARK: 记一笔带来源与外壳文字

    // 产品保证：记一笔的来源计时中取计时器的任务、待机取选中项，并继承任务的科目；主动休息、沉浸、没有任务时没有来源。
    func testCaptureSourceFollowsTimerOrSelection() {
        let r = rig([task(3, category: 8), task(6, category: 9)])
        XCTAssertNil(r.store.captureSource)
        r.store.selectTask(id: 3, title: "任务3")
        XCTAssertEqual(r.store.captureSource, ShellCaptureSource(taskID: 3, categoryID: 8))
        setTimer(r, mode: 0, active: true, taskID: 6, title: "任务6", elapsed: 10)
        XCTAssertEqual(r.store.captureSource, ShellCaptureSource(taskID: 6, categoryID: 9))
        r.store.enterImmersive()
        XCTAssertNil(r.store.captureSource)
        let uncategorized = rig([task(3)])
        uncategorized.store.selectTask(id: 3, title: "任务3")
        XCTAssertEqual(uncategorized.store.captureSource, ShellCaptureSource(taskID: 3, categoryID: -1))
        let rest = rig([task(3, category: 8)])
        setTimer(rest, mode: 2, phase: 3, active: true, taskID: 3, title: "休息")
        XCTAssertNil(rest.store.captureSource)
    }
    // 产品保证：专注页记一笔把提供者给的来源一并写入；其它页无来源；每次打开现取。
    func testShellCapturePassesSourceFromProvider() {
        let bridge = ShellBridgeFake(); let shell = ShellStore(bridge: bridge)
        shell.captureTitle = "无来源"; shell.presentCapture(); XCTAssertTrue(shell.capture())
        XCTAssertEqual(bridge.calls.last, "capture:无来源:-1:-1")
        var source: ShellCaptureSource? = ShellCaptureSource(taskID: 12, categoryID: 5)
        shell.captureSourceProvider = { source }
        shell.select(.focus)
        shell.captureTitle = "有来源"; shell.presentCapture(); XCTAssertTrue(shell.capture())
        XCTAssertEqual(bridge.calls.last, "capture:有来源:5:12")
        source = nil
        shell.captureTitle = "又无来源"; shell.presentCapture(); XCTAssertTrue(shell.capture())
        XCTAssertEqual(bridge.calls.last, "capture:又无来源:-1:-1")
    }
    // 产品保证：迷你计时条文字按阶段——工作与自由显示任务名，休息段显示「休息」，没有名字时退回「专注」。
    func testMiniTimerLabelByPhase() {
        let r = rig()
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "背单词", remaining: 100, target: 1500)
        XCTAssertEqual(r.store.miniTimerLabel, "背单词")
        setTimer(r, mode: 0, phase: 0, active: true, taskID: 1, title: "自由练习", elapsed: 5)
        XCTAssertEqual(r.store.miniTimerLabel, "自由练习")
        setTimer(r, mode: 1, phase: 2, active: true, taskID: 1, title: "背单词", remaining: 50, target: 300)
        XCTAssertEqual(r.store.miniTimerLabel, "休息")
        setTimer(r, mode: 2, phase: 3, active: true, taskID: -1, title: "", elapsed: 5)
        XCTAssertEqual(r.store.miniTimerLabel, "休息")
        setTimer(r, mode: 0, phase: 0, active: true, taskID: 1, title: "", elapsed: 5)
        XCTAssertEqual(r.store.miniTimerLabel, "专注")
    }

    // MARK: 展示派生与沉浸

    // 产品保证：圆环进度按剩余比例消退，待机与完成态是满环；暂停变暗；时间与说明文字格式固定。
    func testRingAndTimeProjection() {
        let r = rig([task(1)])
        r.store.requestModeSwitch(usePomodoro: true)
        XCTAssertEqual(r.store.state, .pomoIdle)
        XCTAssertEqual(r.store.primaryTimeText, "25:00")
        XCTAssertEqual(r.store.ringProgress, 1)
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 300, target: 1500)
        XCTAssertEqual(r.store.primaryTimeText, "05:00")
        XCTAssertEqual(r.store.ringProgress, 0.2, accuracy: 0.0001)
        XCTAssertEqual(r.store.ringCaption, "剩余 · 共 25 分")
        XCTAssertEqual(r.store.stageText, "专注中")
        setTimer(r, mode: 1, phase: 1, running: false, active: true, taskID: 1, title: "任务1", remaining: 300, target: 1500)
        XCTAssertTrue(r.store.ringDimmed)
        XCTAssertEqual(r.store.stageText, "⏸ 专注已暂停")
        XCTAssertEqual(r.store.ringCaption, "已暂停 · 共 25 分")
        r.focus.onPhaseCompleted?(1)
        XCTAssertEqual(r.store.primaryTimeText, "00:00")
        XCTAssertEqual(r.store.ringProgress, 1)
        let free = rig()
        setTimer(free, mode: 0, active: true, taskID: 1, title: "x", elapsed: 3723)
        XCTAssertEqual(free.store.primaryTimeText, "01:02:03")
    }
    // 产品保证：沉浸只在计时进行中（含暂停）进入；计时结束落到待机时自动退出，不留空白全屏。
    func testImmersiveOnlyWhileTimingAndAutoExits() {
        let r = rig([task(1)])
        r.store.enterImmersive()
        XCTAssertFalse(r.store.immersiveActive)
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 100, target: 1500)
        r.store.enterImmersive()
        XCTAssertTrue(r.store.immersiveActive)
        setTimer(r, mode: 0, phase: 0, active: false)
        XCTAssertFalse(r.store.immersiveActive)
    }
    // 产品保证：空闲菜单的番茄时长经设置投影到控制器，自由选项经既有切换路径。
    func testR2IdleMenuMapsPresetsAndFreeMode() {
        let r = rig([task(7)])
        r.store.selectIdleTask(id: 7, title: "任务7")
        r.store.selectModePreset(minutes: 45)
        XCTAssertTrue(r.store.pomodoroModeSelected)
        XCTAssertEqual(r.store.selectedWorkMinutes, 45)
        XCTAssertTrue(r.store.startCurrentMode())
        XCTAssertEqual(last(r, "startPomodoro")?.seconds, 2700)
        r.store.selectModePreset(minutes: nil)
        XCTAssertFalse(r.store.pomodoroModeSelected)
        XCTAssertTrue(r.store.startCurrentMode())
        XCTAssertEqual(last(r, "startFree")?.taskID, 7)
    }
    // 产品保证：计时中的菜单与任务入口只读，不写设置、不换待选任务、不停当前会话。
    func testR2ActiveSessionIgnoresIdleMenus() {
        let r = rig([task(7), task(2)])
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 7, title: "任务7", remaining: 600, target: 1500)
        let before = r.settings.calls.count
        r.store.selectIdleTask(id: 2, title: "任务2")
        r.store.selectModePreset(minutes: 60)
        r.store.selectModePreset(minutes: nil)
        XCTAssertEqual(r.store.selectedTaskID, 7)
        XCTAssertEqual(r.settings.calls.count, before)
        XCTAssertEqual(count(r, "stopForSwitch"), 0)
        XCTAssertTrue(r.store.pomodoroModeSelected)
    }
    // 产品保证：圆环里时间下面一行按阶段写——工作段写「第几个番茄 · 共几分」，暂停统一「已暂停」，休息、自由、主动休息、完成各有说法。
    func testRingStatusTextByPhase() {
        let r = rig([task(1)])
        // 已完成 2 个时正在做的是第 3 个：用非 0 的完成数，区分「直接用完成数」的错误写法。
        r.focus.focusSnapshot.completedPomodoros = 2
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 600, target: 1500)
        XCTAssertEqual(r.store.ringStatusText, "第 3 个番茄 · 共 25 分")
        setTimer(r, mode: 1, phase: 1, running: false, active: true, taskID: 1, title: "任务1", remaining: 600, target: 1500)
        XCTAssertEqual(r.store.ringStatusText, "已暂停 · 共 25 分")
        setTimer(r, mode: 1, phase: 2, active: true, taskID: 1, title: "任务1", remaining: 200, target: 300)
        XCTAssertEqual(r.store.ringStatusText, "休息 · 共 5 分")
        r.focus.onPhaseCompleted?(2)
        XCTAssertEqual(r.store.ringStatusText, "休息结束")
        let free = rig([task(1)])
        setTimer(free, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 90)
        XCTAssertEqual(free.store.ringStatusText, "自由计时")
        setTimer(free, mode: 0, running: false, active: true, taskID: 1, title: "任务1", elapsed: 90)
        XCTAssertEqual(free.store.ringStatusText, "已暂停")
        setTimer(free, mode: 2, phase: 3, active: true, elapsed: 30)
        XCTAssertEqual(free.store.ringStatusText, "主动休息")
    }

    // MARK: 计时控制自动隐藏
    // 视图在 controlsAutoHideKey 变化时调 syncControlsAutoHide；测试在每次改状态后手动调一次，模拟这条接线。
    private func controlsTimers(_ r: Rig) -> [Int] {
        r.scheduler.items.indices.filter { r.scheduler.items[$0].delay == FocusStore.controlsHideDelay }
    }
    // 还在等的隐藏计时：没取消、也没触发过。
    private func liveControlsTimers(_ r: Rig) -> [Int] {
        controlsTimers(r).filter { !r.scheduler.items[$0].cancelled && !r.scheduler.items[$0].fired }
    }

    // 产品保证：专注页计时进行中，3 秒无操作后按钮与工具栏隐藏；到点之前不隐藏。
    func testControlsHideThreeSecondsAfterTimingStarts() {
        let r = rig([task(1)])
        r.store.setPageActive(true)
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 600, target: 1500)
        r.store.syncControlsAutoHide()
        XCTAssertFalse(r.store.controlsHidden)
        XCTAssertEqual(FocusStore.controlsHideDelay, 3)
        XCTAssertEqual(liveControlsTimers(r).count, 1)
        r.scheduler.fire(liveControlsTimers(r)[0])
        XCTAssertTrue(r.store.controlsHidden)
    }
    // 产品保证：每秒走字不会把隐藏计时一直往后推；暂停、换阶段这类状态变化会先露出按钮再从头计时。
    func testTicksKeepTimerButStateChangesRevealControls() {
        let r = rig([task(1)])
        r.store.setPageActive(true)
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 600, target: 1500)
        r.store.syncControlsAutoHide()
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 599, target: 1500)
        r.store.syncControlsAutoHide()
        XCTAssertEqual(controlsTimers(r).count, 1, "走字不该重排隐藏计时")
        r.scheduler.fire(liveControlsTimers(r)[0])
        XCTAssertTrue(r.store.controlsHidden)
        // 自动进入休息（仍在走）：先露出，再重新计 3 秒。
        setTimer(r, mode: 1, phase: 2, active: true, taskID: 1, title: "任务1", remaining: 300, target: 300)
        r.store.syncControlsAutoHide()
        XCTAssertFalse(r.store.controlsHidden)
        XCTAssertEqual(liveControlsTimers(r).count, 1)
        XCTAssertEqual(controlsTimers(r).count, 2)
    }
    // 产品保证：点屏幕唤醒后按钮立刻出现，并从唤醒那一刻重新计 3 秒，旧计时作废。
    func testWakeRevealsAndRestartsTimer() {
        let r = rig([task(1)])
        r.store.setPageActive(true)
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 60)
        r.store.syncControlsAutoHide()
        let first = liveControlsTimers(r)[0]
        r.scheduler.fire(first)
        XCTAssertTrue(r.store.controlsHidden)
        r.store.wakeControls()
        XCTAssertFalse(r.store.controlsHidden)
        XCTAssertEqual(liveControlsTimers(r).count, 1)
        XCTAssertNotEqual(liveControlsTimers(r)[0], first)
        r.store.wakeControls()
        XCTAssertEqual(liveControlsTimers(r).count, 1, "连续唤醒只留最新一个计时")
    }
    // 产品保证：暂停时按钮一直在（等用户继续）；暂停前排下的旧计时迟到触发也不会把按钮藏掉。
    func testPausedNeverHidesEvenIfStaleTimerFires() {
        let r = rig([task(1)])
        r.store.setPageActive(true)
        setTimer(r, mode: 1, phase: 1, active: true, taskID: 1, title: "任务1", remaining: 600, target: 1500)
        r.store.syncControlsAutoHide()
        let stale = liveControlsTimers(r)[0]
        setTimer(r, mode: 1, phase: 1, running: false, active: true, taskID: 1, title: "任务1", remaining: 600, target: 1500)
        XCTAssertTrue(r.store.ringDimmed, "前提：已进入暂停")
        r.store.syncControlsAutoHide()
        XCTAssertTrue(liveControlsTimers(r).isEmpty)
        r.scheduler.fire(stale, ignoringCancel: true)
        XCTAssertFalse(r.store.controlsHidden)
        // 待机（还没开始）同样不藏。
        let idle = rig([task(1)])
        idle.store.setPageActive(true)
        idle.store.requestModeSwitch(usePomodoro: true)
        idle.store.syncControlsAutoHide()
        XCTAssertEqual(idle.store.state, .pomoIdle)
        XCTAssertTrue(liveControlsTimers(idle).isEmpty)
    }
    // 产品保证：旁白开着、记一笔浮层或确认框开着时不隐藏；离开专注页立刻露出，别的页的记一笔不受影响。
    func testAssistivePromptsAndLeavingPageKeepControlsVisible() {
        let r = rig([task(1)])
        r.store.setPageActive(true)
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 60)
        r.store.setAssistiveTechnologyActive(true)
        r.store.syncControlsAutoHide()
        XCTAssertTrue(liveControlsTimers(r).isEmpty)
        r.store.setAssistiveTechnologyActive(false)
        r.shell.capturePresented = true
        r.store.syncControlsAutoHide()
        XCTAssertTrue(liveControlsTimers(r).isEmpty)
        r.shell.capturePresented = false
        r.store.syncControlsAutoHide()
        r.scheduler.fire(liveControlsTimers(r)[0])
        XCTAssertTrue(r.store.controlsHidden, "前提：已隐藏")
        r.store.setPageActive(false)
        XCTAssertFalse(r.store.controlsHidden)
        XCTAssertTrue(liveControlsTimers(r).isEmpty)
        // 回到本页：状态没变也要重新计时，否则按钮会一直挂着。
        r.store.setPageActive(true)
        r.store.syncControlsAutoHide()
        XCTAssertEqual(liveControlsTimers(r).count, 1)
    }

    // 产品保证：切换确认框唤醒已隐藏的计时控制，等待确认期间不隐藏，取消后重新计时一次。
    func testSwitchPromptRevealsControlsAndDefersAutoHide() throws {
        let r = rig([task(1), task(7)])
        r.store.setPageActive(true)
        setTimer(r, mode: 0, active: true, taskID: 1, title: "任务1", elapsed: 1200)
        r.store.syncControlsAutoHide()
        XCTAssertEqual(liveControlsTimers(r).count, 1)
        r.scheduler.fire(try XCTUnwrap(liveControlsTimers(r).first))
        XCTAssertTrue(r.store.controlsHidden, "前提：计时中控制已隐藏")
        r.focus.focusTaskEntry = entry("confirmSwitch", pomodoro: true, autoStart: true)
        r.focus.focusSwitchConsequence.kind = "saved"
        r.store.openTask(taskId: 7, title: "任务7")
        XCTAssertNotNil(r.store.switchPrompt, "前提：切换确认框已打开")
        r.store.syncControlsAutoHide()
        XCTAssertFalse(r.store.controlsHidden)
        XCTAssertTrue(liveControlsTimers(r).isEmpty)
        r.store.cancelSwitch()
        XCTAssertNil(r.store.switchPrompt)
        r.store.syncControlsAutoHide()
        XCTAssertEqual(liveControlsTimers(r).count, 1)
    }

    // MARK: 专注页尺寸

    // 产品保证：工具按钮淡出后导航栏收起、顶部安全区变小，圆盘也不跟着跳（10-12 最小窗口里先叠后正的问题）。
    func testFocusLayoutIgnoresToolbarCollapse() {
        // 这个窗口若按收起后的 24 重算，圆环会从 290 变成 390；两种顶部安全区必须得到同一套尺寸。
        let withBar = FocusPageLayout(width: 600, height: 700, topInset: 74, bottomInset: 90, compact: true)
        let collapsed = FocusPageLayout(width: 600, height: 700, topInset: 24, bottomInset: 90, compact: true)
        XCTAssertEqual(withBar, collapsed)
        XCTAssertEqual(withBar.ring, 290)
    }
    // 产品保证：错误提示参与可滚动布局且不改变档位；矮窗缩环让位，大窗保持圆环位置，横排容纳右列错误块。
    func testFocusLayoutKeepsErrorInsideRegion() {
        func verticalHeight(_ layout: FocusPageLayout) -> Double {
            let group = FocusPageLayout.taskHeight + layout.gapAbove + layout.ring
                + layout.gapBelow + layout.controlsHeight
            return layout.topPadding + group + layout.errorHeight + layout.bottomPadding
        }
        let narrow = FocusPageLayout(width: 375, height: 488, topInset: 74, bottomInset: 90, compact: true)
        XCTAssertEqual(narrow.axis, .vertical)
        XCTAssertEqual(narrow.ring, 176, "前提：收紧竖排仍有缩环空间")
        XCTAssertEqual(narrow.errorHeight, 0)
        let narrowError = FocusPageLayout(width: 375, height: 488, topInset: 74, bottomInset: 90,
                                         compact: true, showsError: true)
        XCTAssertEqual(narrowError.axis, narrow.axis)
        XCTAssertEqual(narrowError.errorHeight, 52)
        XCTAssertLessThan(narrowError.ring, narrow.ring)
        XCTAssertLessThanOrEqual(verticalHeight(narrowError), narrowError.regionHeight)

        let wide = FocusPageLayout(width: 930, height: 834, topInset: 74, bottomInset: 20, compact: false)
        XCTAssertEqual(wide.axis, .vertical)
        XCTAssertEqual(wide.topPadding, wide.bottomPadding, "前提：无错误时采用对称竖排")
        let wideError = FocusPageLayout(width: 930, height: 834, topInset: 74, bottomInset: 20,
                                       compact: false, showsError: true)
        XCTAssertEqual(wideError.axis, wide.axis)
        XCTAssertEqual(wideError.ring, wide.ring)
        XCTAssertEqual(wideError.topPadding, wide.topPadding)
        XCTAssertEqual(verticalHeight(wideError), verticalHeight(wide))

        let short = FocusPageLayout(width: 600, height: 410, topInset: 74, bottomInset: 80, compact: true)
        XCTAssertEqual(short.axis, .horizontal, "前提：无错误时采用横排")
        let shortError = FocusPageLayout(width: 600, height: 410, topInset: 74, bottomInset: 80,
                                        compact: true, showsError: true)
        XCTAssertEqual(shortError.axis, short.axis)
        XCTAssertEqual(shortError.ring, short.ring)
        let columnHeight = FocusPageLayout.taskHeight + shortError.gapBelow
            + shortError.controlsHeight + shortError.errorHeight
        XCTAssertLessThanOrEqual(columnHeight, shortError.regionHeight - shortError.topPadding - shortError.bottomPadding)
    }

    // 产品保证：大窗照定稿竖排对称居中；放不下时先收紧竖排，可见区更矮就横排；再小也不把圆环缩到 120 以下。
    func testFocusLayoutTiersBySize() {
        let wide = FocusPageLayout(width: 930, height: 834, topInset: 74, bottomInset: 20, compact: false)
        XCTAssertEqual(wide.axis, .vertical); XCTAssertEqual(wide.ring, 420)
        XCTAssertEqual(wide.topPadding, wide.bottomPadding)
        let narrow = FocusPageLayout(width: 375, height: 834, topInset: 74, bottomInset: 90, compact: true)
        XCTAssertEqual(narrow.axis, .vertical); XCTAssertEqual(narrow.ring, 262.5)
        // 四分之一屏左右的矮窗：竖排只剩 108，横排能给 240。
        let quarter = FocusPageLayout(width: 600, height: 410, topInset: 74, bottomInset: 80, compact: true)
        XCTAssertEqual(quarter.axis, .horizontal); XCTAssertEqual(quarter.ring, 240)
        XCTAssertEqual(quarter.bottomPadding, 8)
        // 偏窄偏矮：横排右列放不下，收紧的竖排更大。
        let tall = FocusPageLayout(width: 500, height: 580, topInset: 74, bottomInset: 80, compact: true)
        XCTAssertEqual(tall.axis, .vertical); XCTAssertEqual(tall.ring, 278)
        XCTAssertEqual([tall.gapAbove, tall.gapBelow], [16, 16])
        let tiny = FocusPageLayout(width: 320, height: 300, topInset: 74, bottomInset: 80, compact: true)
        XCTAssertEqual(tiny.axis, .vertical); XCTAssertEqual(tiny.ring, 120)
    }

}

// 测试里直接构造完成结果的便捷初始化。
extension FocusTaskCompletion {
    init(focusResult: String, kind: String, discarded: Bool, error: String) {
        self.init()
        self.focusResult = focusResult; self.kind = kind; self.discarded = discarded; self.error = error
    }
}
