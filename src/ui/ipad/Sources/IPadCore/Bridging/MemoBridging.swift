import Foundation

public struct MemoValue: Equatable, Identifiable, Sendable {
    public var id = -1
    public var title = ""
    public var body = ""
    public var displayTitle = ""
    public var preview = ""
    public var categoryID = 0
    public var categoryName = ""
    public var categoryColor = ""
    public var sortOrder = 0
    public var createdAt = ""
    public var updatedAt = ""
    public init() {}
}
// nil 表示未改；空文本或分类 0 表示明确清空。
public struct MemoChanges: Equatable, Sendable {
    public var title: String?
    public var body: String?
    public var categoryID: Int?
    public init(title: String? = nil, body: String? = nil, categoryID: Int? = nil) {
        self.title = title
        self.body = body
        self.categoryID = categoryID
    }
    public var isEmpty: Bool { title == nil && body == nil && categoryID == nil }
}
@MainActor public protocol MemoBridging: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func memos() throws -> [MemoValue]
    func memo(id: Int) throws -> MemoValue
    func create(title: String, body: String, categoryID: Int) throws -> Int
    func update(id: Int, changes: MemoChanges) throws
    func delete(id: Int) throws
    func reorder(categoryID: Int, ids: [Int]) throws
}
