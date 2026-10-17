import Foundation
import Observation

@MainActor @Observable public final class PendingDeletionStore {
    public private(set) var state = PendingDeletionState()
    public var pendingTaskID: Int { state.taskID }
    public var pendingSessionID: Int { state.sessionID }
    @ObservationIgnored private let bridge: any PendingDeletionBridgeProtocol
    @ObservationIgnored private let tasks: any TaskBridgeProtocol
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private var toastID: UUID?
    @ObservationIgnored private var commitFailureSerial: UInt64 = 0

    public init(bridge: any PendingDeletionBridgeProtocol, tasks: any TaskBridgeProtocol, shell: ShellStore) {
        self.bridge = bridge; self.tasks = tasks; self.shell = shell
        // C++ 维护单槽与计时，Swift 只投影隐藏行状态并连接外壳提示。
        bridge.onChanged = { [weak self] in self?.refresh() }
        bridge.onRetired = { [weak self] in self?.retireOwnToast() }
        bridge.onCommitFailed = { [weak self] title in
            guard let self else { return }
            self.commitFailureSerial &+= 1
            self.shell?.showToast("删除「\(title)」失败，请重试")
        }
        refresh()
    }
    private func refresh() { state = bridge.state }
    private func perform(_ action: () throws -> Void) -> Bool {
        let failuresBefore = commitFailureSerial
        do { try action(); return true }
        catch {
            // 提交旧槽失败会先同步回调并提示原标题；参数或登记拒绝没有该回调，才显示本次抛错原因。
            if commitFailureSerial == failuresBefore { shell?.showToast(error.localizedDescription) }
            return false
        }
    }
    private func retireOwnToast() {
        let id = toastID; toastID = nil
        guard let id, shell?.toast?.id == id else { return }
        shell?.retireToast()
    }
    private func showUndo(_ message: String) {
        shell?.showToast(message, actionTitle: "撤销", action: { [weak self] in
            self?.toastID = nil; self?.bridge.cancel()
        }, onRetired: { [weak self] in
            // 退场信号主动收起自己那条时已经清除 id，不再次进入 C++ 提交。
            guard self?.toastID != nil else { return }
            _ = self?.commitIfNeeded()
        })
        toastID = shell?.toast?.id
    }
    @discardableResult public func requestTask(id: Int, title: String) -> Bool {
        guard shell?.snapshot.operationBlocksUI != true else { return false }
        guard perform({ try bridge.requestTask(id: id, title: title) }) else { return false }
        let message = tasks.isRoutineGenerated(id: id) ? "已删除今天的例行任务「\(title)」" : "已删除「\(title)」"
        showUndo(message); return true
    }
    @discardableResult public func requestSession(id: Int, title: String = "", isRest: Bool) -> Bool {
        guard shell?.snapshot.operationBlocksUI != true else { return false }
        let title = title.isEmpty ? "专注记录" : title
        guard perform({ try bridge.requestSession(id: id, title: title, isRest: isRest) }) else { return false }
        showUndo("已删除\(isRest ? "休息" : "专注")记录「\(title)」"); return true
    }
    @discardableResult public func commitIfNeeded() -> Bool {
        guard bridge.state.active else { return true }
        return perform { try bridge.commit() }
    }
    public func setAutomaticCommitSuspended(_ suspended: Bool) {
        bridge.setAutomaticCommitSuspended(suspended)
    }
}
