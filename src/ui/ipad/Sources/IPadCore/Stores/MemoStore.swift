import Foundation
import Observation

@MainActor @Observable public final class MemoStore {
    public private(set) var items: [MemoValue] = []
    public private(set) var categories: [CategoryValue] = []
    public private(set) var selectedID: Int?
    public private(set) var filterCategoryID = -1 { didSet { preferences?.set(filterCategoryID, forKey: "ipadui.memo.category") } }
    public private(set) var editorTitle = ""
    public private(set) var editorBody = ""
    public private(set) var editorCategoryID = 0
    public private(set) var updatedAt = ""
    public private(set) var errorMessage = ""
    public private(set) var errorFromRead = false
    public private(set) var readFailure = ""
    public private(set) var remoteDeleted = false
    public private(set) var pendingDelete: MemoValue?
    public private(set) var draggingID: Int?
    public private(set) var displayNow = Date()
    public private(set) var titleFocusGeneration = 0
    public private(set) var titleComposing = false
    public private(set) var bodyComposing = false
    private var baseline = MemoValue()
    private var deletedNeighborIndex = 0
    private var active = false
    private var saving = false
    private var reading = false
    @ObservationIgnored private let bridge: any MemoBridging
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private let categoryBridge: any CategoryBridgeProtocol
    @ObservationIgnored private weak var shell: ShellStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var flusher: UUID?
    public init(bridge: any MemoBridging, categories: any CategoryBridgeProtocol, shell: ShellStore? = nil, preferences: UserDefaults? = nil) {
        self.bridge = bridge; categoryBridge = categories; self.shell = shell; self.preferences = preferences
        if let stored = preferences?.object(forKey: "ipadui.memo.category") as? Int { filterCategoryID = stored }
        // 本计划保留 Swift 编辑会话；服务变化只在活跃页读取，保存期间的同步信号不重入编辑器。
        bridge.onChanged = { [weak self] in if self?.active == true { self?.refresh() } }
        bridge.onFailure = { [weak self] message in if self?.active == true { self?.setError(message) } }
    }
    public var dirty: Bool { editorTitle != baseline.title || editorBody != baseline.body || editorCategoryID != baseline.categoryID }
    public var isComposing: Bool { titleComposing || bodyComposing }
    public var visibleItems: [MemoValue] { items.filter { filterCategoryID == -1 || $0.categoryID == filterCategoryID } }
    public func rows(categoryID: Int) -> [MemoValue] { visibleItems.filter { $0.categoryID == categoryID } }
    public var usedCategories: [CategoryValue] { categories.filter { category in items.contains { $0.categoryID == category.id } } }
    public var unusedCategories: [CategoryValue] { categories.filter { category in !items.contains { $0.categoryID == category.id } } }
    public var categoryFilters: [Int] { [-1] + usedCategories.map(\.id) + (items.contains { $0.categoryID == 0 } ? [0] : []) }
    // 默认科目色属于新建表单状态，沿用 Mac NewCategoryPrompt 的暖色阶与顺位取色。
    public var newCategoryColor: String {
        let colors = ["#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c", "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"]
        return colors[categories.count % colors.count]
    }
    public var moveCategoryIDs: [Int] { [0] + usedCategories.map(\.id) }
    public func categoryName(_ id: Int) -> String { categories.first { $0.id == id }?.name ?? "未分类" }
    public func setActive(_ value: Bool) {
        active = value
        if value { registerFlusher(); refresh() }
        else { draggingID = nil; _ = flush(); if !dirty && !isComposing { unregisterFlusher() } }
    }
    private func registerFlusher() {
        guard flusher == nil else { return }
        // 即使切页保存失败，后台仍需保存这份草稿；闭包弱引用，不把编辑会话保留成环。
        flusher = shell?.registerEditFlusher { [weak self] in _ = self?.flush() }
    }
    private func unregisterFlusher() { if let flusher { shell?.unregisterEditFlusher(flusher) }; flusher = nil }
    public func relatedDataChanged() { if active { refresh() } }
    public func refresh(now: Date = Date()) {
        guard !saving && !reading else { return }; reading = true; defer { reading = false }
        displayNow = now; draggingID = nil
        let oldIndex = max(0, visibleItems.firstIndex { $0.id == selectedID } ?? 0)
        let oldGlobal = max(0, items.firstIndex { $0.id == selectedID } ?? 0)
        do {
            // 两次读取算一次展示快照；科目失败不能当成科目被删，否则另存草稿会丢分类。
            let values = try bridge.memos(); let subjects = try categoryBridge.allCategories()
            items = values; categories = subjects; readFailure = ""
            if errorFromRead { setError("") }
            if let id = pendingDelete?.id, !items.contains(where: { $0.id == id }) { pendingDelete = nil }
            var neighbor = oldIndex
            if !categoryFilters.contains(filterCategoryID) { filterCategoryID = -1; neighbor = oldGlobal }
            if let current = items.first(where: { $0.id == selectedID }) {
                if !dirty && !isComposing { load(current, clearError: false) }
            } else if selectedID != nil && (dirty || isComposing) {
                remoteDeleted = true; deletedNeighborIndex = neighbor
                setError("这条备忘录已在另一台设备删除。")
                if editorCategoryID != 0 && !categories.contains(where: { $0.id == editorCategoryID }) {
                    editorCategoryID = 0; baseline.categoryID = 0
                }
            } else { selectNeighbor(neighbor, clearError: false) }
        } catch { readFailure = error.localizedDescription; setError(readFailure, fromRead: true) }
    }
    private func setError(_ message: String, fromRead: Bool = false) { errorMessage = message; errorFromRead = fromRead }
    private func load(_ value: MemoValue, clearError: Bool = true) {
        saveTask?.cancel(); selectedID = value.id > 0 ? value.id : nil
        baseline = value; editorTitle = value.title; editorBody = value.body; editorCategoryID = value.categoryID; updatedAt = value.updatedAt
        remoteDeleted = false
        if clearError { setError("") }
    }
    private func selectNeighbor(_ index: Int, clearError: Bool = true) {
        let rows = visibleItems
        if rows.isEmpty { load(MemoValue(), clearError: clearError) }
        else { load(rows[min(max(0, index), rows.count - 1)], clearError: clearError) }
    }
    public func editTitle(_ value: String) { guard selectedID != nil else { return }; editorTitle = value; scheduleSave() }
    public func editBody(_ value: String) { guard selectedID != nil else { return }; editorBody = value; scheduleSave() }
    public func setTitleComposing(_ value: Bool) { titleComposing = value; compositionChanged() }
    public func setBodyComposing(_ value: Bool) { bodyComposing = value; compositionChanged() }
    private func compositionChanged() { if isComposing { saveTask?.cancel() } else { scheduleSave() } }
    private func scheduleSave() {
        saveTask?.cancel(); guard active && !isComposing else { return }
        // 一秒防抖只保存上屏后的最后一版；取消不提交输入法组合，后台 flush 同步执行。
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            _ = self?.flush()
        }
    }
    private func validateText() -> Bool {
        let excess = MemoFormat.characterCount(editorBody) - 10000
        if excess > 0 { setError("正文超出 \(excess) 字，没有保存。"); return false }
        if MemoFormat.characterCount(editorTitle) > 60 { setError("标题不能超过 60 字，没有保存。"); return false }
        return true
    }
    @discardableResult public func flush() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard !isComposing else { return false }
        guard selectedID != nil && dirty else { return true }
        guard validateText(), !remoteDeleted, let id = selectedID else { return false }
        let changes = MemoChanges(title: editorTitle == baseline.title ? nil : editorTitle,
            body: editorBody == baseline.body ? nil : editorBody,
            categoryID: editorCategoryID == baseline.categoryID ? nil : editorCategoryID)
        saving = true
        do {
            try bridge.update(id: id, changes: changes)
            baseline.title = editorTitle; baseline.body = editorBody; baseline.categoryID = editorCategoryID
            saving = false; setError(""); refresh(); return true
        } catch { saving = false; setError(error.localizedDescription); return false }
    }
    @discardableResult public func selectMemo(_ id: Int) -> Bool {
        if id == selectedID { return true }
        guard items.contains(where: { $0.id == id }), flush(), let value = items.first(where: { $0.id == id }) else { return false }
        load(value); return true
    }
    @discardableResult public func selectFilter(_ id: Int) -> Bool {
        guard flush() else { return false }; filterCategoryID = id; load(MemoValue()); refresh(); return true
    }
    @discardableResult public func leaveDetail() -> Bool { flush() }
    @discardableResult public func createNew(categoryID: Int? = nil) -> Bool {
        guard flush() else { return false }; let category = categoryID ?? max(0, filterCategoryID)
        saving = true
        do {
            let id = try bridge.create(title: "", body: "", categoryID: category)
            if filterCategoryID >= 0 && filterCategoryID != category { filterCategoryID = -1 }
            // 先装空编辑会话再重读，重读失败也不能把上一条正文写到新身份。
            var value = MemoValue(); value.id = id; value.categoryID = category; load(value)
            titleFocusGeneration += 1; saving = false; refresh(); return true
        } catch { saving = false; setError(error.localizedDescription); return false }
    }
    @discardableResult public func createCategory(name: String, color: String) -> Bool {
        guard flush() else { return false }
        do { let id = try categoryBridge.add(name: name, color: color); return createNew(categoryID: id) }
        catch { setError(error.localizedDescription); return false }
    }
    @discardableResult public func moveCategory(id: Int, to category: Int) -> Bool {
        guard moveCategoryIDs.contains(category), selectMemo(id) else { return false }
        editorCategoryID = category; return flush()
    }
    public func requestDelete() {
        guard !remoteDeleted, let id = selectedID else { return }
        var value = MemoValue(); value.id = id; value.title = editorTitle; value.body = editorBody; pendingDelete = value
    }
    public func cancelDelete() { pendingDelete = nil }
    public func confirmDelete() {
        guard let value = pendingDelete else { return }; pendingDelete = nil
        saving = true
        do { try bridge.delete(id: value.id); saving = false; load(MemoValue()); refresh() }
        catch { saving = false; setError(error.localizedDescription) }
    }
    @discardableResult public func saveDeletedAsNew() -> Bool {
        guard remoteDeleted && !isComposing, validateText() else { return false }; saveTask?.cancel(); saving = true
        do {
            let id = try bridge.create(title: editorTitle, body: editorBody, categoryID: editorCategoryID)
            var value = MemoValue(); value.id = id; value.title = editorTitle; value.body = editorBody; value.categoryID = editorCategoryID
            load(value); saving = false; refresh(); return true
        } catch { saving = false; setError(error.localizedDescription); return false }
    }
    public func discardDeleted() { guard remoteDeleted else { return }; selectNeighbor(deletedNeighborIndex) }
    @discardableResult public func beginDrag(_ id: Int) -> Bool {
        guard flush(), items.contains(where: { $0.id == id }) else { return false }; draggingID = id; return true
    }
    @discardableResult public func drop(before targetID: Int) -> Bool {
        guard let id = draggingID else { return false }; draggingID = nil
        guard let source = items.first(where: { $0.id == id }), let target = items.first(where: { $0.id == targetID }), source.categoryID == target.categoryID else { return false }
        var ids = items.filter { $0.categoryID == source.categoryID }.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: targetID), from != to else { return false }
        ids.remove(at: from); ids.insert(id, at: to)
        do { try bridge.reorder(categoryID: source.categoryID, ids: ids); refresh(); return true }
        catch { setError(error.localizedDescription); return false }
    }
    public func cancelDrag() { draggingID = nil }
}
