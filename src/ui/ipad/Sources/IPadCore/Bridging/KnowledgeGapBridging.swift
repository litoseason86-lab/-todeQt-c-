import Foundation

public struct GapValue: Equatable, Identifiable, Sendable {
    public var id = -1
    public var title = ""
    public var detail = ""
    public var categoryID = 0
    public var categoryName = ""
    public var categoryColor = ""
    public var sourceTaskID = -1
    public var sourceTaskTitle = ""
    public var priority = 0
    public var status = 0
    public var dueDate = ""
    public var scheduled = false
    public var overdue = false
    public var overdueDays = 0
    public var dueToday = false
    public var resolution = ""
    public var linkedTaskID = -1
    public var linkedTaskCompleted = false
    public var linkedTaskOpen = false
    public var linkedTaskTitle = ""
    public var createdAt = ""
    public var updatedAt = ""
    public var resolvedAt = ""
    public init() {}
}
// nil 表示未改；空文本或分类 0 表示明确清空。
public struct GapChanges: Equatable, Sendable {
    public var title: String?
    public var categoryID: Int?
    public var detail: String?
    public var priority: Int?
    public var dueDate: String?
    public init(title: String? = nil, categoryID: Int? = nil, detail: String? = nil, priority: Int? = nil, dueDate: String? = nil) {
        self.title = title
        self.categoryID = categoryID
        self.detail = detail
        self.priority = priority
        self.dueDate = dueDate
    }
    public var isEmpty: Bool { title == nil && categoryID == nil && detail == nil && priority == nil && dueDate == nil }
}
@MainActor public protocol KnowledgeGapBridging: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onTasksAffected: (() -> Void)? { get set }
    func gaps(status: Int, categoryID: Int, search: String) throws -> [GapValue]
    func gap(id: Int) throws -> GapValue
    func add(title: String, categoryID: Int, detail: String, priority: Int, dueDate: String, sourceTaskID: Int) throws -> Int
    func update(id: Int, changes: GapChanges) throws
    func schedule(id: Int, date: String) throws
    func schedule(ids: [Int], date: String) throws
    func resolve(id: Int, resolution: String) throws
    func reopen(id: Int) throws
    func delete(id: Int) throws
    func convert(id: Int, date: String) throws -> Int
}
