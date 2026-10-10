import Foundation
import IPadCore
import PTBridge

@MainActor final class KnowledgeGapAdapter: KnowledgeGapBridging {
    private let native = PTKnowledgeGapBridge()
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onTasksAffected: (() -> Void)?
    init() {
        // Qt 已排回主线程，适配器只转发并投影字段，不拆业务字典。
        native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        native.onTasksAffected = { [weak self] in MainActor.assumeIsolated { self?.onTasksAffected?() } }
        native.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } }
    }
    private func values(_ result: PTKnowledgeGapResult) throws -> [GapValue] {
        guard result.valid else { throw NSError(domain: "PTBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        return result.items.map { item in
            var value = GapValue()
            value.id = item.gapId
            value.title = item.title
            value.detail = item.detail
            value.categoryID = item.categoryId
            value.categoryName = item.categoryName
            value.categoryColor = item.categoryColor
            value.sourceTaskID = item.sourceTaskId
            value.sourceTaskTitle = item.sourceTaskTitle
            value.priority = item.priority
            value.status = item.status
            value.dueDate = item.dueDate
            value.scheduled = item.scheduled
            value.overdue = item.overdue
            value.overdueDays = item.overdueDays
            value.dueToday = item.dueToday
            value.resolution = item.resolution
            value.linkedTaskID = item.linkedTaskId
            value.linkedTaskCompleted = item.linkedTaskCompleted
            value.linkedTaskOpen = item.linkedTaskOpen
            value.linkedTaskTitle = item.linkedTaskTitle
            value.createdAt = item.createdAt
            value.updatedAt = item.updatedAt
            value.resolvedAt = item.resolvedAt
            return value
        }
    }
    private func changes(_ value: GapChanges) -> PTKnowledgeGapChanges {
        let result = PTKnowledgeGapChanges()
        if let field = value.title { result.title = field }
        if let field = value.categoryID { result.categoryId = field }
        if let field = value.detail { result.detail = field }
        if let field = value.priority { result.priority = field }
        if let field = value.dueDate { result.dueDate = field }
        return result
    }
    func gaps(status: Int, categoryID: Int, search: String) throws -> [GapValue] { try values(native.gaps(withStatus: status, categoryId: categoryID, search: search)) }
    func gap(id: Int) throws -> GapValue { try values(native.gap(id)).first! }
    func add(title: String, categoryID: Int, detail: String, priority: Int, dueDate: String, sourceTaskID: Int) throws -> Int { try native.addTitle(title, categoryId: categoryID, detail: detail, priority: priority, dueDate: dueDate, sourceTaskId: sourceTaskID) }
    func update(id: Int, changes value: GapChanges) throws { try native.updateGap(id, changes: changes(value)) }
    func schedule(id: Int, date: String) throws { try native.setDueDate(id, date: date) }
    func schedule(ids: [Int], date: String) throws { try native.moveGaps(ids.map { NSNumber(value: $0) }, date: date) }
    func resolve(id: Int, resolution: String) throws { try native.resolveGap(id, resolution: resolution) }
    func reopen(id: Int) throws { try native.reopenGap(id) }
    func delete(id: Int) throws { try native.deleteGap(id) }
    func convert(id: Int, date: String) throws -> Int { try native.convertGap(id, date: date) }
}
