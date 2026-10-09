import Foundation

public struct GapReminderSummary: Equatable, Sendable {
    public var dueToday: Int = 0
    public var overdue: Int = 0
    public var unscheduled: Int = 0
    public var openTotal: Int = 0
    public var oldestOverdueDays: Int = 0
    public init() {}
}
public struct GapConversionResult: Equatable, Sendable {
    public var converted: Int = 0
    public var failed: Int = 0
    public var reason: String = ""
    public init() {}
}
@MainActor public protocol GapReminderBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onTasksAffected: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func reminderSummary() throws -> GapReminderSummary
    func convertDueGapsToTasks() throws -> GapConversionResult
}
