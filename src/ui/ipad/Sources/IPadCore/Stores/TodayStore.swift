import Foundation
import Observation

// 今日任务页的展示与交互状态。业务规则（哪些任务属于今天、逾期口径、排序整集合重排、
// 已排分钟的加总、逻辑日）一律由 C++ 服务经桥接给出，这里不比较日期、不加总、不另算逻辑日。
@MainActor @Observable public final class TodayStore {
    // 服务给的今日任务原序（含待删行）；分组与待删隐藏由下面的计算属性做。
    public private(set) var tasks: [TaskValue] = []
    public private(set) var overdue: [TaskValue] = []
    public private(set) var rolloverBannerActive = false
    public private(set) var today = ""
    public private(set) var goalMinutes = 0
    public private(set) var plannedMinutes = 0
    public private(set) var focusedSeconds = 0
    public private(set) var gapSummary: GapReminderSummary?
    public private(set) var gapConvertMessage = ""
    public private(set) var loadError = ""
    // ⌘N 等入口置位并打开同一表单；页面还没创建时请求不会丢。
    public private(set) var newTaskFocusRequested = false
    public var newTitle = ""
    public var newCategoryID = -1
    public var newEstimatedMinutes = 0
    public var newNotes = ""
    public var newTaskPresented = false
    public enum Filter: String, CaseIterable, Sendable { case unfinished, finished }
    public var filter: Filter = .unfinished
    public var filteredTasks: [TaskValue] { filter == .unfinished ? unfinished : finished }
    public private(set) var goalProgressPercent: Double = 0
    public private(set) var newCategories: [CategoryValue] = []
    public private(set) var newFormError = ""
    public let tools: TodayToolsStore

    // 待删任务立刻隐藏；撤销后 pendingTaskID 回到 -1，下一次读取自然恢复。
    private var visibleTasks: [TaskValue] {
        let hidden = pendingDeletion.pendingTaskID
        return hidden > 0 ? tasks.filter { $0.id != hidden } : tasks
    }
    // 服务已把完成项排在末尾；这里只按完成态分组并保持组内原序，不再排序。
    public var unfinished: [TaskValue] { visibleTasks.filter { !$0.completed } }
    public var finished: [TaskValue] { visibleTasks.filter { $0.completed } }
    public var gapBannerActive: Bool { (gapSummary?.dueToday ?? 0) + (gapSummary?.overdue ?? 0) > 0 }
    // 文案照 Mac：只报三个数，不拼成长句。
    public var gapBannerText: String {
        guard let summary = gapSummary else { return "" }
        if summary.overdue > 0 {
            return "\(summary.dueToday + summary.overdue) 条知识缺口到期 · \(summary.overdue) 条已逾期 · 最久 \(summary.oldestOverdueDays) 天"
        }
        return "\(summary.dueToday) 条知识缺口今天到期"
    }
    // 副标题日期以外的部分：目标、已排、已专注；时长格式走统一口径。
    public var subtitleParts: [String] {
        [goalMinutes > 0 ? "目标 " + DurationFormat.minutes(Double(goalMinutes)) : "未设目标",
         "已排 " + DurationFormat.minutes(Double(plannedMinutes)),
         "已专注 " + DurationFormat.seconds(Double(focusedSeconds))]
    }
    // 说清回看了几天：更早的未完成任务已放弃追踪，不写明的话数字对不上用户的印象。天数取服务常量，
    // 拿不到（0）时退回不带天数的说法，与 Mac 一致。
    public var rolloverBannerText: String {
        let days = taskBridge.overdueRolloverDays
        return days > 0 ? "最近 \(days) 天还有 \(overdue.count) 个未完成任务" : "之前还有 \(overdue.count) 个未完成任务"
    }
    public var canReorder: Bool { pendingDeletion.pendingTaskID <= 0 }

    @ObservationIgnored private let taskBridge: any TaskBridgeProtocol
    @ObservationIgnored private let interactions: any InteractionBridgeProtocol
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private let settings: any SettingsBridgeProtocol
    @ObservationIgnored private let statistics: any StatisticsBridgeProtocol
    @ObservationIgnored private let gaps: any GapReminderBridgeProtocol
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    // 055-P4-1 步骤 4：专注完成后「已专注」要跟着变；宿主给本 Store 一份专用适配器，不给就不监听。
    @ObservationIgnored private let focus: (any FocusBridgeProtocol)?
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private var active = false
    // 冻结期间收到的刷新只记一笔，令牌释放时补读一次。
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var dragToken: InteractionToken?

    public init(tasks: any TaskBridgeProtocol, interactions: any InteractionBridgeProtocol,
                logicalDay: any LogicalDayBridgeProtocol, settings: any SettingsBridgeProtocol,
                statistics: any StatisticsBridgeProtocol, gaps: any GapReminderBridgeProtocol,
                pendingDeletion: PendingDeletionStore, shell: ShellStore,
                focus: (any FocusBridgeProtocol)? = nil) {
        self.focus = focus
        self.taskBridge = tasks; self.interactions = interactions; self.logicalDay = logicalDay
        self.settings = settings; self.statistics = statistics; self.gaps = gaps
        self.pendingDeletion = pendingDeletion; self.shell = shell
        self.tools = TodayToolsStore(tasks: tasks, logicalDay: logicalDay, pendingDeletion: pendingDeletion)
    }

