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
    // 行内新建（对齐提醒事项，10-12）：列表底部「＋ 新任务」点开一行输入框，回车建好并接着起下一行，
    // 空行回车或点别处结束。⌘N 等入口置位聚焦请求，页面还没创建时请求不会丢。
    public private(set) var composing = false
    public private(set) var newTaskFocusRequested = false
    public var newTitle = ""
    // 「已完成」组默认收起；同一次运行里离开再回来保持用户上次的选择（提醒事项的「显示已完成」也是记住的）。
    public var completedExpanded = false
    // 多选模式：选中集合只记编号；刷新后不在列表里的编号自动剔除。
    public private(set) var selecting = false
    public private(set) var selection: Set<Int> = []
    public private(set) var goalProgressPercent: Double = 0
    public let tools: TodayToolsStore
    // 打勾后停留（10-12 用户定）：刚完成的任务先在原位置留 lingerDelay 再收进「已完成」组，
    // 连续打勾时从最后一次起算、一起收。值是打勾那一刻它在未完成组里的位置。
    public private(set) var lingering: [Int: Int] = [:]
    @ObservationIgnored public var lingerDelay: Duration = .milliseconds(1500)
    @ObservationIgnored private var lingerTask: Task<Void, Never>?

    // 待删任务立刻隐藏；撤销后 pendingTaskID 回到 -1，下一次读取自然恢复。
    private var visibleTasks: [TaskValue] {
        let hidden = pendingDeletion.pendingTaskID
        return hidden > 0 ? tasks.filter { $0.id != hidden } : tasks
    }
    // 服务已把完成项排在末尾；这里只按完成态分组并保持组内原序，不再排序。
    // 停留中的已完成任务按打勾时的位置插回未完成组（按位置从小到大插，连续打勾的几条各回各位）。
    public var unfinished: [TaskValue] {
        let visible = visibleTasks
        var rows = visible.filter { !$0.completed }
        guard !lingering.isEmpty else { return rows }
        for (id, index) in lingering.sorted(by: { $0.value < $1.value }) {
            if let task = visible.first(where: { $0.id == id && $0.completed }) { rows.insert(task, at: min(index, rows.count)) }
        }
        return rows
    }
    public var finished: [TaskValue] { visibleTasks.filter { $0.completed && lingering[$0.id] == nil } }
    // 多选能选到的行：未完成组（含停留的），「已完成」组展开时也算。
    public var selectable: [TaskValue] { completedExpanded ? unfinished + finished : unfinished }
    public var allSelected: Bool { !selection.isEmpty && selectable.allSatisfy { selection.contains($0.id) } }
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
        settleLingering(); endSelection(); composing = false; newTitle = ""; newTaskFocusRequested = false
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
        do { tasks = try taskBridge.todayTasks() } catch { fail("任务加载失败，请重试"); return }
        // 别处删掉或改期走的任务不再停留、也不留在选中集合里。
        let ids = Set(visibleTasks.map(\.id))
        let lingeringLeft = lingering.filter { ids.contains($0.key) }
        if lingeringLeft.count != lingering.count { lingering = lingeringLeft }
        if !selection.isSubset(of: ids) { selection = selection.intersection(ids) }
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

    // MARK: 新建（行内）
    // 建在逻辑今天、无科目、不预计用时；科目等细节建好后点 ⓘ 补。成功后清空输入、仍在新建状态（回车接下一条）。
    @discardableResult public func submitNewTask() -> Bool {
        guard shell?.operationBlocksUI != true else { return false }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        do { _ = try taskBridge.create(title: title, date: logicalDay.today, categoryID: -1, estimatedMinutes: 0, notes: "") }
        catch { loadError = error.localizedDescription; return false }
        newTitle = ""; newTaskFocusRequested = false
        refresh()
        return true
    }
    // 起一行新任务并请求聚焦；多选中不起（提醒事项选择模式下也不能新建）。
    public func requestNewTask() {
        guard !selecting else { return }
        composing = true; newTaskFocusRequested = true
    }
    public func acknowledgeNewTaskRequest() { newTaskFocusRequested = false }
    // 结束新建：有字就先建上（点别处、Esc 都不丢已输入的标题），建失败保留这一行和文字，让用户看到原因。
    public func endComposing() {
        guard composing else { return }
        if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitNewTask() { return }
        composing = false; newTitle = ""; newTaskFocusRequested = false
    }

    // MARK: 完成与停留
    // 打勾：先登记停留再写库，写库触发的刷新里这一行就留在原位；写失败撤掉登记。取消完成不停留。
    public func toggleCompletion(_ task: TaskValue, using actions: TaskActions) {
        if task.completed {
            if lingering[task.id] != nil { lingering[task.id] = nil }
            _ = actions.uncomplete(id: task.id)
            return
        }
        guard let index = unfinished.firstIndex(where: { $0.id == task.id }) else {
            _ = actions.complete(id: task.id, title: task.title); return
        }
        lingering[task.id] = index
        guard actions.complete(id: task.id, title: task.title) else { lingering[task.id] = nil; return }
        scheduleSettle()
    }
    // 停留结束：全部收进「已完成」组。离开页面、进入多选时也立刻收。
    public func settleLingering() {
        lingerTask?.cancel(); lingerTask = nil
        if !lingering.isEmpty { lingering = [:] }
    }
    private func scheduleSettle() {
        lingerTask?.cancel()
        let delay = lingerDelay
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.settleLingering()
        }
    }

    // MARK: 多选
    public func beginSelection() {
        endComposing()
        // 草稿写入失败时保留新建行，不能再进入与它互斥的多选模式。
        guard !composing else { return }
        settleLingering()
        selecting = true; selection = []
    }
    public func endSelection() { selecting = false; if !selection.isEmpty { selection = [] } }
    public func toggleSelection(_ id: Int) {
        guard selecting else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    // 「全选」再点一次是全不选（照提醒事项）。
    public func toggleSelectAll() {
        selection = allSelected ? [] : Set(selectable.map(\.id))
    }
    // 按列表顺序交出选中的编号：批量写入按选择集合的展示顺序，结果与用户看到的一致。
    public var orderedSelection: [Int] { selectable.map(\.id).filter { selection.contains($0) } }
    @discardableResult public func completeSelection(using actions: TaskActions) -> Bool {
        let ids = orderedSelection
        guard !ids.isEmpty, actions.complete(ids: ids) else { return false }
        endSelection(); return true
    }
    @discardableResult public func deleteSelection(using actions: TaskActions) -> Bool {
        let ids = orderedSelection
        guard !ids.isEmpty, actions.delete(ids: ids) else { return false }
        endSelection(); return true
    }
    @discardableResult public func rescheduleSelection(to date: String) -> Bool {
        let ids = orderedSelection
        guard !ids.isEmpty else { return false }
        do { try taskBridge.move(ids: ids, date: date) }
        catch { loadError = error.localizedDescription; return false }
        endSelection(); return true
    }

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
    // 目标编辑器打开时的起始分钟：今天设过就从当前目标改；没设过才用服务给的预填值（逻辑昨天实际专注的整小时，
    // 10-12 用户定）。不足 1 小时或读不出来时为 0，编辑器从空白开始。预填只是起始值，不点保存就不算设了目标。
    public func goalEditorStartMinutes() -> Int {
        if goalMinutes > 0 { return goalMinutes }
        return (try? statistics.suggestedDailyGoalMinutes(logicalToday: logicalDay.today)) ?? 0
    }
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

// 今日目标编辑器的草稿：小时、分钟两个输入框与 ±15 分、±1 小时按钮共用一个总分钟数
// （10-12 用户要求：原来 5 分钟一档，设 8 小时要点太多下）。范围 0–1440，与 AppSettings 的目标上限一致；
// 0 只表示还没填，保存至少要 1 分钟（服务也拒绝 0）。
public struct DailyGoalDraft: Equatable, Sendable {
    public static let maxMinutes = 24 * 60
    public private(set) var totalMinutes: Int
    public init(minutes: Int) { totalMinutes = Self.clamped(minutes) }
    public var hours: Int { totalMinutes / 60 }
    public var minutes: Int { totalMinutes % 60 }
    public var canSave: Bool { totalMinutes >= 1 }
    // 按钮按总分钟加减，越界停在边上不回绕：6:00 减 15 分是 5:45，不是只动分钟框。
    public mutating func adjust(by delta: Int) { totalMinutes = Self.clamped(totalMinutes + delta) }
    public mutating func setFields(hours: String, minutes: String) {
        totalMinutes = Self.clamped(HourMinuteFields.minutes(hours: hours, minutes: minutes, cap: Self.maxMinutes))
    }
    private static func clamped(_ value: Int) -> Int { min(max(value, 0), maxMinutes) }
}

// 「小时」「分钟」两个输入框合成总分钟数，今日目标与补录时长共用：空框按 0；分钟可以填超过 59，
// 按总分钟折算（填 90 就是 1 小时 30 分）；数字以外的字符忽略。结果不夹范围，由各自的草稿决定上下限。
enum HourMinuteFields {
    static func minutes(hours: String, minutes: String, cap: Int) -> Int {
        number(hours, cap: cap) * 60 + number(minutes, cap: cap)
    }
    private static func number(_ text: String, cap: Int) -> Int {
        // 每位累积后立即饱和，下一次乘 10 的值始终有界；前导零不改变数值，长串粘贴也不会溢出。
        var value = 0
        for byte in text.utf8 where byte >= 48 && byte <= 57 {
            value = min(value * 10 + Int(byte - 48), cap)
        }
        return value
    }
}
