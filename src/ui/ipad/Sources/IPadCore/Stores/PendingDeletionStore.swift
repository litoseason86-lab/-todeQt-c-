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
    @ObservationIgnored private var activeOperationToken: UUID?
    @ObservationIgnored private var commitFailureSerial: UInt64 = 0

    public init(bridge: any PendingDeletionBridgeProtocol, tasks: any TaskBridgeProtocol, shell: ShellStore) {
        self.bridge = bridge; self.tasks = tasks; self.shell = shell
        // C++ 维护单槽与计时，Swift 只投影隐藏行状态并连接外壳提示。
        bridge.onChanged = { [weak self] in self?.refresh() }
        bridge.onRetired = { [weak self] in self?.retireOwnToast() }
        bridge.onCommitFailed = { [weak self] title, reason in
            guard let self else { return }
            self.commitFailureSerial &+= 1
            self.shell?.showToast("删除「\(title)」失败：\(reason)")
        }
        refresh()
    }
    private func refresh() {
        let wasActive = state.active
        state = bridge.state
        // 底层待删槽经外部重置或取消退回空闲（仅发 changed 未发 retired）时，立即静默收起属于本槽的旧撤销条并作废旧令牌。
        if wasActive && !state.active && toastID != nil {
            retireOwnToast()
        }
    }
    public func invalidateForDatabaseChange() {
        activeOperationToken = nil
        toastID = nil
        refresh()
    }
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
        activeOperationToken = nil
        let id = toastID; toastID = nil
        guard let id, shell?.toast?.id == id else { return }
        shell?.retireToast()
    }
    private func showUndo(_ message: String) {
        // 每次撤销条同时绑定操作令牌、C++ 槽代次与数据库代次：换库或开启新删除前旧退场/撤销闭包均立即失效，绝不误伤新槽。
        let operationToken = UUID()
        let slotGeneration = bridge.state.generation
        let dbGeneration = shell?.databaseGeneration ?? 0
        activeOperationToken = operationToken
        shell?.showToast(message, actionTitle: "撤销", action: { [weak self] in
            guard let self, self.activeOperationToken == operationToken,
                  self.shell?.databaseGeneration == dbGeneration else { return }
            self.activeOperationToken = nil
            self.toastID = nil
            self.bridge.cancel(generation: slotGeneration)
        }, onRetired: { [weak self] in
            // 退场信号主动收起、换库失效或新操作替换时令牌已变更，绝不把旧退场错提交到新待删槽。
            guard let self, self.activeOperationToken == operationToken,
                  self.shell?.databaseGeneration == dbGeneration else { return }
            self.activeOperationToken = nil
            self.toastID = nil
            _ = self.commitGenerationIfNeeded(slotGeneration)
        })
        toastID = shell?.toast?.id
    }
    @discardableResult public func requestTask(id: Int, title: String) -> Bool {
        guard shell?.operationBlocksUI != true else { return false }
        guard perform({ try bridge.requestTask(id: id, title: title) }) else { return false }
        let message = tasks.isRoutineGenerated(id: id) ? "已删除今天的例行任务「\(title)」" : "已删除「\(title)」"
        showUndo(message); return true
    }
    @discardableResult public func requestSession(id: Int, title: String = "", isRest: Bool) -> Bool {
        guard shell?.operationBlocksUI != true else { return false }
        let title = title.isEmpty ? "专注记录" : title
        guard perform({ try bridge.requestSession(id: id, title: title, isRest: isRest) }) else { return false }
        showUndo("已删除\(isRest ? "休息" : "专注")记录「\(title)」"); return true
    }
    @discardableResult public func commitIfNeeded() -> Bool {
        guard bridge.state.active else { return true }
        return perform { try bridge.commit() }
    }
    @discardableResult private func commitGenerationIfNeeded(_ generation: Int64) -> Bool {
        guard bridge.state.active, bridge.state.generation == generation else { return true }
        return perform { try bridge.commit(generation: generation) }
    }
    public func setAutomaticCommitSuspended(_ suspended: Bool) {
        bridge.setAutomaticCommitSuspended(suspended)
    }
}
