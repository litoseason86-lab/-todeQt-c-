import Foundation
import IPadCore

@MainActor final class PendingDeletionBridgeFake: PendingDeletionBridgeProtocol {
    var onChanged: (() -> Void)?
    var onRetired: (() -> Void)?
    var onCommitFailed: ((String) -> Void)?
    var state = PendingDeletionState()
    var error: Error?
    var commitError: Error?
    var calls: [(name: String, id: Int, title: String, isRest: Bool)] = []
    var automaticCommitSuspensions: [Bool] = []
    func requestTask(id: Int, title: String) throws {
        calls.append(("requestTask", id, title, false)); if let error { throw error }
        // 真实 PendingDeletion 的新请求先提交旧槽，不能让旧提示的退场回调提交新槽。
        if state.active { try commit() }
        state.active = true; state.taskID = id; state.sessionID = -1; state.title = title; onChanged?()
    }
    func requestSession(id: Int, title: String, isRest: Bool) throws {
        calls.append(("requestSession", id, title, isRest)); if let error { throw error }
        if state.active { try commit() }
        state.active = true; state.taskID = -1; state.sessionID = id; state.sessionIsRest = isRest; state.title = title; onChanged?()
    }
    func commit() throws {
        calls.append(("commit", -1, "", false)); guard state.active else { return }
        let title = state.title; onRetired?(); state = PendingDeletionState(); onChanged?()
        if let commitError { onCommitFailed?(title); throw commitError }
    }
    func cancel() { calls.append(("cancel", -1, "", false)); state = PendingDeletionState(); onChanged?() }
    func setAutomaticCommitSuspended(_ suspended: Bool) { automaticCommitSuspensions.append(suspended) }
}
