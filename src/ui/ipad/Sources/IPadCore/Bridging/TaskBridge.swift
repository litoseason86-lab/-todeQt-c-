import Foundation

public struct TaskValue: Equatable, Sendable, Identifiable {
    public var id = -1
    public var title = ""
    public var categoryText = ""
    public var categoryID = -1
    public var categoryName = ""
    public var categoryColor = ""
    public var date = ""
    public var completed = false
    public var createdAt = ""
    public var estimatedMinutes = 0
    public var notes = ""
    public var completionNote = ""
    public var displayOrder = 0
    public var actualPomodoros = 0
    public var focusedSeconds = 0
    public init() {}
}
// nil 表示未修改；清空科目用 .none，清空文本用空串，不将清空与未修改混用。
public enum TaskCategoryChange: Equatable, Sendable { case none, selected(Int) }
public struct TaskChanges: Equatable, Sendable {
    public var title: String?
    public var category: TaskCategoryChange?
    public var date: String?
    public var estimatedMinutes: Int?
    public var notes: String?
    public var completionNote: String?
    public init() {}
}
@MainActor public protocol TaskBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onDeleted: ((Int) -> Void)? { get set }
    var onRestored: ((Int, [Int]) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func tasks(date: String) throws -> [TaskValue]
    func todayTasks() throws -> [TaskValue]
    func weekTasks(startDate: String) throws -> [TaskValue]
    func overdueTasks() throws -> [TaskValue]
    func task(id: Int) throws -> TaskValue
    func search(text: String, status: Int, limit: Int) throws -> [TaskValue]
    func create(title: String, date: String, categoryID: Int, estimatedMinutes: Int, notes: String) throws -> Int
    func update(id: Int, changes: TaskChanges) throws
    func setCompleted(id: Int, completed: Bool) throws
    func complete(id: Int, note: String) throws
    func move(id: Int, before: Int) throws
    func move(id: Int, date: String) throws
    func move(ids: [Int], date: String) throws
    func moveToToday(ids: [Int]) throws
    func duplicate(id: Int, date: String) throws
    func isRoutineGenerated(id: Int) -> Bool
    // 结转窗口天数，来自服务常量；0 表示不知道，提示不带天数。
    var overdueRolloverDays: Int { get }
    // 从 start 起连续 days 天、每天「已排」分钟；加总口径在 C++（含已完成、负值按 0、排除待删的那条）。
    func plannedMinutes(from start: String, days: Int, excluding taskID: Int) throws -> [Int]
}
