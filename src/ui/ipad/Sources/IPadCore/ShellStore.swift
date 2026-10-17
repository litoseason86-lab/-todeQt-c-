import Foundation
import Observation

public struct ShellSummaryTile: Equatable, Sendable {
    public let page: PageID
    public let title: String
    public let value: String
}

public struct ShellSnapshot: Equatable, Sendable {
    public var todayPendingCount = 0
    public var weekPendingCount = 0
    public var todayFocusedSeconds = 0
    public var dueGapCount = 0
    public var hasTimer = false
    public var running = false
    public var mode = 0
    public var phase = 0
    public var elapsedSeconds = 0
    public var remainingSeconds = 0
    public var currentTaskId = -1
    public var taskTitle = ""
    public var operationBlocksUI = false
    public var operationText = ""
    public var sidebarOrder: [String] = []
    public var backgroundTheme = "warm"
    public var appearance = "system"
    public var hasPrimaryGoal = false
    public var primaryGoalName = ""
    public var primaryGoalDaysRemaining = 0
    public var useWallpaper = false
    public var selectedPage = "dashboard"
    public var maxCaptureTitleLength = 100
    public init() {}
}

// 外观三项：主题、外观模式、壁纸开关。各页外壳修饰与壁纸只读这一项（10-12 拆出，见 ShellStore.appearanceState）。
public struct ShellAppearanceState: Equatable, Sendable {
    public var backgroundTheme = "warm"
    public var appearance = "system"
    public var useWallpaper = false
    public init() {}
}

public struct ShellTimerSnapshot: Equatable, Sendable {
    public var hasTimer = false
    public var running = false
    public var mode = 0
    public var phase = 0
    public var elapsedSeconds = 0
    public var remainingSeconds = 0
    public var currentTaskId = -1
    public var taskTitle = ""
    public init() {}
}

@MainActor public protocol ShellBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onTimerChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func read() throws -> ShellSnapshot
    func readTimer() throws -> ShellTimerSnapshot
    func setNativeUI(_ value: Bool) throws
    func setAppearance(_ value: String) throws
    func selectTheme(_ value: String) throws
    func setUseWallpaper(_ value: Bool) throws
    func pause() throws
    func resume() throws
    func capture(title: String, categoryID: Int, sourceTaskID: Int) throws -> Int
    func select(page: String) throws
}

// 旧外壳替身不涉及新增的本机外观写入；默认拒绝，防止测试或其它实现假装保存成功。
public extension ShellBridgeProtocol {
    func setAppearance(_ value: String) throws { throw CocoaError(.featureUnsupported) }
    func selectTheme(_ value: String) throws { throw CocoaError(.featureUnsupported) }
    func setNativeUI(_ value: Bool) throws { throw CocoaError(.featureUnsupported) }
    func setUseWallpaper(_ value: Bool) throws { throw CocoaError(.featureUnsupported) }
}

// 记一笔的来源任务与它的科目；-1 表示无来源 / 未分类。
public struct ShellCaptureSource: Equatable, Sendable {
    public var taskID: Int
    public var categoryID: Int
    public init(taskID: Int = -1, categoryID: Int = -1) { self.taskID = taskID; self.categoryID = categoryID }
}

public enum CaptureAnchor: Hashable, Sendable {
    case page(PageID), search, moreRoot
}

public struct ShellToast: Identifiable {
    public let id: UUID
    public let message: String
    public let actionTitle: String?
}

