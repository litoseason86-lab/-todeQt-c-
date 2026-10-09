import Foundation
import Observation

@MainActor @Observable public final class TaskEditorStore {
    public var title = ""
    public var date = ""
    public var estimatedMinutes = 0
    public var notes = ""
    public var completionNote = ""
    public var categoryID: Int {
        get { categories.selectedID }
        set { categories.select(id: newValue) }
    }
    public private(set) var initialTask: TaskValue?
    public private(set) var active = false
    public private(set) var errorMessage = ""
    public let categories: TaskCategoryStore
    @ObservationIgnored private let tasks: any TaskBridgeProtocol
    @ObservationIgnored private let interactions: any InteractionBridgeProtocol
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private var token: InteractionToken?
    @ObservationIgnored private var initialCategoryID = -1

    public init(tasks: any TaskBridgeProtocol, interactions: any InteractionBridgeProtocol,
                categories: any CategoryBridgeProtocol, shell: ShellStore) {
        self.tasks = tasks; self.interactions = interactions; self.shell = shell
        self.categories = TaskCategoryStore(bridge: categories)
    }
    @discardableResult public func begin(id: Int) -> Bool {
        guard !active, shell?.snapshot.operationBlocksUI == false else { return false }
        do {
            let registration = try interactions.beginEdit(id: id, source: "ipad.task.detail")
            guard let latest = registration.task, latest.id == id else {
                registration.end(); errorMessage = "任务信息已变化，请重试"; shell?.showToast(errorMessage); return false
            }
            // 令牌中的最新快照是本次改动表基线，不能用列表打开前缓存的旧任务。
            token = registration; initialTask = latest
            title = latest.title; date = latest.date; estimatedMinutes = latest.estimatedMinutes
            notes = latest.notes; completionNote = latest.completionNote
            categories.open(selectedID: latest.categoryID)
            // 对照 Mac 的 openedValues：已缺失的科目以打开时实际选择为基线，不能被当成用户改成未分类。
            initialCategoryID = categories.selectedID; active = true; errorMessage = ""
            return true
        } catch { errorMessage = error.localizedDescription; shell?.showToast(errorMessage); return false }
    }
    public var changes: TaskChanges {
        guard let initialTask else { return TaskChanges() }
        // nil 表示没改；显式空串、零分钟和 .none 才表示清空，避免覆盖同步来的其它字段。
        var result = TaskChanges()
        if title != initialTask.title { result.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if date != initialTask.date { result.date = date }
        if categoryID != initialCategoryID { result.category = categoryID > 0 ? .selected(categoryID) : TaskCategoryChange.none }
        if estimatedMinutes != initialTask.estimatedMinutes { result.estimatedMinutes = estimatedMinutes }
        if notes != initialTask.notes { result.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
        if initialTask.completed && completionNote != initialTask.completionNote { result.completionNote = completionNote.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result
    }
    @discardableResult public func save() -> Bool {
        guard active, let initialTask, shell?.snapshot.operationBlocksUI == false else { return false }
        do {
            let changes = changes
            if changes != TaskChanges() { try tasks.update(id: initialTask.id, changes: changes) }
            cancel(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    public func cancel() {
        // 写入成功、用户取消和离开页面都明确结束登记；意外释放还有桥接 owner 析构兜底。
        categories.close(); active = false
        let registration = token; token = nil; registration?.end()
    }
}