    // MARK: 生命周期
    // 桥接的回调槽只有一个，所以宿主必须给本 Store 一份专用的桥接实例（别的页面各用各的，
    // CoreBridges 里的共享实例只用于调用），这里直接占用、离开页面时置空，不会与其它监听方互相覆盖。
    // 监听只在页面在前台时工作，避免后台页面白白重读（对照 Mac 的 pageActive 门禁）。
    public func start() {
        guard !active else { return }
        active = true
        filter = .unfinished
        taskBridge.onChanged = { [weak self] in self?.requestRefresh() }
        taskBridge.onFailure = { [weak self] message in
            guard let self, self.active else { return }
            self.loadError = message.isEmpty ? "任务加载失败，请重试" : message
        }
        interactions.onChanged = { [weak self] in self?.interactionChanged() }
        logicalDay.onChanged = { [weak self] in self?.requestRefresh() }
        settings.onDailyFocusGoalChanged = { [weak self] in
            guard let self, self.active else { return }
            self.loadGoal()
        }
        settings.onRolloverIgnoredDateChanged = { [weak self] in self?.requestRefresh() }
        gaps.onChanged = { [weak self] in
            guard let self, self.active else { return }
            self.loadGaps()
        }
        gaps.onTasksAffected = { [weak self] in self?.requestRefresh() }
        statistics.onFailure = { [weak self] message in
            guard let self, self.active else { return }
            self.loadError = message.isEmpty ? "统计数据加载失败，请重试" : message
        }
        focus?.onFocusCompleted = { [weak self] _ in
            guard let self, self.active else { return }
            self.loadStats(); self.loadGoal()
        }
        refresh()
    }
    public func stop() {
        guard active else { return }
        active = false
        releaseDrag()
        refreshPending = false
        tools.close()
        taskBridge.onChanged = nil; taskBridge.onFailure = nil
        interactions.onChanged = nil; logicalDay.onChanged = nil
        settings.onDailyFocusGoalChanged = nil; settings.onRolloverIgnoredDateChanged = nil
        gaps.onChanged = nil; gaps.onTasksAffected = nil; statistics.onFailure = nil
        focus?.onFocusCompleted = nil
    }

    // MARK: 读取
    public func refresh() {
        guard active else { return }
        // 编辑或拖动期间不重建列表（会销毁正在编辑的行），只记待补。
        if interactions.refreshBlocked { refreshPending = true; return }
        refreshPending = false
        // 一轮组合读取只在起点清错；后续成功不抹掉前面刚发生的失败。
        loadError = ""
        today = logicalDay.today
        loadOverdue(); loadTasks(); loadStats(); loadGoal(); loadGaps(); loadPlanned()
        tools.reloadIfOpen()
    }
    // 待删状态变化：隐藏/恢复那一行，「已排」也要换排除对象；已开始的拖动随之取消。
    public func pendingDeletionChanged() {
        if pendingDeletion.pendingTaskID > 0 { releaseDrag() }
        refresh()
    }
    private func requestRefresh() { if active { refresh() } }
    private func interactionChanged() {
        guard active else { return }
        // 拖动的登记被外部结束（例如令牌所属对象销毁），清掉残留。
        if dragToken != nil && !interactions.refreshBlocked { dragToken = nil }
        if !interactions.refreshBlocked && refreshPending { refresh() }
    }
    private func fail(_ message: String) { if loadError.isEmpty { loadError = message } }
    private func loadTasks() {
        do { tasks = try taskBridge.todayTasks() } catch { fail("任务加载失败，请重试") }
    }
    private func loadOverdue() {
        do {
            overdue = try taskBridge.overdueTasks()
            let ignored = settings.snapshot().rolloverIgnoredDate == logicalDay.today
            rolloverBannerActive = !overdue.isEmpty && !ignored
        } catch { fail("任务加载失败，请重试") }
    }
    private func loadStats() {
        do { focusedSeconds = try statistics.todayStats().totalDuration } catch { fail("统计数据加载失败，请重试") }
    }
    private func loadGoal() {
        goalMinutes = settings.dailyFocusGoal(date: logicalDay.today)
        // 进度来自服务的周复盘今日目标，不用不同查询时刻的数字在 Swift 重算比例。
        do { goalProgressPercent = try statistics.currentWeeklyReview().todayGoal?.progressPercent ?? 0 }
        catch { fail("统计数据加载失败，请重试") }
    }
    private func loadPlanned() {
        do {
            let hidden = pendingDeletion.pendingTaskID
            plannedMinutes = try taskBridge.plannedMinutes(from: logicalDay.today, days: 1, excluding: hidden > 0 ? hidden : -1).first ?? 0
        } catch { fail("任务加载失败，请重试") }
    }
    // 读取失败时提示条保持安静：一条写着「0 条」的提醒比没有提醒更让人困惑。
    private func loadGaps() {
        gapSummary = try? gaps.reminderSummary()
        if !gapBannerActive { gapConvertMessage = "" }
    }