@MainActor @Observable
public final class ShellStore {
    // 10-12 真机测速：快照原是一个整体属性，计时每秒改一次、每次写任务也整份重写，读它的视图（外壳根视图、
    // 每页的外壳修饰）就跟着整体重算：模拟计时跳一下主线程忙约 155 毫秒、动到 14 个外壳修饰。
    // 现按变化频率拆开存，视图只读自己需要的那几项；每项写入前先比较，值没变就不写
    // （Observation 不比较新旧值，照写一样会通知所有读过它的视图）。
    public private(set) var appearanceState = ShellAppearanceState()
    public private(set) var operationBlocksUI = false
    public private(set) var operationText = ""
    public private(set) var dueGapCount = 0
    public private(set) var hasTimer = false
    // 计时读数每秒都变；目前没有视图读它，留给需要读数的地方单独订阅。
    public private(set) var timer = ShellTimerSnapshot()
    // 其余字段（计数、主目标、侧栏顺序、选中页偏好等）：只在服务通知变化后整份重读时更新，计时跳动不碰它；
    // 上面单独存放的几项在这里一律是默认值，读它们要用各自的属性。
    public private(set) var details = ShellSnapshot()
    // 兼容入口：按上面各项拼回整份快照，给测试和动作里的判断用。视图别读它——读它等于同时订阅了所有项。
    public var snapshot: ShellSnapshot {
        var value = details
        value.backgroundTheme = appearanceState.backgroundTheme
        value.appearance = appearanceState.appearance
        value.useWallpaper = appearanceState.useWallpaper
        value.operationBlocksUI = operationBlocksUI
        value.operationText = operationText
        value.dueGapCount = dueGapCount
        value.hasTimer = timer.hasTimer
        value.running = timer.running
        value.mode = timer.mode
        value.phase = timer.phase
        value.elapsedSeconds = timer.elapsedSeconds
        value.remainingSeconds = timer.remainingSeconds
        value.currentTaskId = timer.currentTaskId
        value.taskTitle = timer.taskTitle
        return value
    }
    public private(set) var selection: PageID = .dashboard
    public private(set) var errorMessage = ""
    public private(set) var toast: ShellToast?
    public private(set) var sidebarPages: [PageID] = PageID.ordered([]).filter {
        !PageID.summary.prefix(3).contains($0) && !PageID.fixed.contains($0)
    }
    public private(set) var morePages: [PageID] = PageID.ordered([]).filter { !PageID.primary.contains($0) }
    public var captureTitle = ""
    public var capturePresented = false
    // 打开位置固定到这次展示：10-12 真机复现切页后开关仍为 true、宿主丢失或落到不可见页面，后续弹窗也被挡住。
    // TabView / NavigationStack 的 onAppear、onDisappear 顺序不能用来认领宿主；显式记录位置并在导航时关闭。
    public private(set) var captureAnchor: CaptureAnchor?
    // 专注页计时进行中无操作时，右上角「记一笔」随计时按钮一起淡出（隐藏与否由 FocusStore 判断，
    // 专注页在动画事务里写进来、离页时清掉）；其它页不会写它。
    public var focusChromeHidden = false
    public private(set) var captureError = ""
    // P4 各页登记保存回调与新建/开始意图，外壳只转发；不在这里决定任务或计时业务流程。
    // 跨页动作由原生根装配一次，持有点让占位外壳也能保存共用撤销状态。
    // 历史页只发日期和切页意图；今日专注页消费一次，业务记录读取仍由该页 Store 负责。
    public private(set) var requestedFocusDate: String?
    public func openFocusHistory(date: String) {
        guard !operationBlocksUI else { return }
        requestedFocusDate = date
        select(.todayFocus)
    }
    public func consumeRequestedFocusDate() -> String? {
        defer { requestedFocusDate = nil }
        return requestedFocusDate
    }
    public var taskActions: TaskActions?
    @ObservationIgnored public var onNewTask: (() -> Void)?
    @ObservationIgnored public var onStartOrPause: (() -> Void)?
    // 055-P4-1：专注页的记一笔要带当前计时任务与科目，其它页没有来源。由原生根装配，
    // 提供者在每次打开记一笔时现取，避免来源停留在上一次的任务上。
    @ObservationIgnored public var captureSourceProvider: (() -> ShellCaptureSource?)?
    @ObservationIgnored private var captureSource = ShellCaptureSource()
    @ObservationIgnored private var editFlushers: [UUID: () -> Void] = [:]
    @ObservationIgnored public var onAccessibilityTimeoutSuspensionChanged: ((Bool) -> Void)?
    // nil 表示尚未接收系统状态；首次关闭也要转发，解除旧根视图可能留在共享删除槽中的暂停。
    @ObservationIgnored private var voiceOverEnabled: Bool?
    @ObservationIgnored private var toastDurationMilliseconds: UInt64 = 5000
    @ObservationIgnored private let bridge: any ShellBridgeProtocol
    @ObservationIgnored private var toastAction: (() -> Void)?
    @ObservationIgnored private var toastRetired: (() -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    public init(bridge: any ShellBridgeProtocol) {
        self.bridge = bridge
        // Qt 信号经桥接回主线程；统计失效重读完整快照，tick 只投影计时字段，避免每秒查询统计。
        // 弱引用避免 Store 与桥接回调互相保留。
        bridge.onChanged = { [weak self] in self?.refresh() }
        bridge.onTimerChanged = { [weak self] in self?.refreshTimer() }
        bridge.onFailure = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
        }
        refresh()
        selection = PageID(rawValue: details.selectedPage) ?? .dashboard
    }

