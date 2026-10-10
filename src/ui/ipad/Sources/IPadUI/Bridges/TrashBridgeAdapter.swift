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
        value.items = result.items.compactMap(Self.item)
        return value
    }
    func purgeExpired() throws -> Int { try native.purgeExpired() }
    func restore(id: Int) throws -> TrashActionResult { Self.action(try native.restoreItem(id)) }
    func delete(id: Int) throws -> TrashActionResult { Self.action(try native.deleteItem(id)) }
    func empty(ids: [Int]) throws -> TrashActionResult { Self.action(try native.emptyTrash(ids.map(NSNumber.init))) }

    private static func action(_ raw: [AnyHashable: Any]) -> TrashActionResult {
        func text(_ key: String) -> String { raw[key] as? String ?? "" }
        return TrashActionResult(title: text("title"), error: text("error"), code: text("code"), conflict: text("conflict"))
    }

    private static func item(_ raw: [AnyHashable: Any]) -> TrashItem? {
        guard let id = raw["id"] as? NSNumber else { return nil }
        let details = raw["details"] as? [AnyHashable: Any] ?? [:]
        func text(_ key: String) -> String { details[key] as? String ?? "" }
        func number(_ key: String) -> Int { (details[key] as? NSNumber)?.intValue ?? 0 }
        func flag(_ key: String) -> Bool { (details[key] as? NSNumber)?.boolValue ?? false }
        var value = TrashDetails()
        value.date = text("date"); value.completed = flag("completed"); value.estimatedMinutes = number("estimatedMinutes")
        value.startTime = text("startTime"); value.endTime = text("endTime"); value.durationSeconds = number("durationSeconds")
        value.mode = number("mode"); value.taskTitle = text("taskTitle"); value.manual = flag("manual")
        value.dueDate = text("dueDate"); value.status = number("status"); value.weekdays = number("weekdays"); value.active = flag("active")
        value.weekday = number("weekday"); value.startMinutes = number("startMinutes"); value.endMinutes = number("endMinutes")
        value.weekStart = number("weekStart"); value.weekEnd = number("weekEnd"); value.weekParity = number("weekParity")
        value.location = text("location"); value.targetDate = text("targetDate")
        return TrashItem(id: id.intValue,
                         kind: raw["kind"] as? String ?? "",
                         title: raw["title"] as? String ?? "",
                         deletedAt: raw["deletedAt"] as? String ?? "",
                         deletedDate: raw["deletedDate"] as? String ?? "",
                         remainingDays: (raw["remainingDays"] as? NSNumber)?.intValue ?? 0,
                         originSyncID: raw["originSyncId"] as? String ?? "",
                         categoryName: raw["categoryName"] as? String ?? "",
                         categoryColor: raw["categoryColor"] as? String ?? "",
                         restorable: (raw["restorable"] as? NSNumber)?.boolValue ?? false,
                         blockedReason: raw["blockedReason"] as? String ?? "",
                         details: value)
    }
}
