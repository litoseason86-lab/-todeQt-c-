import Foundation
import IPadCore

// 内联新建替身严格按真实服务的时序：先更新列表并发变化，再返回编号。
@MainActor final class TaskFormCategoryFake: CategoryBridgeProtocol {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var values: [CategoryValue] = []
    var readError: Error?
    var writeError: Error?
    var createdID = 55
    var writes: [(String, String)] = []
    func allCategories() throws -> [CategoryValue] { if let readError { throw readError }; return values }
    func category(id: Int) throws -> CategoryValue { try allCategories().first { $0.id == id } ?? CategoryValue() }
    func add(name: String, color: String) throws -> Int {
        writes.append((name, color)); if let writeError { throw writeError }
        var value = CategoryValue(); value.id = createdID; value.name = name; value.color = color
        values.insert(value, at: 0); onChanged?(); return createdID
    }
    func update(id: Int, name: String, color: String) throws {}
    func delete(id: Int) throws {}
    func canDelete(id: Int) -> Bool { true }
    func nameExists(_ name: String, excluding id: Int) -> Bool { false }
}
