import Foundation
import IPadCore
import PTBridge

@MainActor final class TaskBridgeAdapter: TaskBridgeProtocol {
    var onChanged: (() -> Void)?
    var onDeleted: ((Int) -> Void)?
    var onRestored: ((Int, [Int]) -> Void)?
    var onFailure: ((String) -> Void)?
    private let bridge = PTTaskBridge()
    init() {
        // Qt 的接收上下文保证回调在主线程，进入 MainActor 后再通知展示层。
        bridge.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        bridge.onDeleted = { [weak self] id in MainActor.assumeIsolated { self?.onDeleted?(id) } }
        bridge.onRestored = { [weak self] id, sessions in MainActor.assumeIsolated { self?.onRestored?(id, sessions.map(\.intValue)) } }
        bridge.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } }
    }
    static func value(_ source: PTTaskValue) -> TaskValue {
        var value = TaskValue()
        value.id = source.taskId; value.title = source.title; value.categoryText = source.categoryText
        value.categoryID = source.categoryId; value.categoryName = source.categoryName; value.categoryColor = source.categoryColor
        value.date = source.date; value.completed = source.completed; value.createdAt = source.createdAt
        value.estimatedMinutes = source.estimatedMinutes; value.notes = source.notes; value.completionNote = source.completionNote
        value.displayOrder = source.displayOrder; value.actualPomodoros = source.actualPomodoros; value.focusedSeconds = source.focusedSeconds
        return value
    }
    private func values(_ result: PTTaskResult) throws -> [TaskValue] {
        guard result.valid else { throw NSError(domain: "PTTaskBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        return result.tasks.map(Self.value)
    }
    func tasks(date: String) throws -> [TaskValue] { try values(bridge.tasks(forDate: date)) }
    func todayTasks() throws -> [TaskValue] { try values(bridge.todayTasks()) }
    func weekTasks(startDate: String) throws -> [TaskValue] { try values(bridge.weekTasks(startDate)) }
    func overdueTasks() throws -> [TaskValue] { try values(bridge.overdueTasks()) }
    func task(id: Int) throws -> TaskValue { try values(bridge.task(id))[0] }
    func search(text: String, status: Int, limit: Int) throws -> [TaskValue] { try values(bridge.search(text, status: status, limit: limit)) }
    func create(title: String, date: String, categoryID: Int, estimatedMinutes: Int, notes: String) throws -> Int {
        try bridge.createTask(title, date: date, categoryId: categoryID, estimatedMinutes: estimatedMinutes, notes: notes)
    }
    func update(id: Int, changes: TaskChanges) throws {
        // 只转发非 nil 的改动，.none 明确清空科目；表单旧快照不能覆盖同步来的字段。
        let change = PTTaskChanges()
        if let value = changes.title { change.title = value }
        if let value = changes.category { switch value { case .none: change.categoryId = -1; case .selected(let id): change.categoryId = id } }
        if let value = changes.date { change.date = value }
        if let value = changes.estimatedMinutes { change.estimatedMinutes = value }
        if let value = changes.notes { change.notes = value }
        if let value = changes.completionNote { change.completionNote = value }
        try bridge.updateTask(id, changes: change)
    }
    func setCompleted(id: Int, completed: Bool) throws { try bridge.setCompleted(id, completed: completed) }
    func complete(id: Int, note: String) throws { try bridge.completeTask(id, note: note) }
    func move(id: Int, before: Int) throws { try bridge.moveTask(id, before: before) }
    func move(id: Int, date: String) throws { try bridge.moveTask(id, toDate: date) }
    func move(ids: [Int], date: String) throws { try bridge.moveTasks(ids.map { NSNumber(value: $0) }, toDate: date) }
    func moveToToday(ids: [Int]) throws { try bridge.moveTasks(toToday: ids.map { NSNumber(value: $0) }) }
    func duplicate(id: Int, date: String) throws { try bridge.duplicateTask(id, date: date) }
    func isRoutineGenerated(id: Int) -> Bool { bridge.isRoutineGeneratedTask(id) }
    func plannedMinutes(from start: String, days: Int, excluding taskID: Int) throws -> [Int] {
        try bridge.plannedMinutes(from: start, days: days, excludingTask: taskID).map(\.intValue)
    }
}
