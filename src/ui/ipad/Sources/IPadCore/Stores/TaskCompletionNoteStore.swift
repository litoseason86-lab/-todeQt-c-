import Foundation
import Observation

@MainActor @Observable public final class TaskCompletionNoteStore {
    public var note = ""
    public private(set) var task: TaskValue?
    public private(set) var active = false
    public private(set) var errorMessage = ""
    @ObservationIgnored private let interactions: any InteractionBridgeProtocol
    @ObservationIgnored private let actions: TaskActions
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private var token: InteractionToken?

    public init(interactions: any InteractionBridgeProtocol, actions: TaskActions, shell: ShellStore) {
        self.interactions = interactions; self.actions = actions; self.shell = shell
    }
    @discardableResult public func begin(id: Int) -> Bool {
        guard !active, shell?.snapshot.operationBlocksUI == false else { return false }
        do {
            let registration = try interactions.beginEdit(id: id, source: "ipad.task.completionNote")
            guard let latest = registration.task, latest.id == id else {
                registration.end(); errorMessage = "任务信息已变化，请重试"; shell?.showToast(errorMessage); return false
            }
            // 取消完成保留的旧记录需从最新任务预填；表单期间冻结列表，不能被同步刷新销毁。
            token = registration; task = latest; note = latest.completionNote; active = true; errorMessage = ""
            return true
        } catch { errorMessage = error.localizedDescription; shell?.showToast(errorMessage); return false }
    }
    @discardableResult public func save() -> Bool {
        guard active, let task, shell?.snapshot.operationBlocksUI == false else { return false }
        // 完成与记录原子写入、专注收尾、撤销提示一律经 TaskActions，不在表单另做一条路径。
        guard actions.complete(id: task.id, title: task.title, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = shell?.toast?.message ?? "任务完成失败，请重试"; return false
        }
        cancel(); return true
    }
    public func cancel() {
        active = false; let registration = token; token = nil; registration?.end()
    }
}