    public var orderedPages: [PageID] { PageID.ordered(details.sidebarOrder) }
    public func summaryTiles(focusTimeText: String) -> [ShellSummaryTile] {
        // 定稿摘要块写「时:分」（1:05）：块宽只放得下四五个数字，整句「1 小时 5 分」会被截断。计时中沿用计时器读数。
        let minutes = max(0, details.todayFocusedSeconds) / 60
        let focusValue = hasTimer ? focusTimeText : "\(minutes / 60):" + String(format: "%02d", minutes % 60)
        let goalTitle = details.hasPrimaryGoal ? details.primaryGoalName : "目标倒计时"
        let goalValue = details.hasPrimaryGoal ? CountdownFormat.days(details.primaryGoalDaysRemaining) : "—"
        return [
            ShellSummaryTile(page: .today, title: PageID.today.title, value: "\(details.todayPendingCount)"),
            ShellSummaryTile(page: .focus, title: PageID.focus.title, value: focusValue),
            ShellSummaryTile(page: .week, title: "本周待办", value: "\(details.weekPendingCount)"),
            ShellSummaryTile(page: .countdown, title: goalTitle, value: goalValue)
        ]
    }
    public func sidebarBadge(for page: PageID) -> Int? {
        page == .knowledgeGap && dueGapCount > 0 ? dueGapCount : nil
    }
    public static func navigationTarget(for page: PageID, size: ShellWindowSize) -> ShellNavigationTarget {
        switch size {
        case .compact where !PageID.primary.contains(page): return .more(path: [page])
        case .compact, .regular: return .page(page)
        }
    }

    private func updateNavigationPages(for sidebarOrder: [String]) {
        let ordered = PageID.ordered(sidebarOrder)
        let sidebar = ordered.filter { !PageID.summary.prefix(3).contains($0) && !PageID.fixed.contains($0) }
        let more = ordered.filter { !PageID.primary.contains($0) }
        if sidebarPages != sidebar { sidebarPages = sidebar }
        if morePages != more { morePages = more }
    }

