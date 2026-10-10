import Foundation
import Observation

@MainActor @Observable public final class CountdownStore {
    public private(set) var items: [CountdownValue] = []
    public private(set) var primary: CountdownValue?
    public private(set) var errorMessage = ""
    public private(set) var lastNotice = ""
    @ObservationIgnored private let bridge: any CountdownBridging
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private weak var shell: ShellStore?
    private var active = false
    private var reading = false
    private var writing = false
    public init(bridge: any CountdownBridging, logicalDay: any LogicalDayBridgeProtocol, shell: ShellStore? = nil) {
        self.bridge = bridge; self.logicalDay = logicalDay; self.shell = shell
        // 模型重载和主目标信号可能同步交错；刷新期间不重入，失败保留最后一次完整结果。
        logicalDay.onChanged = { [weak self] in self?.logicalDayChanged() }
        bridge.onChanged = { [weak self] in if self?.active == true { self?.refresh() } }
        bridge.onPrimaryGoalChanged = { [weak self] in if self?.active == true { self?.refresh() } }
        bridge.onFailure = { [weak self] message in if self?.active == true { self?.errorMessage = message } }
    }
    public var secondary: [CountdownValue] { items.filter { $0.id != primary?.id } }
    public var logicalToday: String { logicalDay.today }
    public func setActive(_ value: Bool) { active = value; if value { refresh() } }
    public func logicalDayChanged() { if active { refresh() } }
    public func refresh() {
        guard !reading && !writing else { return }; reading = true; defer { reading = false }
        do {
            let rows = try bridge.goals(); let main = try bridge.primaryGoal()
            items = rows; primary = main; errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult private func perform(_ action: () throws -> Void) -> Bool {
        writing = true
        do { try action(); writing = false; errorMessage = ""; refresh(); return true }
        catch { writing = false; errorMessage = error.localizedDescription; return false }
    }
    @discardableResult public func add(name: String, date: String) -> Bool { perform { try bridge.add(name: name, date: date) } }
    @discardableResult public func save(opened: CountdownValue, edited: CountdownValue) -> Bool {
        let changes = CountdownChanges(name: opened.name == edited.name ? nil : edited.name,
            targetDate: opened.targetDate == edited.targetDate ? nil : edited.targetDate)
        guard !changes.isEmpty else { return true }
        return perform { try bridge.update(id: opened.id, changes: changes) }
    }
    @discardableResult public func move(id: Int, delta: Int) -> Bool {
        guard let from = items.firstIndex(where: { $0.id == id }), items.indices.contains(from + delta) else { return false }
        return perform { try bridge.reorder(from: from, to: from + delta) }
    }
    @discardableResult public func makePrimary(id: Int) -> Bool {
        guard let from = items.firstIndex(where: { $0.id == id }), from > 0 else { return false }
        return perform { try bridge.reorder(from: from, to: 0) }
    }
    @discardableResult public func delete(_ value: CountdownValue) -> Bool {
        // 沿用 Mac 的直接删除，进废纸篓由服务事务保证；本页只提示结果。
        guard perform({ try bridge.delete(id: value.id) }) else { return false }
        lastNotice = "已删除「\(value.name)」"; shell?.showToast(lastNotice); return true
    }
}
