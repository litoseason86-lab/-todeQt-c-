import Foundation

public struct TrashDetails: Sendable, Equatable {
    public var date = ""
    public var completed = false
    public var estimatedMinutes = 0
    public var startTime = ""
    public var endTime = ""
    public var durationSeconds = 0
    public var mode = 0
    public var taskTitle = ""
    public var manual = false
    public var dueDate = ""
    public var status = 0
    public var weekdays = 0
    public var active = false
    public var weekday = 0
    public var startMinutes: Int?
    public var endMinutes: Int?
    public var weekStart = 0
    public var weekEnd = 0
    public var weekParity = 0
    public var location = ""
    public var targetDate = ""
    public init() {}
}

public struct TrashItem: Sendable, Equatable, Identifiable {
    public let id: Int
    public let kind: String
    public let title: String
    public let deletedAt: String
    public let deletedDate: String
    public let remainingDays: Int
    public let originSyncID: String
    public let categoryName: String
    public let categoryColor: String
    public let restorable: Bool
    public let blockedReason: String
    public let details: TrashDetails
    public init(id: Int, kind: String, title: String, deletedAt: String, deletedDate: String, remainingDays: Int,
                originSyncID: String, categoryName: String, categoryColor: String, restorable: Bool,
                blockedReason: String, details: TrashDetails) {
        self.id = id; self.kind = kind; self.title = title; self.deletedAt = deletedAt; self.deletedDate = deletedDate
        self.remainingDays = remainingDays; self.originSyncID = originSyncID; self.categoryName = categoryName
        self.categoryColor = categoryColor; self.restorable = restorable; self.blockedReason = blockedReason; self.details = details
    }
}

public struct TrashRead: Sendable, Equatable {
    public var today = ""
    public var items: [TrashItem] = []
    public init() {}
}

public struct TrashActionResult: Sendable, Equatable {
    public let title: String
    public let error: String
    public let code: String
    public let conflict: String
    public init(title: String = "", error: String = "", code: String = "", conflict: String = "") {
        self.title = title; self.error = error; self.code = code; self.conflict = conflict
    }
}

@MainActor public protocol TrashBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    func readItems() throws -> TrashRead
    func purgeExpired() throws -> Int
    func restore(id: Int) throws -> TrashActionResult
    func delete(id: Int) throws -> TrashActionResult
    func empty(ids: [Int]) throws -> TrashActionResult
}
