import Foundation
import Observation

// 仪表盘只保存服务返回的今日快照；排序、统计归属和逻辑日都由桥接层决定。
@MainActor @Observable public final class DashboardStore {
    public private(set) var todayStats = DayStatistics()
    public private(set) var tasks: [TaskValue] = []
    public private(set) var streakDays = 0
    public private(set) var totalFocusSeconds = 0
    public private(set) var nickname = ""
    public private(set) var loadError = ""
    public private(set) var now = Date()
    public var topTasks: [TaskValue] { Array(tasks.prefix(6)) }
    public var greeting: String { DashboardFormat.greeting(for: Calendar.current.component(.hour, from: now)) }
    public var dateText: String { DashboardFormat.dateText(now) }

    @ObservationIgnored private let tasksBridge: any TaskBridgeProtocol
    @ObservationIgnored private let statistics: any StatisticsBridgeProtocol
    @ObservationIgnored private let settings: any SettingsBridgeProtocol
    @ObservationIgnored private let actions: TaskActions
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private weak var focus: FocusStore?
    @ObservationIgnored private let logicalDay: (any LogicalDayBridgeProtocol)?
    @ObservationIgnored private let nowProvider: () -> Date
    @ObservationIgnored private var active = false

    public init(tasks: any TaskBridgeProtocol, statistics: any StatisticsBridgeProtocol,
                settings: any SettingsBridgeProtocol, actions: TaskActions, shell: ShellStore,
                focus: FocusStore, logicalDay: (any LogicalDayBridgeProtocol)? = nil, nowProvider: @escaping () -> Date = Date.init) {
        self.tasksBridge = tasks; self.statistics = statistics; self.settings = settings
        self.actions = actions; self.shell = shell; self.focus = focus; self.logicalDay = logicalDay; self.nowProvider = nowProvider
    }

    public func start() {
        guard !active else { return }
        active = true
        // 日界可能没有例行任务新增，不能靠任务信号间接刷新今日数据。
        logicalDay?.onChanged = { [weak self] in self?.refresh() }
        tasksBridge.onChanged = { [weak self] in self?.refresh() }
        tasksBridge.onFailure = { [weak self] message in self?.loadError = message.isEmpty ? "任务加载失败，请重试" : message }
        statistics.onFailure = { [weak self] message in self?.loadError = message.isEmpty ? "统计数据加载失败，请重试" : message }
        settings.onNicknameChanged = { [weak self] in self?.nickname = self?.settings.snapshot().nickname ?? "" }
        focus?.onFocusCompletedForPages = { [weak self] in self?.refresh() }
        refresh()
    }

    public func stop() {
        guard active else { return }
        active = false
        tasksBridge.onChanged = nil; tasksBridge.onFailure = nil; statistics.onFailure = nil
        logicalDay?.onChanged = nil
        settings.onNicknameChanged = nil
        if focus?.onFocusCompletedForPages != nil { focus?.onFocusCompletedForPages = nil }
    }

    public func refresh() {
        guard active else { return }
        now = nowProvider(); nickname = settings.snapshot().nickname
        // 一次刷新从当前快照重新建立错误状态；某一路失败时保留它之前的数据显示，避免空白覆盖有效数据。
        loadError = ""
        do { tasks = try tasksBridge.todayTasks() } catch { loadError = "任务加载失败，请重试" }
        do { todayStats = try statistics.todayStats() } catch { loadError = "统计数据加载失败，请重试" }
        do { streakDays = try statistics.streakDays() } catch { loadError = "统计数据加载失败，请重试" }
        do { totalFocusSeconds = try statistics.totalFocusDuration() } catch { loadError = "统计数据加载失败，请重试" }
    }

    public func complete(_ task: TaskValue) { _ = actions.complete(id: task.id, title: task.title) }
    public func delete(_ task: TaskValue) { _ = actions.delete(id: task.id, title: task.title) }
    public func openFocus(_ task: TaskValue) { actions.openFocus(id: task.id, title: task.title) }
}
