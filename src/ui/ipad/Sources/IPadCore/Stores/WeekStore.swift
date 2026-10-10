import Foundation
import Observation

public struct WeekDayGroup: Equatable, Sendable, Identifiable {
    public let date: String
    public var tasks: [TaskValue]
    public var plannedMinutes: Int
    public var id: String { date }
}

@MainActor @Observable public final class WeekStore {
    public private(set) var groups: [WeekDayGroup] = []
    public private(set) var weekStart: String
    public private(set) var logicalToday: String
    public private(set) var error = ""
    public private(set) var pendingTaskID = -1
    @ObservationIgnored private let tasks: any TaskBridgeProtocol
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    @ObservationIgnored private let weekDates: (String, Int) -> String
    public init(tasks: any TaskBridgeProtocol, logicalDay: any LogicalDayBridgeProtocol, pendingDeletion: PendingDeletionStore,
                weekStart: String, weekDates: @escaping (String, Int) -> String) {
        self.tasks = tasks; self.logicalDay = logicalDay; self.pendingDeletion = pendingDeletion
        self.weekStart = weekStart; logicalToday = logicalDay.today; self.weekDates = weekDates
        logicalDay.onChanged = { [weak self] in self?.refresh() }; tasks.onChanged = { [weak self] in self?.refresh() }
        refresh()
    }
    public func refresh() {
        logicalToday = logicalDay.today
        do {
            let rows = try tasks.weekTasks(startDate: weekStart)
            let planned = try tasks.plannedMinutes(from: weekStart, days: 7, excluding: pendingDeletion.pendingTaskID)
            groups = (0..<7).map { day in WeekDayGroup(date: weekDates(weekStart, day), tasks: rows.filter { $0.date == weekDates(weekStart, day) }, plannedMinutes: planned.indices.contains(day) ? max(0, planned[day]) : 0) }
            error = ""
        } catch { self.self.error = error.localizedDescription }
    }
    public func updateLogicalDay() { refresh() }
    public func canAdd(on date: String) -> Bool { date >= logicalToday }
    @discardableResult public func move(task: TaskValue, to date: String) -> Bool {
        guard task.date != date else { return true }
        do { try tasks.move(id: task.id, date: date); refresh(); return true } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult public func reorder(task: TaskValue, before: TaskValue) -> Bool {
        guard task.id != before.id else { return true }
        do { try tasks.move(id: task.id, before: before.id); refresh(); return true } catch { self.error = error.localizedDescription; return false }
    }
    public func markPendingTask(_ id: Int) { pendingTaskID = id }
    public func clearPendingTask() { pendingTaskID = -1 }
}
