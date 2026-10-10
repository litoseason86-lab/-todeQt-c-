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
    func setUseWallpaper(_ value: Bool) throws
    func pause() -> Bool
    func resume() -> Bool
    func capture(title: String, categoryID: Int, sourceTaskID: Int) -> Int
    func select(page: String)
}

// 旧外壳替身不涉及新增的本机外观写入；默认拒绝，防止测试或其它实现假装保存成功。
public extension ShellBridgeProtocol {
    func setAppearance(_ value: String) throws { throw CocoaError(.featureUnsupported) }
    func setNativeUI(_ value: Bool) throws { throw CocoaError(.featureUnsupported) }
    func setUseWallpaper(_ value: Bool) throws { throw CocoaError(.featureUnsupported) }
}

// 记一笔的来源任务与它的科目；-1 表示无来源 / 未分类。
public struct ShellCaptureSource: Equatable, Sendable {
    public var taskID: Int
    public var categoryID: Int
    public init(taskID: Int = -1, categoryID: Int = -1) { self.taskID = taskID; self.categoryID = categoryID }
}

public struct ShellToast: Identifiable {
    public let id: UUID
    public let message: String
    public let actionTitle: String?
}

@MainActor @Observable
public final class ShellStore {
    public private(set) var snapshot = ShellSnapshot()
    public private(set) var selection: PageID = .dashboard
    public private(set) var errorMessage = ""
    public private(set) var toast: ShellToast?
    public private(set) var sidebarPages: [PageID] = PageID.ordered([]).filter {
        !PageID.summary.prefix(3).contains($0) && !PageID.fixed.contains($0)
    }
    public private(set) var morePages: [PageID] = PageID.ordered([]).filter { !PageID.primary.contains($0) }
    public var captureTitle = ""
    public var capturePresented = false
    public private(set) var captureError = ""
    // P4 各页登记保存回调与新建/开始意图，外壳只转发；不在这里决定任务或计时业务流程。
    // 跨页动作由原生根装配一次，持有点让占位外壳也能保存共用撤销状态。
    // 历史页只发日期和切页意图；今日专注页消费一次，业务记录读取仍由该页 Store 负责。
    public private(set) var requestedFocusDate: String?
    public func openFocusHistory(date: String) {
        guard !snapshot.operationBlocksUI else { return }
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
        bridge.onFailure = { [weak self] message in self?.errorMessage = message }
        refresh()
        selection = PageID(rawValue: snapshot.selectedPage) ?? .dashboard
    }

    public var orderedPages: [PageID] { PageID.ordered(snapshot.sidebarOrder) }
    public func summaryTiles(focusTimeText: String) -> [ShellSummaryTile] {
        let focusValue = snapshot.hasTimer ? focusTimeText : DurationFormat.seconds(Double(snapshot.todayFocusedSeconds))
        let goalTitle = snapshot.hasPrimaryGoal ? snapshot.primaryGoalName : "目标倒计时"
        let goalValue = snapshot.hasPrimaryGoal ? "\(snapshot.primaryGoalDaysRemaining) 天" : "—"
        return [
            ShellSummaryTile(page: .today, title: PageID.today.title, value: "\(snapshot.todayPendingCount)"),
            ShellSummaryTile(page: .focus, title: PageID.focus.title, value: focusValue),
            ShellSummaryTile(page: .week, title: "本周待办", value: "\(snapshot.weekPendingCount)"),
            ShellSummaryTile(page: .countdown, title: goalTitle, value: goalValue)
        ]
    }
    public func sidebarBadge(for page: PageID) -> Int? {
        page == .knowledgeGap ? snapshot.dueGapCount : nil
    }
    public var miniTimerVisible: Bool { snapshot.hasTimer && selection != .focus }

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
            snapshot = value
            updateNavigationPages(for: value.sidebarOrder)
            errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }
    public func refreshTimer() {
        do {
            let value = try bridge.readTimer()
            snapshot.hasTimer = value.hasTimer
            snapshot.running = value.running
            snapshot.mode = value.mode
            snapshot.phase = value.phase
            snapshot.elapsedSeconds = value.elapsedSeconds
            snapshot.remainingSeconds = value.remainingSeconds
            snapshot.currentTaskId = value.currentTaskId
            snapshot.taskTitle = value.taskTitle
        } catch { errorMessage = error.localizedDescription }
    }
    public func setUseWallpaper(_ value: Bool) {
        let previous = snapshot.useWallpaper
        do {
            try bridge.setUseWallpaper(value)
            refresh()
        } catch {
            snapshot.useWallpaper = previous
            errorMessage = error.localizedDescription
        }
    }
    public func useLegacyUIOnNextLaunch() {
        guard !snapshot.operationBlocksUI else { return }
        do {
            try bridge.setNativeUI(false)
            errorMessage = ""
            showToast("下次启动将使用旧版界面")
        } catch { errorMessage = error.localizedDescription }
    }
    public func select(_ page: PageID) {
        guard !snapshot.operationBlocksUI else { return }
        selection = page
        bridge.select(page: page.rawValue)
    }
    public func toggleTimer() {
        guard !snapshot.operationBlocksUI else { return }
        let succeeded = snapshot.running ? bridge.pause() : bridge.resume()
        if !succeeded && errorMessage.isEmpty { errorMessage = "计时操作失败，请重试" }
    }
    public func presentCapture() {
        presentCapture(source: selection == .focus ? (captureSourceProvider?() ?? ShellCaptureSource()) : ShellCaptureSource())
    }
    // 带来源的入口：来源任务与科目随这次记一笔一起写入，打开时固定，之后任务切换也不改。
    public func presentCapture(source: ShellCaptureSource) {
        guard !snapshot.operationBlocksUI else { return }
        captureSource = source
        captureError = ""
        capturePresented = true
    }
    @discardableResult public func capture() -> Bool {
        guard !snapshot.operationBlocksUI else { return false }
        let title = captureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { captureError = "先写一句，哪怕只是几个关键词"; return false }
        if bridge.capture(title: title, categoryID: captureSource.categoryID, sourceTaskID: captureSource.taskID) <= 0 {
            captureError = errorMessage.isEmpty ? "没能存下来，请再试一次" : errorMessage
            return false
        }
        captureTitle = ""
        captureError = ""
        capturePresented = false
        showToast("已记入知识缺口")
        return true
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
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(durationMilliseconds)) }
            catch { return }
            guard self?.toast?.id == id else { return }
            self?.retireToast()
        }
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
        guard !snapshot.operationBlocksUI else { return }
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
