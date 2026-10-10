import Foundation
public struct RoutineValue: Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var categoryID: Int
    public var categoryName: String
    public var categoryColor: String
    public var active: Bool
    public var weekdays: Int
    public init(id: Int, title: String, categoryID: Int, categoryName: String = "", categoryColor: String = "", active: Bool = true, weekdays: Int) {
        self.id = id; self.title = title; self.categoryID = categoryID; self.categoryName = categoryName
        self.categoryColor = categoryColor; self.active = active; self.weekdays = weekdays
    }
}
public struct RoutineChanges: Equatable, Sendable {
    public var title: String?
    public var categoryID: Int?
    public init(title: String? = nil, categoryID: Int? = nil) { self.title = title; self.categoryID = categoryID }
    public var isEmpty: Bool { title == nil && categoryID == nil }
}
@MainActor public protocol RoutineBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func routines() throws -> [RoutineValue]
    func add(title: String, categoryID: Int, weekdays: Int) throws
    func update(id: Int, changes: RoutineChanges) throws
    func delete(id: Int) throws
    func setActive(id: Int, active: Bool) throws
    func setWeekdays(id: Int, weekdays: Int) throws
    func materializeToday() -> Int
}
