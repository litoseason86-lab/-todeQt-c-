import Foundation
public struct CategoryValue: Equatable, Sendable {
    public var id = -1
    public var name = ""
    public var color = ""
    public var isPreset = false
    public var displayOrder = 0
    public var createdAt = ""
    public init() {}
}
public struct CategoryChanges: Equatable, Sendable {
    public var name: String?
    public var color: String?
    public init(name: String? = nil, color: String? = nil) { self.name = name; self.color = color }
    public var isEmpty: Bool { name == nil && color == nil }
}
@MainActor public protocol CategoryBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func allCategories() throws -> [CategoryValue]
    func category(id: Int) throws -> CategoryValue
    func add(name: String, color: String) throws -> Int
    func update(id: Int, name: String, color: String) throws
    func update(id: Int, changes: CategoryChanges) throws
    func delete(id: Int) throws
    func canDelete(id: Int) -> Bool
    func nameExists(_ name: String, excluding id: Int) -> Bool
}
public extension CategoryBridgeProtocol {
    func update(id: Int, changes: CategoryChanges) throws {
        guard !changes.isEmpty else { return }
        let current = try category(id: id)
        try update(id: id, name: changes.name ?? current.name, color: changes.color ?? current.color)
    }
}
