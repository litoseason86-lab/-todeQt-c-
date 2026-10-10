import Foundation
import IPadCore
import PTBridge

@MainActor final class MemoAdapter: MemoBridging {
    private let native = PTMemoBridge()
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    init() {
        // Qt 已排回主线程，适配器只转发并投影字段，不拆业务字典。
        native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        native.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } }
    }
    private func values(_ result: PTMemoResult) throws -> [MemoValue] {
        guard result.valid else { throw NSError(domain: "PTBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        return result.items.map { item in
            var value = MemoValue()
            value.id = item.memoId
            value.title = item.title
            value.body = item.body
            value.displayTitle = item.displayTitle
            value.preview = item.preview
            value.categoryID = item.categoryId
            value.categoryName = item.categoryName
            value.categoryColor = item.categoryColor
            value.sortOrder = item.sortOrder
            value.createdAt = item.createdAt
            value.updatedAt = item.updatedAt
            return value
        }
    }
    private func changes(_ value: MemoChanges) -> PTMemoChanges {
        let result = PTMemoChanges()
        if let field = value.title { result.title = field }
        if let field = value.body { result.body = field }
        if let field = value.categoryID { result.categoryId = field }
        return result
    }
    func memos() throws -> [MemoValue] { try values(native.memos()) }
    func memo(id: Int) throws -> MemoValue { try values(native.memo(id)).first! }
    func create(title: String, body: String, categoryID: Int) throws -> Int { try native.createTitle(title, body: body, categoryId: categoryID) }
    func update(id: Int, changes value: MemoChanges) throws { try native.updateMemo(id, changes: changes(value)) }
    func delete(id: Int) throws { try native.deleteMemo(id) }
    func reorder(categoryID: Int, ids: [Int]) throws { try native.reorderCategory(categoryID, ids: ids.map { NSNumber(value: $0) }) }
}
