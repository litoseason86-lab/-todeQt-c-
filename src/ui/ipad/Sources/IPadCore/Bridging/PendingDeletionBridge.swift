import Foundation

public struct PendingDeletionState: Equatable, Sendable {
    public var active = false
    public var taskID = -1
    public var sessionID = -1
    public var sessionIsRest = false
    public var title = ""
    public var generation: Int64 = 0
    public init() {}
}
@MainActor public protocol PendingDeletionBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onRetired: (() -> Void)? { get set }
    var onCommitFailed: ((String, String) -> Void)? { get set }
    var state: PendingDeletionState { get }
    func requestTask(id: Int, title: String) throws
    func requestSession(id: Int, title: String, isRest: Bool) throws
    func commit() throws
    func commit(generation: Int64) throws
    func cancel()
    func cancel(generation: Int64)
    func setAutomaticCommitSuspended(_ suspended: Bool)
}
public extension PendingDeletionBridgeProtocol {
    func commit(generation: Int64) throws {
        guard state.active, state.generation == generation else { return }
        try commit()
    }
    func cancel(generation: Int64) {
        guard state.active, state.generation == generation else { return }
        cancel()
    }
}
