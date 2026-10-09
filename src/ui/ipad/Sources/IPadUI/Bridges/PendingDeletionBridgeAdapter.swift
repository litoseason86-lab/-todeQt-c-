import IPadCore
import PTBridge

@MainActor final class PendingDeletionBridgeAdapter: PendingDeletionBridgeProtocol {
    var onChanged: (() -> Void)?
    var onRetired: (() -> Void)?
    var onCommitFailed: ((String) -> Void)?
    private let bridge = PTPendingDeletionBridge()
    init() {
        // 回调遵循 Qt 主线程上下文约束；弱引用使适配器可以随外壳释放。
        bridge.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        bridge.onRetired = { [weak self] in MainActor.assumeIsolated { self?.onRetired?() } }
        bridge.onCommitFailed = { [weak self] title in MainActor.assumeIsolated { self?.onCommitFailed?(title) } }
    }
    var state: PendingDeletionState {
        var value = PendingDeletionState()
        value.active = bridge.active; value.taskID = bridge.taskId; value.sessionID = bridge.sessionId
        value.sessionIsRest = bridge.sessionIsRest; value.title = bridge.title
        return value
    }
    func requestTask(id: Int, title: String) throws { try bridge.requestTask(id, title: title) }
    func requestSession(id: Int, title: String, isRest: Bool) throws { try bridge.requestSession(id, title: title, isRest: isRest) }
    func commit() throws { try bridge.commit() }
    func cancel() { bridge.cancel() }
}
