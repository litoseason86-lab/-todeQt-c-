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
@MainActor public protocol CategoryBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func allCategories() throws -> [CategoryValue]
    func category(id: Int) throws -> CategoryValue
    func add(name: String, color: String) throws -> Int
    func update(id: Int, name: String, color: String) throws
    func delete(id: Int) throws
    func canDelete(id: Int) -> Bool
    func nameExists(_ name: String, excluding id: Int) -> Bool
}
