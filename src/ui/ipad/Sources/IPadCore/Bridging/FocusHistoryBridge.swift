import Foundation
public struct SessionValue: Equatable, Sendable, Identifiable {
    public var id = -1
    public var taskID = -1
    public var taskTitle = ""
    public var startTime = ""
    public var endTime = ""
    public var durationSeconds = 0
    public var date = ""
    public var isRest = false
    public init() {}
}
public struct SessionTaskOption: Equatable, Sendable {
    public var taskID = -1
    public var title = ""
    public init() {}
}
public enum SessionTaskChange: Equatable, Sendable { case none, selected(Int) }
// nil 是未改；.none 明确清空任务，时间传带毫秒与时区的 ISO 串。
public struct SessionChanges: Equatable, Sendable {
    public var startTime: String?
    public var durationSeconds: Int?
    public var task: SessionTaskChange?
    public var isRest: Bool?
    public init() {}
}
@MainActor public protocol FocusHistoryBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var lastError: String { get }
    func monthSessions(year: Int, month: Int) throws -> [SessionValue]
    func daySessions(date: String) throws -> [SessionValue]
    func dayTimeline(date: String) throws -> [SessionValue]
    func dayTotalDuration(date: String) throws -> Int
    func invalidSessionCount() throws -> Int
    func taskOptions(date: String) throws -> [SessionTaskOption]
    func bandForMinutes(_ minutes: Double) -> Int
    func formatDuration(seconds: Int) -> String
    func cleanupInvalidSessions() throws -> Int
    func addManualSession(taskID: Int, startTime: String, durationMinutes: Int) throws -> Int
    func updateSession(id: Int, changes: SessionChanges) throws
    func updateRestSession(id: Int, changes: SessionChanges) throws
}