    public func refresh() {
        do {
            let value = try bridge.read()
            apply(value)
            updateNavigationPages(for: value.sidebarOrder)
            if !errorMessage.isEmpty { errorMessage = "" }
        } catch { errorMessage = error.localizedDescription }
    }
    public func refreshTimer() {
        do {
            let value = try bridge.readTimer()
            applyTimer(value)
        } catch { errorMessage = error.localizedDescription }
    }
    // 整份快照按项分发，每项变了才写。
    private func apply(_ value: ShellSnapshot) {
        var appearance = ShellAppearanceState()
        appearance.backgroundTheme = value.backgroundTheme
        appearance.appearance = value.appearance
        appearance.useWallpaper = value.useWallpaper
        if appearance != appearanceState { appearanceState = appearance }
        if value.operationBlocksUI != operationBlocksUI { operationBlocksUI = value.operationBlocksUI }
        if value.operationText != operationText { operationText = value.operationText }
        if value.dueGapCount != dueGapCount { dueGapCount = value.dueGapCount }
        var timerValue = ShellTimerSnapshot()
        timerValue.hasTimer = value.hasTimer; timerValue.running = value.running
        timerValue.mode = value.mode; timerValue.phase = value.phase
        timerValue.elapsedSeconds = value.elapsedSeconds; timerValue.remainingSeconds = value.remainingSeconds
        timerValue.currentTaskId = value.currentTaskId; timerValue.taskTitle = value.taskTitle
        applyTimer(timerValue)
        // 已单独存放的几项在这里清回默认值，计时在走时每次重读也不会因为秒数不同而让「其余字段」变一次。
        var rest = value
        let blank = ShellSnapshot()
        rest.backgroundTheme = blank.backgroundTheme; rest.appearance = blank.appearance; rest.useWallpaper = blank.useWallpaper
        rest.operationBlocksUI = blank.operationBlocksUI; rest.operationText = blank.operationText; rest.dueGapCount = blank.dueGapCount
        rest.hasTimer = blank.hasTimer; rest.running = blank.running; rest.mode = blank.mode; rest.phase = blank.phase
        rest.elapsedSeconds = blank.elapsedSeconds; rest.remainingSeconds = blank.remainingSeconds
        rest.currentTaskId = blank.currentTaskId; rest.taskTitle = blank.taskTitle
        if rest != details { details = rest }
    }
    private func applyTimer(_ value: ShellTimerSnapshot) {
        if value != timer { timer = value }
        if value.hasTimer != hasTimer { hasTimer = value.hasTimer }
    }
    public var selectedSystemAppearance: String? { appearanceState.appearance == "theme" ? nil : appearanceState.appearance }
    public var selectedTheme: String? { appearanceState.appearance == "theme" ? appearanceState.backgroundTheme : nil }
    public var wallpaperAvailable: Bool { appearanceState.appearance == "theme" }
    public var wallpaperVisible: Bool { wallpaperAvailable && appearanceState.useWallpaper }
    public func setAppearance(_ value: String) {
        guard !operationBlocksUI else { return }
        let previous = appearanceState
        do { try bridge.setAppearance(value); refresh() }
        catch { appearanceState = previous; errorMessage = error.localizedDescription }
    }
    public func selectTheme(_ value: String) {
        guard !operationBlocksUI else { return }
        let previous = appearanceState
        do { try bridge.selectTheme(value); refresh() }
        catch { appearanceState = previous; errorMessage = error.localizedDescription }
    }
    public func setUseWallpaper(_ value: Bool) {
        guard wallpaperAvailable && !operationBlocksUI else { return }
        let previous = appearanceState.useWallpaper
        do {
            try bridge.setUseWallpaper(value)
            refresh()
        } catch {
            appearanceState.useWallpaper = previous
            errorMessage = error.localizedDescription
        }
    }
    public func useLegacyUIOnNextLaunch() {
        guard !operationBlocksUI else { return }
        do {
            try bridge.setNativeUI(false)
            errorMessage = ""
            showToast("下次启动将使用旧版界面")
        } catch { errorMessage = error.localizedDescription }
    }
    // 055-R4：搜索不是侧栏页面，没有 PageID；selection 仍是进搜索前那页（离开搜索时回到它）。
    // 「当前实际显示的是不是搜索」单独记在这里：记一笔的来源、宽窄切换后停在哪，都按它判断。
    public private(set) var searchShown = false
    // 每次切页或打开搜索都加一，外壳据此重新对齐标签与「更多」路径。
    // 选的还是同一页（从搜索回到原页、页面快捷键）时 selection 不变，只靠它通知外壳。
    public private(set) var navigationRequest = 0
    public func openSearch() {
        dismissCapture()
        searchShown = true
        navigationRequest += 1
    }
    // 外壳里直接离开搜索（窄窗从搜索页返回「更多」列表）：只清标记，不切页。
    public func closeSearch() {
        dismissCapture()
        searchShown = false
    }
    public func select(_ page: PageID) {
        guard !operationBlocksUI else { return }
        dismissCapture()
        selection = page
        searchShown = false
        navigationRequest += 1
        do { try bridge.select(page: page.rawValue) }
        catch { errorMessage = error.localizedDescription }
    }
    public func presentCapture() {
        presentCapture(from: searchShown ? .search : .page(selection))
    }
    // 来源只取打开位置；「更多」根列表或搜索可能仍保留专注页 selection，不能据此带入任务。
    public func presentCapture(from anchor: CaptureAnchor) {
        guard !operationBlocksUI else { return }
        captureSource = anchor == .page(.focus) ? (captureSourceProvider?() ?? ShellCaptureSource()) : ShellCaptureSource()
        captureError = ""
        captureAnchor = anchor
        capturePresented = true
    }
    public func isCapturePresented(at anchor: CaptureAnchor) -> Bool {
        capturePresented && captureAnchor == anchor
    }
    public func captureDismissed(at anchor: CaptureAnchor) {
        // 旧页面的关闭回调可能晚于新页面打开，不能收掉新位置的浮层。
        guard captureAnchor == anchor else { return }
        dismissCapture()
    }
    // 「取消」与点浮层外面一样只关闭，不清空没记下的文字。
    public func dismissCapture() { capturePresented = false }
    // 工具栏按钮再点一下就关闭：从工具栏按钮弹出的气泡不保证因点按钮本身而收起。
    public func toggleCapture(from anchor: CaptureAnchor) {
        if isCapturePresented(at: anchor) { dismissCapture() }
        else { presentCapture(from: anchor) }
    }
    @discardableResult public func capture() -> Bool {
        guard !operationBlocksUI else { return false }
        let title = captureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { captureError = "先写一句，哪怕只是几个关键词"; return false }
        // 桥接用抛错返回本次已认领的原因，不再从外壳共用错误中猜测，避免沿用旧错误（062 A039）。
        do {
            guard try bridge.capture(title: title, categoryID: captureSource.categoryID, sourceTaskID: captureSource.taskID) > 0 else {
                captureError = "没能存下来，请再试一次"
                return false
            }
        } catch {
            captureError = error.localizedDescription
            return false
        }
        captureTitle = ""
        captureError = ""
        capturePresented = false
        showToast("已记入知识缺口")
        return true
    }

