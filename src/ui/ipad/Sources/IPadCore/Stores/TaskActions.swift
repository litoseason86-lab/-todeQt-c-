import Foundation
import Observation

public enum TaskCompletionFocusOutcome: Equatable, Sendable {
    case none, ended(discarded: Bool), failed, needsConfirmation
}
@MainActor public protocol FocusFlowHook: AnyObject {
    func taskCompleted(taskId: Int) -> TaskCompletionFocusOutcome
    func openTask(taskId: Int, title: String)
}
@MainActor @Observable public final class TaskActions {
    @ObservationIgnored public weak var focusHook: (any FocusFlowHook)?
    public let pendingDeletion: PendingDeletionStore
    @ObservationIgnored private let tasks: any TaskBridgeProtocol
    @ObservationIgnored private weak var shell: ShellStore?
    public init(tasks: any TaskBridgeProtocol, pendingDeletion: PendingDeletionStore, shell: ShellStore) {
        self.tasks = tasks; self.pendingDeletion = pendingDeletion; self.shell = shell
    }
    @discardableResult public func complete(id: Int, title: String, note: String? = nil) -> Bool {
        guard shell?.snapshot.operationBlocksUI != true else { return false }
        do {
            if let note { try tasks.complete(id: id, note: note) }
            else { try tasks.setCompleted(id: id, completed: true) }
        } catch { shell?.showToast(error.localizedDescription); return false }
        // 完成成功后才通知专注流程；提示严格沿用 MainWindow，撤销只取消任务完成态。
        var message = "已完成「\(title)」"
        switch focusHook?.taskCompleted(taskId: id) ?? .none {
        case .none: break
        case .ended(let discarded): message += discarded ? "，专注不足 3 分钟，未计入记录" : "，专注已结束"
        case .failed: message += "，但结束专注失败，计时仍在继续"
        case .needsConfirmation: shell?.select(.focus)
        }
        shell?.showToast(message, actionTitle: "撤销", action: { [weak self] in _ = self?.uncomplete(id: id) })
        return true
    }
    @discardableResult public func uncomplete(id: Int) -> Bool {
        guard shell?.snapshot.operationBlocksUI != true else { return false }
        do { try tasks.setCompleted(id: id, completed: false); return true }
        catch { shell?.showToast(error.localizedDescription); return false }
    }
    @discardableResult public func delete(id: Int, title: String) -> Bool { pendingDeletion.requestTask(id: id, title: title) }
    public func openFocus(id: Int, title: String) {
        guard shell?.snapshot.operationBlocksUI != true else { return }
        shell?.select(.focus); focusHook?.openTask(taskId: id, title: title)
    }
}
