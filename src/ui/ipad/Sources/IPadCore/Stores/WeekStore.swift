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
        snapshotGroups.map { group in
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
        guard !interactions.refreshBlocked else { refreshPending = true; return }
        refreshPending = false
        do {
            let start = try weekStartProvider?() ?? weekStart
            let dates = try weekDates(start)
            guard dates.count == 7 else { throw NSError(domain: "WeekStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "周日期读取不完整"]) }
            let rows = try tasks.weekTasks(startDate: start)
            let planned = try tasks.plannedMinutes(from: start, days: 7, excluding: pendingDeletion.pendingTaskID)
            snapshotGroups = dates.enumerated().map { day, date in
                WeekDayGroup(date: date, tasks: rows.filter { $0.date == date },
                             plannedMinutes: planned.indices.contains(day) ? max(0, planned[day]) : 0)
            }
            weekStart = start; logicalToday = logicalDay.today; error = ""
            if task(id: cursorTaskID) == nil { cursorTaskID = -1 }
        } catch { self.error = error.localizedDescription }
    }
    public func updateLogicalDay() { refresh() }
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
