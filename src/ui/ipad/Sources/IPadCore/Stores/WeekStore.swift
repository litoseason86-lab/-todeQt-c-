import Foundation
import Observation

public struct WeekDayGroup: Equatable, Sendable, Identifiable {
    public let date: String
    public var tasks: [TaskValue]
    public var plannedMinutes: Int
    public var id: String { date }
}

@MainActor @Observable public final class WeekStore {
    private var snapshotGroups: [WeekDayGroup] = []
    public var groups: [WeekDayGroup] {
        guard pendingDeletion.pendingTaskID > 0 else { return snapshotGroups }
        return snapshotGroups.map { group in
            var visible = group
            visible.tasks.removeAll { $0.id == pendingDeletion.pendingTaskID }
            return visible
        }
    }
    public private(set) var weekStart: String
    public private(set) var logicalToday: String
    public private(set) var error = ""
    public private(set) var cursorTaskID = -1
    public private(set) var draggingTaskID = -1
    public private(set) var selecting = false
    public private(set) var selection: Set<Int> = []
    public var allSelected: Bool {
        let ids = groups.flatMap(\.tasks).map(\.id)
        return !ids.isEmpty && ids.allSatisfy { selection.contains($0) }
    }
    public var orderedSelection: [Int] { groups.flatMap(\.tasks).map(\.id).filter { selection.contains($0) } }
    @ObservationIgnored private let tasks: any TaskBridgeProtocol
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    @ObservationIgnored private let interactions: any InteractionBridgeProtocol
    @ObservationIgnored private let weekDates: (String) throws -> [String]
    @ObservationIgnored private let weekStartProvider: (() throws -> String)?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var dragToken: InteractionToken?
    @ObservationIgnored private var dragSessionID: UUID?
    @ObservationIgnored private var rescheduleToken: InteractionToken?

    public init(tasks: any TaskBridgeProtocol, logicalDay: any LogicalDayBridgeProtocol,
                pendingDeletion: PendingDeletionStore, interactions: any InteractionBridgeProtocol,
                weekStart: String, weekDates: @escaping (String) throws -> [String],
                weekStartProvider: (() throws -> String)? = nil) {
        self.tasks = tasks; self.logicalDay = logicalDay; self.pendingDeletion = pendingDeletion
        self.interactions = interactions; self.weekStart = weekStart; logicalToday = logicalDay.today
        self.weekDates = weekDates; self.weekStartProvider = weekStartProvider
        logicalDay.onChanged = { [weak self] in self?.refresh() }
        tasks.onChanged = { [weak self] in self?.refresh() }
        // 共用交互协调器冻结所有任务入口；最后一个令牌结束后只补一次读取。
        interactions.onChanged = { [weak self] in
            guard let self, !self.interactions.refreshBlocked, self.refreshPending else { return }
            self.refresh()
        }
        observePendingDeletion()
        refresh()
    }

