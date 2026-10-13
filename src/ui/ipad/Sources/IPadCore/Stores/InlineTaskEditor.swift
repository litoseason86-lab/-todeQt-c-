import Foundation
import Observation

// 行内编辑（对齐提醒事项：点任务行就地改标题、备注）。全应用同一时间只编辑一行，所以只有一个实例，
// 放在 CoreBridges 里给各页的任务行共用。编辑期间持有交互令牌：列表刷新暂缓，结束时补读一次，
// 改动表只交改过的字段（与详情表单同一口径），弹开期间另一台改了别的字段不会被盖掉。
@MainActor @Observable public final class InlineTaskEditor {
    public private(set) var taskID = -1
    public var title = ""
    public var notes = ""
    // 一次性的聚焦请求：开始编辑时置位，行视图聚焦标题框后清掉；放在 Store 里，行被重建也不会丢。
    public private(set) var focusRequested = false
    @ObservationIgnored private let tasks: any TaskBridgeProtocol
    @ObservationIgnored private let interactions: any InteractionBridgeProtocol
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private var token: InteractionToken?
    @ObservationIgnored private var baseline: TaskValue?

    public init(tasks: any TaskBridgeProtocol, interactions: any InteractionBridgeProtocol, shell: ShellStore) {
        self.tasks = tasks; self.interactions = interactions; self.shell = shell
    }
    public var isEditing: Bool { taskID > 0 }
    public func isEditing(_ id: Int) -> Bool { taskID == id }

    // 开始编辑某一行；正在编辑别的行先把那一行保存掉。基线取令牌里的最新快照，不用列表里可能过期的那份。
    @discardableResult public func begin(id: Int) -> Bool {
        if taskID == id { focusRequested = true; return true }
        finish()
        guard shell?.operationBlocksUI != true else { return false }
        do {
            let registration = try interactions.beginEdit(id: id, source: "ipad.task.inline")
            guard let latest = registration.task, latest.id == id else {
                registration.end(); shell?.showToast("任务信息已变化，请重试"); return false
            }
            token = registration; baseline = latest
            title = latest.title; notes = latest.notes
            taskID = id; focusRequested = true
            return true
        } catch { shell?.showToast(error.localizedDescription); return false }
    }
    public func acknowledgeFocus() { focusRequested = false }

    // 结束编辑并保存改过的字段。标题清空不算改（提醒事项清空标题后离开会恢复原标题），备注可以清空。
    // 保存失败也结束编辑，原因用提示条说；返回值表示有没有写成功（没改动算成功）。
    @discardableResult public func finish() -> Bool {
        guard let baseline, isEditing else { return true }
        var changes = TaskChanges()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty && trimmedTitle != baseline.title { changes.title = trimmedTitle }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes != baseline.notes { changes.notes = trimmedNotes }
        // 先释放令牌再写：写入发出的刷新通知要能直接生效，不必再等一轮补读。
        release()
        guard changes != TaskChanges(), shell?.operationBlocksUI != true else { return true }
        do { try tasks.update(id: baseline.id, changes: changes); return true }
        catch { shell?.showToast(error.localizedDescription); return false }
    }
    // 放弃这次编辑（Esc 不走这里：提醒事项按 Esc 也保留已输入的文字）；任务被删或页面拆掉时用。
    public func cancel() { release() }

    private func release() {
        taskID = -1; baseline = nil; focusRequested = false
        let registration = token; token = nil; registration?.end()
    }
}
