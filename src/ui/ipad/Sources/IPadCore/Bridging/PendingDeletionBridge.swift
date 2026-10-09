import Foundation

public struct PendingDeletionState: Equatable, Sendable {
    public var active = false
    public var taskID = -1
    public var sessionID = -1
    public var sessionIsRest = false
    public var title = ""
    public init() {}
}
@MainActor public protocol PendingDeletionBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onRetired: (() -> Void)? { get set }
    var onCommitFailed: ((String) -> Void)? { get set }
    var state: PendingDeletionState { get }
    func requestTask(id: Int, title: String) throws
    func requestSession(id: Int, title: String, isRest: Bool) throws
    func commit() throws
    func cancel()
}