    // MARK: 结转
    public func moveOverdueToToday() {
        do { try taskBridge.moveToToday(ids: overdue.map(\.id)) }
        catch { loadError = "结转失败，请重试"; return }
        refresh()
    }
    public func ignoreOverdueForToday() {
        do { try settings.setRolloverIgnoredDate(logicalDay.today) }
        catch { loadError = error.localizedDescription; return }
        rolloverBannerActive = false
    }

    // MARK: 知识缺口
    // 挑哪些条目、逐条事务、汇总成败与原因都由服务做；这里只报结果，失败必须说出来。
    public func convertDueGaps() {
        gapConvertMessage = ""
        let result: GapConversionResult
        do { result = try gaps.convertDueGapsToTasks() }
        catch { loadError = error.localizedDescription; return }
        loadGaps()
        if result.failed > 0 {
            let reason = result.reason.isEmpty ? "未知原因" : result.reason
            gapConvertMessage = result.converted > 0
                ? "有 \(result.failed) 条知识缺口没加上：\(reason)"
                : "\(result.failed) 条知识缺口没能加到今天：\(reason)"
        }
        if result.converted > 0 { shell?.showToast("已把 \(result.converted) 条知识缺口加到今天的任务") }
    }

    // MARK: 新建
    @discardableResult public func submitNewTask() -> Bool {
        guard shell?.snapshot.operationBlocksUI != true else { return false }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        do { _ = try taskBridge.create(title: title, date: logicalDay.today, categoryID: newCategoryID, estimatedMinutes: newEstimatedMinutes, notes: newNotes) }
        catch { newFormError = error.localizedDescription; loadError = newFormError; return false }
        newTitle = ""; newTaskFocusRequested = false; newTaskPresented = false
        refresh()
        return true
    }
    public func requestNewTask() {
        guard !newTaskPresented else { return }
        newTitle = ""; newCategoryID = -1; newEstimatedMinutes = 0; newNotes = ""; newFormError = ""
        newTaskPresented = true; newTaskFocusRequested = true
    }
    public func loadNewCategories(from bridge: any CategoryBridgeProtocol) {
        do { newCategories = try bridge.allCategories(); newFormError = "" }
        catch { newFormError = error.localizedDescription }
    }
    public func acknowledgeNewTaskRequest() { newTaskFocusRequested = false }

    // MARK: 排序
    // 拖动只交「把 X 移到 Y 之前」，整天重新编号、已完成固定在末尾由服务做。
    @discardableResult public func beginDrag(taskID: Int) -> Bool {
        guard canReorder, dragToken == nil, unfinished.contains(where: { $0.id == taskID }) else { return false }
        do { dragToken = try interactions.beginDrag(id: taskID, source: "TodayStore.drag"); return true }
        catch { loadError = error.localizedDescription; return false }
    }
    public func cancelDrag() { releaseDrag() }
    // target 是移动后在「未完成组」里的最终下标；落在该组之外（含已完成组）或原位不写库。
    @discardableResult public func commitDrag(taskID: Int, toIndex target: Int) -> Bool {
        let list = unfinished
        var written = false
        defer { releaseDrag(); if written { refresh() } }
        guard canReorder, let from = list.firstIndex(where: { $0.id == taskID }),
              target >= 0, target < list.count, target != from else { return false }
        // 向上移落在 target 那项之前；向下移落在 target 后一项之前，没有后一项时取第一条已完成任务，
        // 再没有就传 0 表示末尾。后面是已完成项时照样传它的编号，夹到组尾是服务的事。
        let before: Int
        if target < from { before = list[target].id }
        else if target + 1 < list.count { before = list[target + 1].id }
        else { before = finished.first?.id ?? 0 }
        do { try taskBridge.move(id: taskID, before: before) }
        catch { loadError = "任务排序保存失败，请重试"; return false }
        written = true
        return true
    }
    private func releaseDrag() {
        let token = dragToken; dragToken = nil; token?.end()
    }

    // MARK: 其它写入
    @discardableResult public func saveGoal(minutes: Int) -> Bool {
        do { try settings.setDailyFocusGoal(date: logicalDay.today, minutes: minutes) }
        catch { loadError = error.localizedDescription; return false }
        loadGoal(); return true
    }
    @discardableResult public func copyToToday(id: Int) -> Bool {
        do { try taskBridge.duplicate(id: id, date: logicalDay.today) }
        catch { loadError = error.localizedDescription; return false }
        return true
    }
    @discardableResult public func reschedule(id: Int, date: String) -> Bool {
        do { try taskBridge.move(id: id, date: date) }
        catch { loadError = error.localizedDescription; return false }
        return true
    }
}
