import Foundation
import IPadCore
import PTBridge
@MainActor final class TrashBridgeAdapter: TrashBridgeProtocol {
    private let native = PTTrashBridge(); var onChanged: (() -> Void)?
    init() { native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } } }
    func readItems() throws -> TrashRead {
        let result = native.readItems()
        guard result.valid else { throw NSError(domain: "PTTrashBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        var value = TrashRead(); value.today = result.today
        value.items = result.items.map(Self.item)
        return value
    }
    func purgeExpired() throws -> Int { try native.purgeExpired() }
    func restore(id: Int) throws -> TrashActionResult { Self.action(try native.restoreItem(id)) }
    func delete(id: Int) throws -> TrashActionResult { Self.action(try native.deleteItem(id)) }
    func empty(ids: [Int]) throws -> TrashActionResult { Self.action(try native.emptyTrash(ids.map(NSNumber.init))) }

    private static func action(_ value: PTTrashActionValue) -> TrashActionResult {
        TrashActionResult(title: value.title, error: value.error, code: value.code, conflict: value.conflict)
    }

    private static func item(_ item: PTTrashItemValue) -> TrashItem {
        let details = item.details
        var value = TrashDetails()
        value.date = details.date; value.completed = details.completed; value.estimatedMinutes = details.estimatedMinutes
        value.startTime = details.startTime; value.endTime = details.endTime; value.durationSeconds = details.durationSeconds
        value.mode = details.mode; value.taskTitle = details.taskTitle; value.manual = details.manual
        value.dueDate = details.dueDate; value.status = details.status; value.weekdays = details.weekdays; value.active = details.active
        value.weekday = details.weekday; value.startMinutes = details.startMinutes?.intValue; value.endMinutes = details.endMinutes?.intValue
        value.weekStart = details.weekStart; value.weekEnd = details.weekEnd; value.weekParity = details.weekParity
        value.location = details.location; value.targetDate = details.targetDate
        return TrashItem(id: item.itemId, kind: item.kind, title: item.title,
                         deletedAt: item.deletedAt, deletedDate: item.deletedDate, remainingDays: item.remainingDays,
                         originSyncID: item.originSyncId, categoryName: item.categoryName, categoryColor: item.categoryColor,
                         restorable: item.restorable, blockedReason: item.blockedReason, details: value)
    }
}
