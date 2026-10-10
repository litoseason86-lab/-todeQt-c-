import Foundation

public struct CountdownValue: Equatable, Identifiable, Sendable {
    public var id = -1
    public var name = ""
    public var targetDate = ""
    public var displayOrder = 0
    public var daysRemaining = 0
    public var createdAt = ""
    public var updatedAt = ""
    public init() {}
}
// nil 表示未改；空文本或分类 0 表示明确清空。
public struct CountdownChanges: Equatable, Sendable {
    public var name: String?
    public var targetDate: String?
    public init(name: String? = nil, targetDate: String? = nil) {
        self.name = name
        self.targetDate = targetDate
    }
    public var isEmpty: Bool { name == nil && targetDate == nil }
}
@MainActor public protocol CountdownBridging: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onPrimaryGoalChanged: (() -> Void)? { get set }
    func goals() throws -> [CountdownValue]
    func primaryGoal() throws -> CountdownValue?
    func add(name: String, date: String) throws
    func update(id: Int, changes: CountdownChanges) throws
    func delete(id: Int) throws
    func reorder(from: Int, to: Int) throws
    func daysRemaining(date: String) -> Int
}
