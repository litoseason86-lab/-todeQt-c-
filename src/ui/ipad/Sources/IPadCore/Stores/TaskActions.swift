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
        catch {
            // 桥接已认领服务给出的失败原因；取消完成也要保留原文，不能再次退回通用重试提示。
            shell?.showToast(error.localizedDescription); return false
        }
    }
    @discardableResult public func delete(id: Int, title: String) -> Bool { pendingDeletion.requestTask(id: id, title: title) }

    // MARK: 多选批量
    // 整批一个事务（服务做）；成功后逐条通知专注流程——只有正在专注的那条会有结果，提示照它补一句。
    // 一条提示带撤销，撤销把这一批一起取消完成。
    @discardableResult public func complete(ids: [Int]) -> Bool {
        guard !ids.isEmpty, shell?.operationBlocksUI != true else { return false }
        do { try tasks.setCompleted(ids: ids, completed: true) }
        catch { shell?.showToast(error.localizedDescription); return false }
        var message = "已完成 \(ids.count) 项任务"
        for id in ids {
            switch focusHook?.taskCompleted(taskId: id) ?? .none {
            case .none: continue
            case .ended(let discarded): message += discarded ? "，专注不足 3 分钟，未计入记录" : "，专注已结束"
            case .failed: message += "，但结束专注失败，计时仍在继续"
            case .needsConfirmation: shell?.select(.focus)
            }
        }
        shell?.showToast(message, actionTitle: "撤销", action: { [weak self] in
            guard let self, self.shell?.operationBlocksUI != true else { return }
            do { try self.tasks.setCompleted(ids: ids, completed: false) }
            catch { self.shell?.showToast("撤销完成失败，请重试") }
        })
        return true
    }
    // 批量删除直接进废纸篓（服务一个事务），不走单条删除的撤销槽：撤销槽一次只能挂一条。
    // 提示给「查看」去废纸篓恢复，与 Mac 删除后可在废纸篓恢复的口径一致。
    @discardableResult public func delete(ids: [Int]) -> Bool {
        guard !ids.isEmpty, shell?.operationBlocksUI != true else { return false }
        do { try tasks.delete(ids: ids) }
        catch { shell?.showToast(error.localizedDescription); return false }
        shell?.showToast("已删除 \(ids.count) 项任务，可在废纸篓恢复", actionTitle: "查看", action: { [weak self] in
            self?.shell?.select(.trash)
        })
        return true
    }
    public func openFocus(id: Int, title: String) {
        guard shell?.snapshot.operationBlocksUI != true else { return }
        shell?.select(.focus); focusHook?.openTask(taskId: id, title: title)
    }
}