    private func observePendingDeletion() {
        // Observation 的追踪是一次性的；变化回调发生在赋值前，排到主队列后读新槽并重新登记。
        withObservationTracking { _ = pendingDeletion.state } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observePendingDeletion()
            }
        }
    }
    public func refresh() {
        let followingRead = Result { try weekStartProvider?() ?? followedWeekStart }
        // 列表读取被冻结或失败时保留旧周，但「是否本周」先按服务当前的本周核对：跨周日界后旧周就不是本周了，
        // 外壳给的本周待办数已是新周的，不能接在旧周日期后面；读不到服务的本周也按「不是」处理。
        showsCurrentWeek = (try? followingRead.get()) == weekStart
        guard !interactions.refreshBlocked else { refreshPending = true; return }
        refreshPending = false
        do {
            let following = try followingRead.get()
            // 固定显示的周在日界换周后正好成了本周：恢复跟随，之后的日界照常前进。
            if shownWeekStart == following { shownWeekStart = nil }
            let start = shownWeekStart ?? following
            followedWeekStart = following
            let dates = try weekDates(start)
            guard dates.count == 7 else { throw NSError(domain: "WeekStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "周日期读取不完整"]) }
            let rows = try tasks.weekTasks(startDate: start)
            let planned = try tasks.plannedMinutes(from: start, days: 7, excluding: pendingDeletion.pendingTaskID)
            // 一次分组保留服务给的组内次序，避免七列各自扫描整周任务。
            let rowsByDate = Dictionary(grouping: rows, by: \.date)
            snapshotGroups = dates.enumerated().map { day, date in
                WeekDayGroup(date: date, tasks: rowsByDate[date] ?? [],
                             plannedMinutes: planned.indices.contains(day) ? max(0, planned[day]) : 0)
            }
            // 日界只带动仍跟随今日的选中项；手选日期保持，周被替换后失效选择退回今日。
            if selectedDate.isEmpty || selectedDate == logicalToday || !dates.contains(selectedDate) { selectedDate = logicalDay.today }
            weekStart = start; showsCurrentWeek = start == following; logicalToday = logicalDay.today; error = ""
            selection.formIntersection(Set(groups.flatMap(\.tasks).map(\.id)))
            if task(id: cursorTaskID) == nil { cursorTaskID = -1 }
        } catch { self.error = error.localizedDescription }
    }
    public func updateLogicalDay() { refresh() }
    // 055-R4 翻周（同 Mac 本周计划）：周的起止由服务按统一日界换算；翻到别的周后日界不抢回，
    // 翻回本周就重新跟随服务的「本周」。是不是本周一律拿显示的周和服务当前的本周比，
    // 不记累计翻了几周：跨过周日界后服务的本周会变，累计偏移就对不上了。
    @ObservationIgnored private var shownWeekStart: String?
    // 跟随中的本周起点：没有服务提供本周时（测试替身），翻回来要回到这里，而不是停在上次显示的周。
    @ObservationIgnored private lazy var followedWeekStart: String = weekStart
    public private(set) var showsCurrentWeek = true
    public func shiftWeek(_ delta: Int) {
        guard delta != 0 else { return }
        endSelection()
        do {
            let period = try logicalDay.period(anchor: weekStart, range: "week", shift: delta, logicalToday: logicalDay.today)
            // refresh 会核对当前周并恢复跟随；这里不提前查询一次周复盘来只取周起点。
            shownWeekStart = period.start
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    public var selectedDate = ""
    public var selectedGroup: WeekDayGroup? { groups.first { $0.date == selectedDate } ?? groups.first { $0.date == logicalToday } ?? groups.first }
    public func selectDay(_ date: String) { if groups.contains(where: { $0.date == date }) { selectedDate = date } }
    public var addTitle: String {
        guard let date = selectedGroup?.date, let index = groups.firstIndex(where: { $0.date == date }) else { return "添加" }
        return "添加到周" + ["一", "二", "三", "四", "五", "六", "日"][index]
    }
    public func isToday(_ date: String) -> Bool { date == logicalToday }

    public func beginSelection() {
        // 先释放拖动和改期令牌，让被冻结的最新周列表补读后再进入多选。
        cancelDrag(); endReschedule(); selecting = true; selection = []
    }
    public func endSelection() { selecting = false; selection = [] }
    public func toggleSelection(_ id: Int) {
        guard selecting, task(id: id) != nil else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    public func toggleSelectAll() {
        guard selecting else { return }
        selection = allSelected ? [] : Set(groups.flatMap(\.tasks).map(\.id))
    }
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
        do { try tasks.move(ids: ids, date: date); endSelection(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult public func moveSelectionToToday() -> Bool {
        let ids = orderedSelection
        guard !ids.isEmpty else { return false }
        do { try tasks.moveToToday(ids: ids); endSelection(); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    public func canAdd(on date: String) -> Bool {
        do { return try logicalDay.relation(date, to: logicalDay.today) != .earlier }
        catch { return false }
    }
    public func canStart(on date: String) -> Bool {
        do { return try logicalDay.relation(date, to: logicalDay.today) == .same }
        catch { return false }
    }
    @discardableResult public func addTask(title: String, date: String) -> Bool {
        do {
            guard try logicalDay.relation(date, to: logicalDay.today) != .earlier else {
                error = "过去的日期不能添加任务"; return false
            }
            _ = try tasks.create(title: title, date: date, categoryID: -1, estimatedMinutes: 0, notes: "")
            // 写入已成功时，后续读失败只留在列表错误区；不能让用户重试创建而产生重复任务。
            refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult public func move(task: TaskValue, to date: String) -> Bool {
        guard task.date != date else { return true }
        do { try tasks.move(id: task.id, date: date); refresh(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult public func reorder(task: TaskValue, before: TaskValue) -> Bool {
        guard task.id != before.id else { return true }
        do { try tasks.move(id: task.id, before: before.id); refresh(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    public func task(id: Int) -> TaskValue? { groups.lazy.flatMap(\.tasks).first { $0.id == id } }
    public func selectTask(id: Int) { cursorTaskID = task(id: id) == nil ? -1 : id }
    public func moveCursor(_ delta: Int) {
        guard draggingTaskID == -1 else { return }
        let ids = groups.flatMap(\.tasks).map(\.id)
        guard !ids.isEmpty else { cursorTaskID = -1; return }
        guard let current = ids.firstIndex(of: cursorTaskID) else {
            cursorTaskID = delta >= 0 ? ids[0] : ids[ids.count - 1]; return
        }
        let next = current + delta
        if ids.indices.contains(next) { cursorTaskID = ids[next] }
    }
    @discardableResult public func toggleCursorCompletion(using actions: TaskActions) -> Bool {
        guard draggingTaskID == -1, let selected = task(id: cursorTaskID) else { return false }
        return selected.completed ? actions.uncomplete(id: selected.id) : actions.complete(id: selected.id, title: selected.title)
    }
    @discardableResult public func startCursorFocus(using actions: TaskActions) -> Bool {
        guard draggingTaskID == -1, let selected = task(id: cursorTaskID), !selected.completed,
              canStart(on: selected.date) else { return false }
        actions.openFocus(id: selected.id, title: selected.title); return true
    }
    public func beginReschedule(id: Int) -> TaskValue? {
        guard rescheduleToken == nil else { return nil }
        do {
            let registration = try interactions.beginEdit(id: id, source: "ipad.week.reschedule")
            guard let latest = registration.task, latest.id == id else {
                registration.end(); error = "任务信息已变化，请重试"; return nil
            }
            rescheduleToken = registration; return latest
        } catch { self.error = error.localizedDescription; return nil }
    }
    public func endReschedule() {
        let registration = rescheduleToken; rescheduleToken = nil; registration?.end()
    }
    public func beginDrag(id: Int) -> UUID? {
        guard dragToken == nil, task(id: id) != nil else { return nil }
        do {
            dragToken = try interactions.beginDrag(id: id, source: "ipad.week.drag")
            let session = UUID(); dragSessionID = session; draggingTaskID = id; return session
        } catch { self.error = error.localizedDescription; return nil }
    }
    public func endDrag(session: UUID) {
        guard dragSessionID == session else { return }
        let registration = dragToken; dragToken = nil; dragSessionID = nil; draggingTaskID = -1
        registration?.end()
    }
    public func cancelDrag() { if let session = dragSessionID { endDrag(session: session) } }
    @discardableResult public func drop(taskID: Int, to date: String, before beforeID: Int? = nil) -> Bool {
        guard draggingTaskID == taskID, let session = dragSessionID, let dragged = task(id: taskID) else { return false }
        // 只在放下时写一次；悬停不改变模型，取消及拖回原日的组尾都不写库。
        var writeFailure: String?
        defer {
            endDrag(session: session)
            // 结束令牌可能立即补读；写失败仍须显示服务原文，不能被成功读取覆盖。
            if let writeFailure { error = writeFailure }
        }
        let saved: Bool
        if dragged.date == date {
            guard let beforeID, let target = task(id: beforeID), target.date == date else { return true }
            saved = reorder(task: dragged, before: target)
        } else {
            saved = move(task: dragged, to: date)
        }
        if !saved { writeFailure = error }
        return saved
    }
}
