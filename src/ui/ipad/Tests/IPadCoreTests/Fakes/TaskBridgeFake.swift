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
    var overdueRolloverDays = 0
    var planned: [Int] = []
    var error: Error?
    // 055-P4-1：逾期列表单独给；nil 时沿用 result。failing 只让指定方法失败，用来验证「某一路读取失败不拖垮其它读取」。
    var overdue: [TaskValue]?
    var failing: Set<String> = []
    var calls: [(name: String, ids: [Int], text: [String], numbers: [Int])] = []
    var onWrite: (() -> Void)?
    var changes: [(Int, TaskChanges)] = []
    private func record(_ name: String, ids: [Int] = [], text: [String] = [], numbers: [Int] = []) throws {
        calls.append((name, ids, text, numbers)); if let error { throw error }
        if failing.contains(name) { throw NSError(domain: "测试", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name) 失败"]) }
    }
    func tasks(date: String) throws -> [TaskValue] { try record("tasks", text: [date]); return result }
    func todayTasks() throws -> [TaskValue] { try record("todayTasks"); return result }
    func weekTasks(startDate: String) throws -> [TaskValue] { try record("weekTasks", text: [startDate]); return result }
    func overdueTasks() throws -> [TaskValue] { try record("overdueTasks"); return overdue ?? result }
    // 按编号查任务：给了 tasksByID 就严格按编号，缺的抛真实桥接同款「任务已不存在」；没给时沿用旧行为。
    var tasksByID: [Int: TaskValue]?
    func task(id: Int) throws -> TaskValue {
        try record("task", ids: [id])
        if let tasksByID {
            guard let value = tasksByID[id] else { throw NSError(domain: "PTTaskBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "任务已不存在"]) }
            return value
        }
        return result.first ?? TaskValue()
    }
    func search(text: String, status: Int, limit: Int) throws -> [TaskValue] { try record("search", text: [text], numbers: [status, limit]); return result }
    func create(title: String, date: String, categoryID: Int, estimatedMinutes: Int, notes: String) throws -> Int {
        try record("create", text: [title, date, notes], numbers: [categoryID, estimatedMinutes]); return createdID
    }
    func update(id: Int, changes: TaskChanges) throws { self.changes.append((id, changes)); try record("update", ids: [id]); onWrite?() }
    func setCompleted(id: Int, completed: Bool) throws { try record("setCompleted", ids: [id], numbers: [completed ? 1 : 0]); onWrite?() }
    func complete(id: Int, note: String) throws { try record("complete", ids: [id], text: [note]) }
    func move(id: Int, before: Int) throws { try record("moveBefore", ids: [id, before]) }
    func move(id: Int, date: String) throws { try record("moveDate", ids: [id], text: [date]) }
    func move(ids: [Int], date: String) throws { try record("moveDates", ids: ids, text: [date]) }
    func moveToToday(ids: [Int]) throws { try record("moveToday", ids: ids) }
    func setCompleted(ids: [Int], completed: Bool) throws { try record("setCompletedBatch", ids: ids, numbers: [completed ? 1 : 0]) }
    func delete(ids: [Int]) throws { try record("deleteBatch", ids: ids) }
    func duplicate(id: Int, date: String) throws { try record("duplicate", ids: [id], text: [date]) }
    func isRoutineGenerated(id: Int) -> Bool { calls.append(("routine", [id], [], [])); return routine }
    func plannedMinutes(from start: String, days: Int, excluding taskID: Int) throws -> [Int] {
        try record("plannedMinutes", ids: [taskID], text: [start], numbers: [days]); return planned
    }
}