    public func setVoiceOverEnabled(_ enabled: Bool) {
        guard voiceOverEnabled != enabled else { return }
        voiceOverEnabled = enabled
        onAccessibilityTimeoutSuspensionChanged?(enabled)
        scheduleToastTimeout()
    }

    // 读屏时保留带动作的提示，避免尚未到达撤销按钮就自动提交；纯信息提示仍按原时长退出。
    private func scheduleToastTimeout() {
        toastTask?.cancel()
        toastTask = nil
        guard let current = toast,
              !(voiceOverEnabled == true && current.actionTitle != nil && toastAction != nil) else { return }
        let id = current.id
        let duration = toastDurationMilliseconds
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(duration)) }
            catch { return }
            guard self?.toast?.id == id else { return }
            self?.retireToast()
        }
    }

    // 提示条只有一个槽；替换、超时、主动收起均通知原调用方，供待删项提交，动作执行时不重复提交。
    public func showToast(_ message: String, actionTitle: String? = nil,
                          durationMilliseconds: UInt64 = 5000,
                          action: (() -> Void)? = nil, onRetired: (() -> Void)? = nil) {
        retireToast()
        let id = UUID()
        toast = ShellToast(id: id, message: message, actionTitle: actionTitle)
        toastAction = action
        toastRetired = onRetired
        toastDurationMilliseconds = durationMilliseconds
        scheduleToastTimeout()
    }
    public func retireToast() {
        toastTask?.cancel()
        toastTask = nil
        let retired = toastRetired
        toast = nil
        toastAction = nil
        toastRetired = nil
        retired?()
    }
    public func triggerToastAction() {
        guard !operationBlocksUI else { return }
        let action = toastAction
        toastRetired = nil
        retireToast()
        action?()
    }
    @discardableResult public func registerEditFlusher(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID()
        editFlushers[token] = callback
        return token
    }
    public func unregisterEditFlusher(_ token: UUID) { editFlushers.removeValue(forKey: token) }
    public func flushEdits() {
        // 复制回调集合后调用，保存过程允许页面注销；此方法必须同步完成后才能进入后台同步。
        for callback in Array(editFlushers.values) { callback() }
    }
}

public enum ShellDisplay {
    // 只格式化服务给出的秒数，不决定计时模式或统计归属；分钟超过 59 时不丢失小时。
    public static func clock(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }
}
