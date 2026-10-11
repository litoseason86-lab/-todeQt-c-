import Foundation
import Observation

public enum GapFormIntent: Identifiable, Equatable {
    case add, edit(GapValue), schedule(GapValue), resolve(GapValue)
    public var id: String {
        switch self { case .add: "add"; case .edit(let g): "edit\(g.id)"; case .schedule(let g): "date\(g.id)"; case .resolve(let g): "resolve\(g.id)" }
    }
    public var gap: GapValue? {
        switch self { case .add: nil; case .edit(let g), .schedule(let g), .resolve(let g): g }
    }
}

@MainActor @Observable public final class GapStore {
    public private(set) var detailPresented = false
    public private(set) var form: GapFormIntent?
    public func select(_ id: Int) {
        guard items.contains(where: { $0.id == id }) else { return }
        pendingRevealID = nil
        selectedID = id; detailPresented = true
    }
    public func closeDetail() { detailPresented = false }
    // 从全局搜索跳到某条：只改状态筛选不够，页内旧搜索词会让它不在结果里，refresh 随即清掉选中；
    // 所以先清搜索词、筛选切到它所在的一类（已解决 2，其余归未解决 -2），重读后再选中并推入详情。
    // 目标记成待定，等某次读取成功才落到选中：这次读取失败时先清掉旧选中（不把另一条当成这次的结果），
    // 之后重试或页面激活读到了再打开它；期间用户自己选了别的条目（select）就作废。
    @ObservationIgnored private var pendingRevealID: Int?
    public func reveal(_ gap: GapValue) {
        search = ""
        statusFilter = gap.status == 2 ? 2 : -2
        pendingRevealID = gap.id
        selectedID = nil; detailPresented = false
        refresh()
    }
    public func requestForm(_ intent: GapFormIntent) {
        if case .add = intent { form = .add; return }
        guard let id = intent.gap?.id, let current = items.first(where: { $0.id == id }) else { return }
        // 显式表单保留打开时的值；换选择或远端刷新都不能改写正在编辑的记录身份。
        switch intent {
        case .add: form = .add
        case .edit: form = .edit(current)
        case .schedule: form = .schedule(current)
        case .resolve: form = .resolve(current)
        }
    }
    public func dismissForm() { form = nil }
    public private(set) var items: [GapValue] = []
    public var selectedID: Int?
    public private(set) var categories: [CategoryValue] = []
    public var statusFilter = -2 { didSet { preferences?.set(statusFilter, forKey: "ipadui.knowledgeGap.status") } }
    public var search = ""
    public private(set) var errorMessage = ""
    public private(set) var pendingDelete: GapValue?
    @ObservationIgnored private let bridge: any KnowledgeGapBridging
    @ObservationIgnored private let taskBridge: (any TaskBridgeProtocol)?
    @ObservationIgnored private let categoryBridge: (any CategoryBridgeProtocol)?
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private weak var shell: ShellStore?
    private var active = false
    private var reading = false
    public init(bridge: any KnowledgeGapBridging, logicalDay: any LogicalDayBridgeProtocol, shell: ShellStore? = nil, categories: (any CategoryBridgeProtocol)? = nil, preferences: UserDefaults? = nil, tasks: (any TaskBridgeProtocol)? = nil) {
        self.bridge = bridge; self.logicalDay = logicalDay; self.shell = shell; categoryBridge = categories; self.preferences = preferences; taskBridge = tasks
        if let stored = preferences?.object(forKey: "ipadui.knowledgeGap.status") as? Int, [-2, 2].contains(stored) { statusFilter = stored }
        // 信号来自同一个 C++ 服务；后台失败只在当前页展示，重新进入时重读。
        // 每个 Store 独占订阅适配器；同一服务的信号由各实例分别接收，避免串接顺序影响刷新。
        logicalDay.onChanged = { [weak self] in self?.logicalDayChanged() }
        categories?.onChanged = { [weak self] in self?.relatedDataChanged() }
        tasks?.onChanged = { [weak self] in self?.relatedDataChanged() }
        bridge.onChanged = { [weak self] in if self?.active == true { self?.refresh() } }
        bridge.onFailure = { [weak self] message in if self?.active == true { self?.errorMessage = message } }
    }
    public func setActive(_ value: Bool) { active = value; if value { refresh() } }
    public func logicalDayChanged() { if active { refresh() } }
    public func relatedDataChanged() { if active { refresh() } }
    public func gaps(status: Int) -> [GapValue] { items.filter { $0.status == status } }
    public var logicalToday: String { logicalDay.today }
    public var selected: GapValue? { items.first { $0.id == selectedID } }
    public func refresh() {
        guard !reading else { return }; reading = true; defer { reading = false }
        do {
            let rows = try bridge.gaps(status: statusFilter, categoryID: 0, search: search)
            let subjects = try categoryBridge?.allCategories() ?? []
            items = rows; categories = subjects; errorMessage = ""
            if let target = pendingRevealID {
                // 目标已被删除或不在这一类里：不再等，保持无选中。
                pendingRevealID = nil
                if rows.contains(where: { $0.id == target }) { selectedID = target; detailPresented = true }
            } else if let selectedID, !rows.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil; detailPresented = false
            }
        }
        catch { errorMessage = error.localizedDescription }
    }
    @discardableResult private func perform(_ action: () throws -> Void) -> Bool {
        do { try action(); errorMessage = ""; refresh(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult public func add(title: String, categoryID: Int, detail: String, priority: Int, dueDate: String) -> Bool {
        perform { _ = try bridge.add(title: title, categoryID: categoryID, detail: detail, priority: priority, dueDate: dueDate, sourceTaskID: -1) }
    }
    @discardableResult public func update(opened: GapValue, edited: GapValue) -> Bool {
        let changes = GapChanges(title: edited.title == opened.title ? nil : edited.title,
            categoryID: edited.categoryID == opened.categoryID ? nil : edited.categoryID,
            detail: edited.detail == opened.detail ? nil : edited.detail,
            priority: edited.priority == opened.priority ? nil : edited.priority,
            dueDate: edited.dueDate == opened.dueDate ? nil : edited.dueDate)
        guard !changes.isEmpty else { return true }
        return perform { try bridge.update(id: opened.id, changes: changes) }
    }
    @discardableResult public func convert(_ gap: GapValue) -> Bool {
        let ok = perform { _ = try bridge.convert(id: gap.id, date: logicalDay.today) }
        if ok { shell?.showToast("已加到今天「\(gap.title)」") }; return ok
    }
    @discardableResult public func schedule(_ gap: GapValue, date: String) -> Bool { perform { try bridge.schedule(id: gap.id, date: date) } }
    @discardableResult public func schedule(ids: [Int], date: String) -> Bool { perform { try bridge.schedule(ids: ids, date: date) } }
    @discardableResult public func resolve(_ gap: GapValue, resolution: String) -> Bool { perform { try bridge.resolve(id: gap.id, resolution: resolution) } }
    @discardableResult public func reopen(_ gap: GapValue) -> Bool { perform { try bridge.reopen(id: gap.id) } }
    public func requestDelete(_ gap: GapValue) { pendingDelete = gap }
    public func cancelDelete() { pendingDelete = nil }
    public func confirmDelete() { guard let gap = pendingDelete else { return }; pendingDelete = nil; _ = perform { try bridge.delete(id: gap.id) } }
}
