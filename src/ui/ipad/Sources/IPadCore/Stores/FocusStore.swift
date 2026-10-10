import Foundation
import Observation

// 专注页的展示状态，由计时器快照、所选模式与「刚完成的阶段」合成（对照 Mac FocusView.computeState）。
public enum FocusPageState: Equatable, Sendable {
    case free, manualRest, pomoIdle, pomoWork, workDone, pomoBreak, breakDone
}

// 切换任务或模式前的确认框内容。
public struct FocusSwitchPrompt: Equatable, Sendable {
    public var taskID: Int
    public var title: String
    public var pomodoro: Bool
    public var autoStart: Bool
    // 打开确认框时记下的计时器来源，确认时由控制器比对（stopForSwitch 的 stateChanged 判断）。
    public var source: FocusSwitchSource?
    public var message: String
    // 「结束并开始」只用于快速开始的任务切换，其余是「结束并切换」。
    public var confirmTitle: String { autoStart ? "结束并开始" : "结束并切换" }
}

// 超长自由专注的确认框内容；adjustmentError 是修正时长的前端校验提示。
public struct LongFreePrompt: Equatable, Sendable {
    // 确认之后要继续做的动作（end / startPomodoro / startFree / toPomodoro / toFree / enterPomodoro / enterFree）。
    public var action: String
    public var taskID: Int
    public var title: String
    public var elapsedSeconds: Int
    public var thresholdHours: Int
    public var minimumMinutes: Int
    public var adjustmentError = ""
}

