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

    // 科目颜色是用户数据，沿用 ColorPicker 的暖色阶；页面自身仍用语义色。
    public static let colors = ["#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c",
                                "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"]
    public init(bridge: any CategoryBridgeProtocol) {
        self.bridge = bridge
        bridge.onChanged = { [weak self] in self?.reload() }
        bridge.onFailure = { [weak self] in self?.errorMessage = $0 }
        reload()
    }
    public func reload() {
        do { values = try bridge.allCategories(); errorMessage = "" }
        catch { errorMessage = error.localizedDescription }
    }
    public func beginNew() {
        opened = nil; name = ""; color = Self.colors[values.count % Self.colors.count]
        errorMessage = ""; editing = true
    }
    public func beginEdit(_ value: CategoryValue) {
        opened = value; name = value.name; color = value.color; errorMessage = ""; editing = true
    }
    public func cancel() { editing = false; opened = nil }
    @discardableResult public func save() -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入科目名称"; return false }
        guard !bridge.nameExists(trimmed, excluding: opened?.id ?? -1) else {
            errorMessage = "已存在同名科目"; return false
        }
        do {
            if let opened {
                if trimmed != opened.name || color != opened.color {
                    try bridge.update(id: opened.id, name: trimmed, color: color)
                }
            } else { _ = try bridge.add(name: trimmed, color: color) }
            editing = false; self.opened = nil; reload(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    public func canDelete(_ value: CategoryValue) -> Bool { !value.isPreset && bridge.canDelete(id: value.id) }
    @discardableResult public func delete(_ value: CategoryValue) -> Bool {
        guard canDelete(value) else { errorMessage = "此科目不能删除"; return false }
        do { try bridge.delete(id: value.id); reload(); return true }
        catch { errorMessage = error.localizedDescription; return false }
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
    public init(bridge: any RoutineBridgeProtocol, categories: any CategoryBridgeProtocol) {
        self.bridge = bridge; self.categoryBridge = categories
        bridge.onChanged = { [weak self] in self?.reload() }
        bridge.onFailure = { [weak self] in self?.errorMessage = $0 }
        categories.onChanged = { [weak self] in self?.reloadCategories() }
        reload(); reloadCategories()
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
    public func cancel() { editing = false; editingWeekdays = false; opened = nil }
    @discardableResult public func save() -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "例行任务标题不能为空"; return false }
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
        do {
            try bridge.setWeekdays(id: opened.id, weekdays: weekdays)
            editingWeekdays = false; self.opened = nil; reload(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    public func setActive(_ value: RoutineValue, active: Bool) {
        do { try bridge.setActive(id: value.id, active: active); reload() }
        catch { errorMessage = error.localizedDescription }
    }
    public func delete(_ value: RoutineValue) {
        do { try bridge.delete(id: value.id); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
