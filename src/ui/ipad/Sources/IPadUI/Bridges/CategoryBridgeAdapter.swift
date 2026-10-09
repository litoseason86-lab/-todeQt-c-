import Foundation
import IPadCore
import PTBridge
@MainActor final class CategoryBridgeAdapter: CategoryBridgeProtocol {
    private let native = PTCategoryBridge()
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    init() {
        // Qt 已把跨线程信号排回主线程，适配器只进入主 actor 并逐字段拷贝。
        native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        native.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } }
    }
    private func values(_ result: PTCategoryResult) throws -> [CategoryValue] {
        guard result.valid else { throw NSError(domain: "PTBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        return result.categories.map { item in
            var value = CategoryValue(); value.id = item.categoryId; value.name = item.name; value.color = item.color
            value.isPreset = item.isPreset; value.displayOrder = item.displayOrder; value.createdAt = item.createdAt; return value
        }
    }
    func allCategories() throws -> [CategoryValue] { try values(native.allCategories()) }
    func category(id: Int) throws -> CategoryValue { try values(native.category(id)).first! }
    func add(name: String, color: String) throws -> Int { try native.addCategory(name, color: color) }
    func update(id: Int, name: String, color: String) throws { try native.updateCategory(id, name: name, color: color) }
    func delete(id: Int) throws { try native.deleteCategory(id) }
    func canDelete(id: Int) -> Bool { native.canDeleteCategory(id) }
    func nameExists(_ name: String, excluding id: Int) -> Bool { native.nameExists(name, excluding: id) }
}