public typealias FocusDelay = @MainActor (_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void

// 专注计时的展示与交互状态。长休息、自动衔接、切换分流、结束分发、超长确认、候选任务等业务判断
// 全在 C++（FocusSessionController），这里只按返回结果做界面动作；根级常驻，
// 自动衔接跟随计时器而不是页面（用户停在别的页时同样生效）。
@MainActor @Observable public final class FocusStore: FocusFlowHook {
    public private(set) var snapshot = FocusSnapshot()
    public private(set) var pomodoroModeSelected = false
    public private(set) var selectedTaskID = -1
    public private(set) var selectedTaskTitle = ""
    public private(set) var selectedWorkMinutes = 25
    public private(set) var selectedBreakMinutes = 5
    public private(set) var justCompletedPhase = 0
    public var errorText = ""
    public private(set) var todayTasks: [TaskValue] = []
    public private(set) var taskNotes = ""
    public var panelExpanded = false
    public private(set) var switchPrompt: FocusSwitchPrompt?
    public private(set) var longFree: LongFreePrompt?
    // 快捷键找不到候选任务时展开选择器；视图消费后置回。
    public var taskSelectorPresented = false
    public private(set) var shortcutOpenedSelector = false
    public private(set) var immersiveActive = false
    // 专注页是否在前台：只影响任务清单的重读，不影响自动衔接。
    public var pageActive = false
    // 「细体时钟」设置：只换计时数字的字重，随设置信号更新。
    public private(set) var slimClockFont = false
    // 动画是否该收敛：系统「减少动态效果」或应用内同名设置任一打开；视图每次渲染时现取。
    public var animationsReduced: Bool { reduceMotion() }
    @ObservationIgnored public var onFocusCompletedForPages: (() -> Void)?

    @ObservationIgnored private let focus: any FocusBridgeProtocol
    @ObservationIgnored private let settings: any SettingsBridgeProtocol
    @ObservationIgnored private let taskBridge: any TaskBridgeProtocol
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored private let delay: FocusDelay
    @ObservationIgnored private var cancelAutoAdvanceAction: (@MainActor () -> Void)?
    @ObservationIgnored private var autoAdvancePhase = 0
    // 为完成任务而结束专注期间为真：计时器同步发出的「不足 3 分钟未计入」改由完成提示一并说明。
    @ObservationIgnored private var endingForCompletion = false
    // 在其它页原地结束计时（仪表盘、完成任务）时不跳回今日页。
    @ObservationIgnored private var endingInPlace = false
    // 选中项恰好是待删任务时先收起暂存，撤销后还回去。
    @ObservationIgnored private var heldSelection: (id: Int, title: String)?
    @ObservationIgnored private var started = false

    public static let realDelay: FocusDelay = { seconds, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { action() }
        }
        return { task.cancel() }
    }

    public init(focus: any FocusBridgeProtocol, settings: any SettingsBridgeProtocol,
                tasks: any TaskBridgeProtocol, pendingDeletion: PendingDeletionStore, shell: ShellStore,
                reduceMotion: @escaping @MainActor () -> Bool = { false },
                delay: @escaping FocusDelay = FocusStore.realDelay) {
        self.focus = focus; self.settings = settings; self.taskBridge = tasks
        self.pendingDeletion = pendingDeletion; self.shell = shell
        self.reduceMotion = reduceMotion; self.delay = delay
    }

    // MARK: 派生展示
    public var freeModeAvailable: Bool { snapshot.freeTimingAllowed }
    public var state: FocusPageState {
        if snapshot.mode == 2 && snapshot.phase == 3 { return .manualRest }
        if !pomodoroModeSelected { return .free }
        if justCompletedPhase == 1 { return .workDone }
        if justCompletedPhase == 2 { return .breakDone }
        if snapshot.mode == 1 && snapshot.phase == 1 { return .pomoWork }
        if snapshot.mode == 1 && snapshot.phase == 2 { return .pomoBreak }
        return .pomoIdle
    }
    // 计时中、休息中、刚完成一段：任务由计时器说了算，选择器只在真正空闲时出现。
    public var taskSelectorActive: Bool {
        (state == .free && !snapshot.hasActiveSession) || state == .pomoIdle
    }
    public var immersiveAvailable: Bool {
        switch state {
        case .manualRest, .pomoWork, .pomoBreak: true
        case .free: snapshot.hasActiveSession
        default: false
        }
    }
    // 沉浸里除计时中还要能显示完成态；待机和无会话的自由态没有可投影内容。
    public var immersiveProjectable: Bool { immersiveAvailable || state == .workDone || state == .breakDone }
    public var knowledgeGapEntryAvailable: Bool { state != .manualRest }
    // 迷你计时条文字：工作与自由显示任务名，休息段显示「休息」。
    public var miniTimerLabel: String {
        if snapshot.phase == 2 || snapshot.phase == 3 { return "休息" }
        return snapshot.currentTaskTitle.isEmpty ? "专注" : snapshot.currentTaskTitle
    }
    public var canStartPomodoro: Bool {
        (selectedTaskID > 0 && !selectedTaskTitle.isEmpty) || (snapshot.currentTaskID > 0 && !snapshot.currentTaskTitle.isEmpty)
    }
    public var canStartFreeFocus: Bool {
        !snapshot.hasActiveSession && snapshot.phase == 0 && selectedTaskID > 0 && !selectedTaskTitle.isEmpty
    }
    public var taskTitleText: String {
        if state == .manualRest { return "主动休息" }
        if snapshot.hasActiveSession && !snapshot.currentTaskTitle.isEmpty { return snapshot.currentTaskTitle }
        if !selectedTaskTitle.isEmpty { return selectedTaskTitle }
        return pomodoroModeSelected ? "尚未选择任务" : "尚未开始专注"
    }
    public var stageText: String {
        let running = snapshot.running
        switch state {
        case .manualRest: return running ? "主动休息中" : "⏸ 主动休息已暂停"
        case .pomoWork: return running ? "专注中" : "⏸ 专注已暂停"
        case .pomoBreak: return running ? "休息中" : "⏸ 休息已暂停"
        case .workDone: return "专注完成"
        case .breakDone: return "休息结束"
        default: return ""
        }
    }
    public var runningText: String {
        guard state == .free else { return "" }
        if !snapshot.hasActiveSession { return selectedTaskID > 0 ? "准备开始" : "尚未选择任务" }
        return snapshot.running ? "专注进行中" : "专注已暂停"
    }
    public var primaryTimeText: String {
        switch state {
        case .manualRest, .free: return Self.clock(snapshot.elapsedSeconds, hours: true)
        case .pomoIdle: return "\(selectedWorkMinutes):00"
        case .workDone, .breakDone: return "00:00"
        default: return Self.clock(snapshot.remainingSeconds, hours: false)
        }
    }
    public var ringDimmed: Bool {
        (state == .manualRest || state == .pomoWork || state == .pomoBreak) && !snapshot.running
    }
    // 工作与休息阶段环按剩余比例消退；待机与完成态是满环（完成态合拢是刻意的收尾）。
    public var ringProgress: Double {
        guard state == .pomoWork || state == .pomoBreak else { return 1 }
        guard snapshot.targetSeconds > 0 else { return 0 }
        return max(0, min(1, Double(snapshot.remainingSeconds) / Double(snapshot.targetSeconds)))
    }
    public var ringCaption: String {
        let target = Int((Double(snapshot.targetSeconds) / 60).rounded())
        switch state {
        case .pomoWork: return (ringDimmed ? "已暂停 · 共 " : "剩余 · 共 ") + "\(target) 分"
        case .pomoBreak: return (ringDimmed ? "已暂停 · 共 " : "休息 · 共 ") + "\(target) 分"
        default: return ""
        }
    }
    public var primaryButtonText: String {
        switch state {
        case .workDone: "开始休息"
        case .breakDone: "开始专注"
        default: snapshot.running ? "暂停" : "继续"
        }
    }
    public var primaryButtonEnabled: Bool {
        switch state {
        case .workDone: true
        case .breakDone: canStartPomodoro
        case .free: snapshot.hasActiveSession
        default: snapshot.phase != 0
        }
    }
    public var secondaryButtonText: String {
        switch state {
        case .manualRest: "结束休息"
        case .pomoBreak: "跳过休息"
        case .free: "结束专注"
        default: "结束"
        }
    }
    // 记一笔的来源：计时中以计时器绑定的任务为准，待机退回选中项；主动休息与沉浸里不提供入口。
    public var captureSource: ShellCaptureSource? {
        guard knowledgeGapEntryAvailable, !immersiveActive else { return nil }
        let id = snapshot.hasActiveSession ? snapshot.currentTaskID : selectedTaskID
        guard id > 0 else { return nil }
        let category = (try? taskBridge.task(id: id))?.categoryID ?? -1
        return ShellCaptureSource(taskID: id, categoryID: category > 0 ? category : -1)
    }
    public func selectableTasks() -> [TaskValue] {
        let hidden = pendingDeletion.pendingTaskID
        return hidden > 0 ? todayTasks.filter { $0.id != hidden } : todayTasks
    }

    private static func clock(_ seconds: Int, hours: Bool) -> String {
        let safe = max(0, seconds)
        let h = safe / 3600, m = (safe % 3600) / 60, s = safe % 60
        if hours { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", safe / 60, s)
    }

    // MARK: 生命周期与信号
    // 桥接回调槽只有一个，所以宿主必须给本 Store 一份专用适配器（共享实例只用于调用）。
    public func start() {
        guard !started else { return }
        started = true
        let saved = settings.snapshot()
        if (5...180).contains(saved.workMinutes) { selectedWorkMinutes = saved.workMinutes }
        if (1...60).contains(saved.breakMinutes) { selectedBreakMinutes = saved.breakMinutes }
        slimClockFont = saved.slimClockFont
        refreshSnapshot()
        // 平台不开放自由计时就从番茄开始；之后由用户操作和服务现态替换。
        pomodoroModeSelected = !freeModeAvailable
        // C++ 在界面加载前恢复会话时不会重放旧信号，首次必须主动读取服务现态。
        syncToActiveTimer()
        reloadTodayTasks()
        connectSignals()
    }
    private func connectSignals() {
        focus.onTick = { [weak self] in self?.refreshSnapshot() }
        focus.onRunningStateChanged = { [weak self] in self?.refreshSnapshot() }
        focus.onCompletedPomodorosChanged = { [weak self] in self?.refreshSnapshot() }
        focus.onSessionLogicalDateChanged = { [weak self] in self?.refreshSnapshot() }
        focus.onManualRestAllowedChanged = { [weak self] in self?.refreshSnapshot() }
        focus.onFreeTimingAllowedChanged = { [weak self] in
            guard let self else { return }
            refreshSnapshot()
            if !freeModeAvailable && !pomodoroModeSelected { pomodoroModeSelected = true }
        }
        focus.onCurrentTaskChanged = { [weak self] in self?.refreshSnapshot(); self?.syncToActiveTimer() }
        focus.onModeChanged = { [weak self] in self?.refreshSnapshot(); self?.syncToActiveTimer() }
        focus.onPhaseChanged = { [weak self] in self?.refreshSnapshot(); self?.syncToActiveTimer() }
        focus.onFocusCompleted = { [weak self] _ in self?.onFocusCompletedForPages?() }
        focus.onPhaseCompleted = { [weak self] phase in self?.phaseCompleted(phase) }
        focus.onSessionDiscarded = { [weak self] _ in
            guard let self, !endingForCompletion else { return }
            shell?.showToast("本次专注不足 3 分钟，未计入记录")
        }
        focus.onTaskAutoCompleteFailed = { [weak self] _ in
            self?.shell?.showToast("专注记录已保存，但任务自动完成失败，请手动检查")
        }
        focus.onFailure = { [weak self] message in self?.shell?.showToast(message.isEmpty ? "专注操作失败" : message) }
        focus.onPhaseSettledOffline = { [weak self] phase in
            self?.shell?.showToast(phase == 1 ? "离开期间番茄已到点，已记为完成" : "离开期间休息已结束")
        }
        focus.onAlarmUnavailable = { [weak self] reason in
            self?.shell?.showToast("到点提醒没有预约成功（\(reason)），离开应用后不会提醒")
        }
        focus.onNotificationDeliveryFailed = { [weak self] reason in
            self?.shell?.showToast("系统通知没有发出（\(reason)）")
        }
        settings.onSlimClockFontChanged = { [weak self] in
            guard let self else { return }
            slimClockFont = settings.snapshot().slimClockFont
        }
        settings.onWorkMinutesChanged = { [weak self] in
            guard let self else { return }
            let value = settings.snapshot().workMinutes
            if (5...180).contains(value) { selectedWorkMinutes = value }
        }
        settings.onBreakMinutesChanged = { [weak self] in
            guard let self else { return }
            let value = settings.snapshot().breakMinutes
            if (1...60).contains(value) { selectedBreakMinutes = value }
        }
        // 等待自动衔接期间用户关掉了开关：立即取消，不等到点再验。
        settings.onAutoStartBreakChanged = { [weak self] in
            guard let self, autoAdvancePhase == 1, !wantsAutoAdvance(1) else { return }
            cancelAutoAdvance()
        }
        settings.onAutoStartNextPomodoroChanged = { [weak self] in
            guard let self, autoAdvancePhase == 2, !wantsAutoAdvance(2) else { return }
            cancelAutoAdvance()
        }
        taskBridge.onChanged = { [weak self] in
            guard let self else { return }
            reconcileSelectedTask(); refreshTaskNotes()
            if pageActive { reloadTodayTasks() }
        }
    }
    public func refreshSnapshot() {
        let value = focus.snapshot
        if value != snapshot { snapshot = value }
        // 沉浸中意外落入待机或无会话的自由态，立即退出，不留空白全屏。
        if immersiveActive && !immersiveProjectable { immersiveActive = false }
        if state != .pomoIdle { panelExpanded = false }
    }
    // 服务才是计时开始后的唯一事实源；本地模式和待机缓存只服务于尚未开始的状态。
    public func syncToActiveTimer() {
        let s = snapshot
        guard s.hasActiveSession || s.phase != 0 else { return }
        if s.mode == 2 && s.phase == 3 { justCompletedPhase = 0; return }
        let usesPomodoro = s.mode == 1 || s.phase != 0
        pomodoroModeSelected = usesPomodoro
        if !usesPomodoro {
            selectedTaskID = s.currentTaskID; selectedTaskTitle = s.currentTaskTitle
            refreshTaskNotes(); return
        }
        // 休息阶段没有任务编号，保留刚完成工作阶段的缓存供下一轮继续使用。
        if s.currentTaskID > 0 { selectedTaskID = s.currentTaskID }
        if !s.currentTaskTitle.isEmpty { selectedTaskTitle = s.currentTaskTitle }
        refreshTaskNotes()
    }
    private func phaseCompleted(_ phase: Int) {
        refreshSnapshot()
        cancelAutoAdvance()
        justCompletedPhase = phase
        guard wantsAutoAdvance(phase) else { return }
        // 延一小段再切，让用户看清完成态后再进入下一阶段；减少动态效果时立即切。
        autoAdvancePhase = phase
        cancelAutoAdvanceAction = delay(reduceMotion() ? 0 : 0.9) { [weak self] in self?.autoAdvanceFired(phase) }
    }
    private func autoAdvanceFired(_ phase: Int) {
        autoAdvancePhase = 0; cancelAutoAdvanceAction = nil
        // 延迟期间用户可能已经结束循环或关闭自动衔接；到点必须再问一次。
        guard justCompletedPhase == phase, wantsAutoAdvance(phase) else { return }
        if phase == 1 {
            startBreak()
            if errorText.isEmpty { autoAdvanced(1) }
        } else if phase == 2 {
            startPomodoro()
            if errorText.isEmpty { autoAdvanced(2) }
        }
    }
    private func autoAdvanced(_ phase: Int) {
        // 用户正盯着专注页时切换本身可见，不必再提示。
        guard shell?.selection != .focus else { return }
        shell?.showToast(phase == 1 ? "专注完成，已自动开始休息" : "休息结束，已自动开始下一个番茄")
    }
    public func cancelAutoAdvance() {
        cancelAutoAdvanceAction?(); cancelAutoAdvanceAction = nil; autoAdvancePhase = 0
    }
    private func wantsAutoAdvance(_ phase: Int) -> Bool { (try? focus.autoAdvanceAfter(phase: phase)) ?? false }

    // MARK: 任务选择
    public func setPageActive(_ active: Bool) {
        pageActive = active
        if active { reloadTodayTasks() }
    }
    public func reloadTodayTasks() {
        reconcileSelectedTask()
        todayTasks = (try? taskBridge.todayTasks()) ?? todayTasks
    }
    // 活动会话由计时器持有；这里只校验待启动的选择，删除或改名后不能留下失效编号。
    private func reconcileSelectedTask() {
        guard !snapshot.hasActiveSession, selectedTaskID > 0 else { return }
        do {
            let task = try taskBridge.task(id: selectedTaskID)
            if task.id != selectedTaskID { clearSelectedTask() } else { selectedTaskTitle = task.title }
        } catch {
            // 只有确认任务不存在才清掉；读取失败时保留用户的选择。
            if error.localizedDescription == "任务已不存在" { clearSelectedTask() }
        }
    }
    private func taskExists(_ id: Int) -> Bool {
        do { return try taskBridge.task(id: id).id == id }
        catch { return error.localizedDescription != "任务已不存在" }
    }
    private func refreshTaskNotes() {
        let id = snapshot.hasActiveSession ? snapshot.currentTaskID : selectedTaskID
        taskNotes = id > 0 ? ((try? taskBridge.task(id: id))?.notes ?? "") : ""
    }
    public func selectTask(id: Int, title: String) {
        selectedTaskID = id; selectedTaskTitle = title; errorText = ""
        refreshTaskNotes()
    }
    public func clearSelectedTask() {
        selectedTaskID = -1; selectedTaskTitle = ""
        // 显式清空意味着撤销后也不该再把它还回来。
        heldSelection = nil
        refreshTaskNotes()
    }
    // 待删任务：选中项先收起，撤销或删除失败后还回去；任务真删掉了就丢弃。
    public func pendingDeletionChanged() {
        let pendingID = pendingDeletion.pendingTaskID
        if let held = heldSelection, held.id != pendingID {
            heldSelection = nil
            if selectedTaskID <= 0 && !snapshot.hasActiveSession && taskExists(held.id) {
                selectedTaskID = held.id; selectedTaskTitle = held.title; refreshTaskNotes()
            }
        }
        if pendingID > 0 && selectedTaskID == pendingID && !snapshot.hasActiveSession {
            let hidden = (id: selectedTaskID, title: selectedTaskTitle)
            clearSelectedTask(); heldSelection = hidden
        }
        if pageActive { reloadTodayTasks() }
    }
    // 可自动启动的那条由控制器挑；选中项失效则清掉选中。取不到返回 nil，由调用方落到选择器。
    public func autoStartCandidate() -> (id: Int, title: String)? {
        let candidate = try? focus.autoStartCandidate(taskID: selectedTaskID, title: selectedTaskTitle)
        if candidate?.selectionStale == true { clearSelectedTask() }
        reloadTodayTasks()
        guard let candidate, candidate.taskID > 0 else { return nil }
        return (candidate.taskID, candidate.title)
    }
    public func openTaskSelector() { reloadTodayTasks(); taskSelectorPresented = true }
    // 选择器里新建今日任务并开始：用服务返回的编号，不按标题反查（同名任务会绑错）。
    @discardableResult public func createTaskAndStart(title: String) -> Bool {
        let newID: Int
        do { newID = try focus.createTodayTask(title: title) }
        catch { errorText = "新建任务失败，请重试"; return false }
        guard newID > 0 else { errorText = "新建任务失败，请重试"; return false }
        // 先重读清单再记选中：重读会校验选中项，新任务要等清单里有了再选。
        reloadTodayTasks()
        selectedTaskID = newID
        selectedTaskTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshTaskNotes()
        return startCurrentMode()
    }
    @discardableResult public func startFromShortcut() -> Bool {
        shortcutOpenedSelector = false
        guard let candidate = autoStartCandidate() else {
            openTaskSelector(); shortcutOpenedSelector = true; return false
        }
        selectedTaskID = candidate.id; selectedTaskTitle = candidate.title
        refreshTaskNotes()
        return startCurrentMode()
    }
    // 仪表盘开始按钮沿用自动候选口径，但成功后留在仪表盘；没有候选时才把用户送到专注页选择。
    @discardableResult public func startFromDashboard() -> Bool {
        refreshSnapshot()
        if snapshot.hasActiveSession || snapshot.phase != 0 { togglePause(); return true }
        guard let candidate = autoStartCandidate() else {
            shell?.select(.focus); openTaskSelector(); return false
        }
        selectedTaskID = candidate.id; selectedTaskTitle = candidate.title; refreshTaskNotes()
        return startCurrentMode()
    }
    // ⌘↩：计时中暂停或继续，空闲时切到专注页按当前模式开始；取不到任务就展开选择器并提示。
    public func startOrPauseFromShortcut() {
        refreshSnapshot()
        if snapshot.hasActiveSession || snapshot.phase != 0 {
            togglePause()
            let rest = snapshot.mode == 2 && snapshot.phase == 3
            shell?.showToast(snapshot.running ? (rest ? "已继续休息" : "已继续专注") : (rest ? "已暂停休息" : "已暂停专注"))
            return
        }
        shell?.select(.focus)
        if !startFromShortcut() && shortcutOpenedSelector {
            shell?.showToast("今天还没有可以开始的任务，挑一条或新建一个")
        }
    }

    // MARK: 时长
    public func selectWorkMinutes(_ minutes: Int) {
        // 范围而非白名单：自定义时长和预设走同一入口。
        guard (5...180).contains(minutes) else { return }
        selectedWorkMinutes = minutes
        try? settings.setWorkMinutes(minutes)
    }
    public func selectBreakMinutes(_ minutes: Int) {
        guard (1...60).contains(minutes) else { return }
        selectedBreakMinutes = minutes
        try? settings.setBreakMinutes(minutes)
    }
    // 长休息的判定在控制器，手动和自动开始休息共用。
    private func nextBreakMinutes() -> Int { (try? focus.nextBreakMinutes(selected: selectedBreakMinutes)) ?? selectedBreakMinutes }

    // MARK: 开始、暂停、休息
    @discardableResult public func startCurrentMode() -> Bool { pomodoroModeSelected ? startPomodoro() : startFreeFocus() }
    @discardableResult public func startFreeFocus() -> Bool {
        cancelAutoAdvance()
        guard freeModeAvailable else { errorText = "这台设备暂时只支持番茄专注"; return false }
        guard canStartFreeFocus else { errorText = "请先选择要专注的任务"; return false }
        do { try focus.startFree(taskID: selectedTaskID, title: selectedTaskTitle) }
        catch { errorText = "自由专注启动失败，请重试"; return false }
        errorText = ""; justCompletedPhase = 0
        try? settings.setLastMode(0)
        refreshSnapshot()
        return true
    }
    @discardableResult public func startPomodoro() -> Bool {
        cancelAutoAdvance()
        justCompletedPhase = 0
        let taskID = selectedTaskID > 0 ? selectedTaskID : snapshot.currentTaskID
        let title = !selectedTaskTitle.isEmpty ? selectedTaskTitle : (!snapshot.currentTaskTitle.isEmpty ? snapshot.currentTaskTitle : "番茄专注")
        guard taskID > 0, (try? focus.startPomodoro(taskID: taskID, title: title, seconds: selectedWorkMinutes * 60)) != nil else {
            errorText = "番茄专注启动失败"; return false
        }
        errorText = ""
        // 只在真正启动番茄后记忆模式；单纯切到番茄页不改变用户偏好。
        try? settings.setLastMode(1)
        refreshSnapshot()
        return true
    }
    @discardableResult public func startBreak() -> Bool {
        cancelAutoAdvance()
        let taskID = selectedTaskID > 0 ? selectedTaskID : snapshot.currentTaskID
        let title = !selectedTaskTitle.isEmpty ? selectedTaskTitle : snapshot.currentTaskTitle
        do { try focus.startBreak(seconds: nextBreakMinutes() * 60, taskID: taskID, title: title) }
        catch { errorText = "休息启动失败"; return false }   // 失败时保留完成态，用户必须仍能重试
        justCompletedPhase = 0; errorText = ""
        refreshSnapshot()
        return true
    }
    public func togglePause() {
        refreshSnapshot()
        if snapshot.running {
            do { try focus.pause() } catch { errorText = error.localizedDescription }
        } else {
            do { try focus.resume(); errorText = "" } catch { errorText = "专注恢复失败" }
        }
        refreshSnapshot()
    }

    // MARK: 结束
    public func endPomodoro() {
        cancelAutoAdvance()
        // 番茄页的结束用专门入口：空档里计时器已回到自由模式，只有它能放弃整个番茄循环（连续计数归零）。
        applyEndResult((try? focus.endPomodoroCycle()) ?? Self.endFailure)
    }
    public func endFreeFocus() {
        cancelAutoAdvance()
        applyEndResult((try? focus.endCurrent()) ?? Self.endFailure)
    }
    public func endManualRest() {
        // 只在确实处于主动休息时才结束；别的状态收到这个入口一律报失败，不误停别的会话。
        guard snapshot.mode == 2 && snapshot.phase == 3 else { errorText = "结束休息失败，请重试"; return }
        applyEndResult((try? focus.endCurrent()) ?? Self.endFailure)
    }
    // 沉浸与主按钮共用的两个动作入口。
    public func triggerPrimary() {
        switch state {
        case .workDone: startBreak()
        case .breakDone: startPomodoro()
        default: togglePause()
        }
    }
    public func triggerSecondary() {
        switch state {
        case .free: endFreeFocus()
        case .manualRest: endManualRest()
        default: endPomodoro()
        }
    }
    private static let endFailure = FocusEndResult(result: "failed", error: "专注结束失败，请重试")
    // 把控制器的结束结果落成界面动作。
    func applyEndResult(_ outcome: FocusEndResult) {
        refreshSnapshot()
        if outcome.result == "needsConfirmation" { requestLongFreeConfirmation(action: "end", taskID: -1, title: ""); return }
        if outcome.result == "failed" { errorText = outcome.error; return }
        if outcome.kind == "manualRest" { errorText = ""; leaveFocusPage(); return }
        if outcome.kind == "pomodoro" {
            errorText = ""; justCompletedPhase = 0
            clearSelectedTask(); leaveFocusPage(); return
        }
        // free 与 none 同一收尾（none 是自动衔接的空档里点结束：没有东西要停，页面照样回到起点）。
        applyPostFreeStopAction("end", taskID: -1, title: "")
    }
    // 先退出沉浸再切页；在其它页原地结束时留在原页。
    private func leaveFocusPage() {
        immersiveActive = false
        if !endingInPlace { shell?.select(.today) }
    }
    // 其它页（仪表盘、完成任务）原地结束：返回值含义对照 Mac applyInPlaceEnd。
    public enum InPlaceEnd: Equatable { case none, confirming, ended, failed }
    public func applyInPlaceEnd(_ outcome: FocusEndResult) -> InPlaceEnd {
        if outcome.result == "none" { return .none }
        if outcome.result == "needsConfirmation" {
            // 确认框属于专注页，切过去才看得见。
            immersiveActive = false
            requestLongFreeConfirmation(action: "end", taskID: -1, title: "")
            shell?.select(.focus)
            return .confirming
        }
        if outcome.result == "failed" { errorText = outcome.error; return .failed }
        endingInPlace = true; cancelAutoAdvance(); applyEndResult(outcome); endingInPlace = false
        return .ended
    }

    // 仪表盘和任务页的结束入口只负责把控制器结果交回同一套收尾逻辑；需要确认时切到专注页显示确认框。
    @discardableResult public func endFromDashboard() -> InPlaceEnd {
        refreshSnapshot()
        let outcome: FocusEndResult
        if state == .free || state == .manualRest {
            outcome = (try? focus.endCurrent()) ?? Self.endFailure
        } else {
            outcome = (try? focus.endPomodoroCycle()) ?? Self.endFailure
        }
        return applyInPlaceEnd(outcome)
    }

    // MARK: 超长自由专注
    private func requestLongFreeConfirmation(action: String, taskID: Int, title: String) {
        refreshSnapshot()
        immersiveActive = false
        longFree = LongFreePrompt(action: action, taskID: taskID, title: title, elapsedSeconds: snapshot.elapsedSeconds,
                                  thresholdHours: (try? focus.freeTimerWarningHours()) ?? 8,
                                  minimumMinutes: snapshot.minimumValidMinutes)
    }
    public func recordLongFree() { finishLongFree(record: true, correctedSeconds: -1) }
    public func discardLongFree() { finishLongFree(record: false, correctedSeconds: -1) }
    // Esc 或关闭都等价于继续计时：没有明确选择时绝不保存或丢弃。
    public func continueLongFree() { longFree = nil }
    // 修正时长：整分钟、不少于有效下限、不超过实际计时；前端与服务层都校验。
    @discardableResult public func recordLongFree(correctedMinutes minutes: Int?) -> Bool {
        guard var prompt = longFree else { return false }
        func reject(_ text: String) -> Bool { prompt.adjustmentError = text; longFree = prompt; return false }
        guard let minutes else { return reject("请输入整分钟数") }
        if minutes < prompt.minimumMinutes { return reject("记录时长不能少于 \(prompt.minimumMinutes) 分钟") }
        if minutes * 60 > prompt.elapsedSeconds {
            return reject("记录时长不能超过实际计时的 " + Self.elapsedLabel(prompt.elapsedSeconds))
        }
        finishLongFree(record: true, correctedSeconds: minutes * 60)
        return true
    }
    public static func elapsedLabel(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        let hours = safe / 3600, minutes = (safe % 3600) / 60
        return "\(hours) 小时" + (minutes > 0 ? " \(minutes) 分钟" : "")
    }
    private func finishLongFree(record: Bool, correctedSeconds: Int) {
        guard let prompt = longFree else { return }
        longFree = nil
        let outcome: FocusFinishResult
        do { outcome = try focus.finishLongFree(record: record, correctedSeconds: correctedSeconds) }
        catch { errorText = record ? "专注保存失败，请重试" : "专注丢弃失败，请重试"; return }
        guard outcome.ok else { errorText = outcome.error; return }
        applyPostFreeStopAction(prompt.action, taskID: prompt.taskID, title: prompt.title)
    }
    private func applyPostFreeStopAction(_ action: String, taskID: Int, title: String) {
        errorText = ""; justCompletedPhase = 0
        switch action {
        case "end": clearSelectedTask(); leaveFocusPage()
        case "startPomodoro", "startFree": applyTask(taskID, title, pomodoro: action == "startPomodoro", autoStart: true)
        case "toPomodoro", "toFree": pomodoroModeSelected = action == "toPomodoro"
        // 多走了一道超时确认，意图仍是「切过去待机」，不能因此变成自动开始。
        case "enterPomodoro", "enterFree": applyTask(taskID, title, pomodoro: action == "enterPomodoro", autoStart: false)
        default: break
        }
        refreshSnapshot()
    }

    // MARK: 切换模式与任务
    private enum StopOutcome { case stopped, confirming, failed }
    // 为切模式或切任务停掉忙碌中的计时器：停表与超长确认判断都经控制器。
    private func stopBusyTimerForSwitch(action: String, taskID: Int, title: String) -> StopOutcome {
        let outcome: String
        do { outcome = try focus.stopForSwitch(try focus.captureSwitchSource()) } catch { return .failed }
        if outcome == "needsLongFreeConfirmation" {
            requestLongFreeConfirmation(action: action, taskID: taskID, title: title); return .confirming
        }
        return outcome == "stopped" ? .stopped : .failed
    }
    // 页签切换。到达这里时计时器要么空闲，要么忙碌但没有可继承的任务（有的话已先走确认框）。
    // 两个方向的停表都经控制器：超长自由专注按计时器的真实模式判断，不凭页签推断。
    func toPomodoroTab(_ wanted: Bool) {
        let enabled = wanted || !freeModeAvailable
        cancelAutoAdvance(); refreshSnapshot()
        if snapshot.mode == 2 && snapshot.phase == 3 { return }
        let busy = snapshot.hasActiveSession || snapshot.phase != 0
        if enabled {
            let useTimerTask = busy || selectedTaskID <= 0
            if useTimerTask && snapshot.currentTaskID > 0 { selectedTaskID = snapshot.currentTaskID }
            if useTimerTask && !snapshot.currentTaskTitle.isEmpty { selectedTaskTitle = snapshot.currentTaskTitle }
        }
        if busy {
            switch stopBusyTimerForSwitch(action: enabled ? "toPomodoro" : "toFree", taskID: -1, title: "") {
            case .confirming: return
            case .failed: errorText = enabled ? "切换番茄失败，请重试" : "结束当前阶段失败，请重试"; return
            case .stopped: break
            }
        }
        pomodoroModeSelected = enabled; errorText = ""; justCompletedPhase = 0
        refreshSnapshot()
    }
    public func requestModeSwitch(usePomodoro: Bool) {
        guard usePomodoro != pomodoroModeSelected else { return }
        let plan = try? focus.planModeSwitch(taskID: selectedTaskID, title: selectedTaskTitle)
        if let plan, plan.kind == "confirmSwitch" {
            // 切模式只换计时方式：确认结束后停在新模式待机；直接走确认框而不经 openTask，
            // 因为同一任务正在计时会被 openTask 当成「回到当前专注」。
            requestEndThen(taskID: plan.taskID, title: plan.title, pomodoro: usePomodoro, autoStart: false)
        } else {
            toPomodoroTab(usePomodoro)
        }
    }
    @discardableResult private func enterPomodoroWithTask(_ taskID: Int, _ title: String) -> Bool {
        cancelAutoAdvance(); refreshSnapshot()
        let safe = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taskID > 0, !safe.isEmpty else { errorText = "番茄任务无效，请重试"; return false }
        if snapshot.hasActiveSession || snapshot.phase != 0 {
            switch stopBusyTimerForSwitch(action: "enterPomodoro", taskID: taskID, title: safe) {
            case .confirming: return true
            case .failed: errorText = "切换番茄失败，请重试"; return false
            case .stopped: break
            }
        }
        // 外部任务选择是新的明确意图，一次性替换模式和任务缓存。
        pomodoroModeSelected = true; selectedTaskID = taskID; selectedTaskTitle = safe
        errorText = ""; justCompletedPhase = 0; refreshTaskNotes()
        return true
    }
    @discardableResult private func enterFreeWithTask(_ taskID: Int, _ title: String) -> Bool {
        if !freeModeAvailable { return enterPomodoroWithTask(taskID, title) }
        cancelAutoAdvance(); refreshSnapshot()
        let safe = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taskID > 0, !safe.isEmpty else { errorText = "自由专注任务无效，请重试"; return false }
        if snapshot.hasActiveSession || snapshot.phase != 0 { errorText = "已有计时进行中"; return false }
        pomodoroModeSelected = false; selectedTaskID = taskID; selectedTaskTitle = safe
        errorText = ""; justCompletedPhase = 0; refreshTaskNotes()
        return true
    }
    // 把任务和模式落到本页，调用前计时器必须已空闲。autoStart 为假时停在待机，番茄模式顺带展开时长面板。
    @discardableResult private func applyTask(_ taskID: Int, _ title: String, pomodoro: Bool, autoStart: Bool) -> Bool {
        let usePomodoro = pomodoro || !freeModeAvailable
        guard usePomodoro ? enterPomodoroWithTask(taskID, title) : enterFreeWithTask(taskID, title) else { return false }
        if autoStart { return usePomodoro ? startPomodoro() : startFreeFocus() }
        panelExpanded = usePomodoro
        return true
    }
    // 当前计时会被截断：先记下「结束之后做什么」再弹确认框，确认之前不动计时器。
    private func requestEndThen(taskID: Int, title: String, pomodoro: Bool, autoStart: Bool) {
        cancelAutoAdvance(); refreshSnapshot(); syncToActiveTimer()
        let consequence = switchConsequenceText()
        let message = autoStart
            ? "将开始：\(title)。\(consequence)"
            : "将切换到\(pomodoro ? "番茄专注" : "自由专注")：\(title)，切换后不会自动开始。\(consequence)"
        switchPrompt = FocusSwitchPrompt(taskID: taskID, title: title, pomodoro: pomodoro, autoStart: autoStart,
                                         source: try? focus.captureSwitchSource(), message: message)
    }
    // 被截断的是什么由当前阶段决定，不能对休息也说「专注不足 3 分钟不会保存」。
    private func switchConsequenceText() -> String {
        guard let consequence = try? focus.switchConsequence() else { return "" }
        if consequence.kind == "restKept" { return "当前休息会保留在时间轴中。" }
        return consequence.kind == "notSaved" ? "当前专注不足 \(consequence.minimumMinutes) 分钟，不会保存。" : "当前专注会先保存。"
    }
    public func cancelSwitch() { switchPrompt = nil }
    public func confirmSwitch() {
        guard let intent = switchPrompt else { return }
        switchPrompt = nil
        // 状态是否变过、要不要超长确认、停表是否成功都由控制器判断。
        let outcome: String
        do {
            guard let source = intent.source else { throw CocoaError(.fileReadUnknown) }
            outcome = try focus.stopForSwitch(source)
        } catch { errorText = "计时状态已变化，请重新选择任务"; return }
        switch outcome {
        case "stateChanged": errorText = "计时状态已变化，请重新选择任务"
        case "needsLongFreeConfirmation":
            let action = intent.autoStart ? (intent.pomodoro ? "startPomodoro" : "startFree")
                                          : (intent.pomodoro ? "enterPomodoro" : "enterFree")
            requestLongFreeConfirmation(action: action, taskID: intent.taskID, title: intent.title)
        case "stopFailed": errorText = "当前计时保存失败，未切换"
        default: applyTask(intent.taskID, intent.title, pomodoro: intent.pomodoro, autoStart: intent.autoStart)
        }
        refreshSnapshot()
    }

    // MARK: 沉浸
    public func enterImmersive() { if immersiveAvailable { immersiveActive = true } }
    public func exitImmersive() { immersiveActive = false }

    // MARK: FocusFlowHook
    // 任务入口（今日、仪表盘、本周）的统一落点；分流由控制器的 planTaskEntry 决定。
    public func openTask(taskId: Int, title: String) {
        refreshSnapshot()
        guard let plan = try? focus.planTaskEntry(taskID: taskId, title: title), plan.kind != "invalid" else {
            // 静默返回会让「开始」点了没反应；必须给出可见原因。
            errorText = "任务信息无效，无法开始计时"; return
        }
        switch plan.kind {
        case "returnToCurrent": syncToActiveTimer()
        case "confirmSwitch": requestEndThen(taskID: taskId, title: title, pomodoro: plan.usePomodoro, autoStart: plan.autoStart)
        default: applyTask(taskId, title, pomodoro: plan.usePomodoro, autoStart: plan.autoStart)
        }
    }
    // 完成的正是正在计时的任务时顺带结束这段专注；是否结束只认控制器的判断。
    public func taskCompleted(taskId: Int) -> TaskCompletionFocusOutcome {
        // 停表发生在这次调用里，计时器会同步发 sessionDiscarded：标志必须罩住这次调用本身。
        endingForCompletion = true
        let completed = try? focus.handleTaskCompleted(taskID: taskId)
        endingForCompletion = false
        guard let completed, completed.focusResult != "none" else { return .none }
        let result = applyInPlaceEnd(FocusEndResult(result: completed.focusResult, kind: completed.kind,
                                                    discarded: completed.discarded, error: completed.error))
        switch result {
        case .none: return .none
        case .confirming: return .needsConfirmation
        case .failed: return .failed
        case .ended: return .ended(discarded: completed.discarded)
        }
    }
}

extension FocusEndResult {
    init(result: String, kind: String = "", discarded: Bool = false, error: String = "") {
        self.init()
        self.result = result; self.kind = kind; self.discarded = discarded; self.error = error
    }
}
