import Foundation
import Observation

@MainActor @Observable public final class SettingsCategoryStore {
    public private(set) var values: [CategoryValue] = []
    public private(set) var errorMessage = ""
    public private(set) var editing = false
    public var name = ""
    public var color = "#d4a574"
    @ObservationIgnored private var opened: CategoryValue?
    @ObservationIgnored private let bridge: any CategoryBridgeProtocol
    @ObservationIgnored private var active = false
    @ObservationIgnored private var writing = false
    // 按次缓存每条科目的可删状态，reload 后失效，避免 SwiftUI 列表重绘时逐行同步查库。
    @ObservationIgnored private var deletableCache: [Int: Bool] = [:]

    // 科目颜色是用户数据，沿用 ColorPicker 的暖色阶；页面自身仍用语义色。
    public static let colors = ["#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c",
                                "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"]
    public init(bridge: any CategoryBridgeProtocol) {
        self.bridge = bridge
        bridge.onChanged = { [weak self] in if self?.active == true && self?.writing == false { self?.reload() } }
        bridge.onFailure = { [weak self] message in if self?.active == true { self?.errorMessage = message } }
    }
    public func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value { reload() } else { cancel() }
    }
    public func prepareForRestore() { cancel(); deletableCache.removeAll() }
    public func reload() {
        do { values = try bridge.allCategories(); deletableCache.removeAll(); errorMessage = "" }
        catch { errorMessage = error.localizedDescription }
    }
    public func beginNew() {
        opened = nil; name = ""; color = Self.colors[values.count % Self.colors.count]
        errorMessage = ""; editing = true
    }
    public func beginEdit(_ value: CategoryValue) {
        opened = value; name = value.name; color = value.color; errorMessage = ""; editing = true
    }
    public func cancel() { editing = false; opened = nil; errorMessage = "" }
    @discardableResult public func save() -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入科目名称"; return false }
        if let opened {
            // 只提交用户实际修改的字段；未改名时跳过重名检查，防止远端已改名并新建同名科目后阻塞本机仅改色。
            let changes = CategoryChanges(name: trimmed == opened.name ? nil : trimmed,
                                          color: color == opened.color ? nil : color)
            if changes.isEmpty { editing = false; self.opened = nil; errorMessage = ""; return true }
            if let newName = changes.name, bridge.nameExists(newName, excluding: opened.id) {
                errorMessage = "已存在同名科目"; return false
            }
            writing = true; defer { writing = false }
            do {
                try bridge.update(id: opened.id, changes: changes)
                editing = false; self.opened = nil; reload(); return true
            } catch { errorMessage = error.localizedDescription; return false }
        }
        guard !bridge.nameExists(trimmed, excluding: -1) else {
            errorMessage = "已存在同名科目"; return false
        }
        writing = true; defer { writing = false }
        do {
            _ = try bridge.add(name: trimmed, color: color)
            editing = false; self.opened = nil; reload(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    public func canDelete(_ value: CategoryValue) -> Bool {
        guard !value.isPreset else { return false }
        if let cached = deletableCache[value.id] { return cached }
        let allowed = bridge.canDelete(id: value.id)
        deletableCache[value.id] = allowed
        return allowed
    }
    @discardableResult public func delete(_ value: CategoryValue) -> Bool {
        // 能否删除以服务的删除结果为准；canDelete 只供按钮判断能力，给不出拒绝原因。
        writing = true; defer { writing = false }
        do { try bridge.delete(id: value.id); reload(); return true }
        catch {
            // 列表可能因另一台设备删除科目而过期；先刷新再写原因，避免 reload 成功清空本次错误。
            reload(); errorMessage = error.localizedDescription; return false
        }
    }
}

@MainActor @Observable public final class SettingsRoutineStore {
    public private(set) var values: [RoutineValue] = []
    public private(set) var categories: [CategoryValue] = []
    public private(set) var errorMessage = ""
    public private(set) var editing = false
    public private(set) var editingWeekdays = false
    public var title = ""
    public var categoryID = -1
    public var weekdays = 127
    @ObservationIgnored private var opened: RoutineValue?
    @ObservationIgnored private let bridge: any RoutineBridgeProtocol
    @ObservationIgnored private let categoryBridge: any CategoryBridgeProtocol
    @ObservationIgnored private var active = false
    @ObservationIgnored private var writing = false
    public init(bridge: any RoutineBridgeProtocol, categories: any CategoryBridgeProtocol) {
        self.bridge = bridge; self.categoryBridge = categories
        bridge.onChanged = { [weak self] in if self?.active == true && self?.writing == false { self?.reload() } }
        bridge.onFailure = { [weak self] message in if self?.active == true { self?.errorMessage = message } }
        categories.onChanged = { [weak self] in if self?.active == true { self?.reloadCategories() } }
    }
    public func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value { reload(); reloadCategories() } else { cancel() }
    }
    public func reload() {
        do { values = try bridge.routines(); errorMessage = "" }
        catch { errorMessage = error.localizedDescription }
    }
    public func reloadCategories() {
        do { categories = try categoryBridge.allCategories() }
        catch { errorMessage = error.localizedDescription }
    }
    public func beginNew() { opened = nil; title = ""; categoryID = -1; editing = true; errorMessage = "" }
    public func beginEdit(_ value: RoutineValue) {
        opened = value; title = value.title; categoryID = value.categoryID; editing = true; errorMessage = ""
    }
    public func beginWeekdays(_ value: RoutineValue) {
        opened = value; weekdays = RoutineWeekdaysFormat.normalize(value.weekdays); editingWeekdays = true; errorMessage = ""
    }
    public func cancel() { editing = false; editingWeekdays = false; opened = nil; errorMessage = "" }
    public func prepareForRestore() { cancel() }
    @discardableResult public func save() -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "例行任务标题不能为空"; return false }
        writing = true; defer { writing = false }
        do {
            if let opened {
                // 打开时的快照只用于挑选变化字段，未编辑的字段由服务保留最新同步值。
                let changes = RoutineChanges(title: title == opened.title ? nil : trimmed,
                                             categoryID: categoryID == opened.categoryID ? nil : categoryID)
                if !changes.isEmpty { try bridge.update(id: opened.id, changes: changes) }
            } else { try bridge.add(title: trimmed, categoryID: categoryID, weekdays: 127) }
            editing = false; opened = nil; reload(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult public func saveWeekdays() -> Bool {
        guard let opened else { return false }
        writing = true; defer { writing = false }
        do {
            try bridge.setWeekdays(id: opened.id, weekdays: weekdays)
            editingWeekdays = false; self.opened = nil; reload(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    public func setActive(_ value: RoutineValue, active: Bool) {
        writing = true; defer { writing = false }
        do { try bridge.setActive(id: value.id, active: active); reload() }
        catch { errorMessage = error.localizedDescription }
    }
    public func delete(_ value: RoutineValue) {
        writing = true; defer { writing = false }
        do { try bridge.delete(id: value.id); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
