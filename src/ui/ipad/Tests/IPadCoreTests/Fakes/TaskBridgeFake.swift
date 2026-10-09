import Foundation
import IPadCore

@MainActor final class TaskBridgeFake: TaskBridgeProtocol {
    var onChanged: (() -> Void)?
    var onDeleted: ((Int) -> Void)?
    var onRestored: ((Int, [Int]) -> Void)?
    var onFailure: ((String) -> Void)?
    var result: [TaskValue] = []
    var createdID = 1
    var routine = false
    var error: Error?
    var calls: [(name: String, ids: [Int], text: [String], numbers: [Int])] = []
    var changes: [(Int, TaskChanges)] = []
    private func record(_ name: String, ids: [Int] = [], text: [String] = [], numbers: [Int] = []) throws {
        calls.append((name, ids, text, numbers)); if let error { throw error }
    }
    func tasks(date: String) throws -> [TaskValue] { try record("tasks", text: [date]); return result }
    func todayTasks() throws -> [TaskValue] { try record("todayTasks"); return result }
    func weekTasks(startDate: String) throws -> [TaskValue] { try record("weekTasks", text: [startDate]); return result }
    func overdueTasks() throws -> [TaskValue] { try record("overdueTasks"); return result }
    func task(id: Int) throws -> TaskValue { try record("task", ids: [id]); return result.first ?? TaskValue() }
    func search(text: String, status: Int, limit: Int) throws -> [TaskValue] { try record("search", text: [text], numbers: [status, limit]); return result }
    func create(title: String, date: String, categoryID: Int, estimatedMinutes: Int, notes: String) throws -> Int {
        try record("create", text: [title, date, notes], numbers: [categoryID, estimatedMinutes]); return createdID
    }
    func update(id: Int, changes: TaskChanges) throws { self.changes.append((id, changes)); try record("update", ids: [id]) }
    func setCompleted(id: Int, completed: Bool) throws { try record("setCompleted", ids: [id], numbers: [completed ? 1 : 0]) }
    func complete(id: Int, note: String) throws { try record("complete", ids: [id], text: [note]) }
    func move(id: Int, before: Int) throws { try record("moveBefore", ids: [id, before]) }
    func move(id: Int, date: String) throws { try record("moveDate", ids: [id], text: [date]) }
    func move(ids: [Int], date: String) throws { try record("moveDates", ids: ids, text: [date]) }
    func moveToToday(ids: [Int]) throws { try record("moveToday", ids: ids) }
    func duplicate(id: Int, date: String) throws { try record("duplicate", ids: [id], text: [date]) }
    func isRoutineGenerated(id: Int) -> Bool { calls.append(("routine", [id], [], [])); return routine }
}
