import Foundation
import Observation

public struct TrashGroup: Equatable, Identifiable {
    public let key: String
    public let label: String
    public let remainingLabel: String
    public let items: [TrashItem]
    public var id: String { key }
}

public enum TrashConfirmation: Equatable {
    case restore, delete, empty
    case deleteSelection(Int)
    public var title: String {
        switch self { case .restore: "恢复项目？"; case .delete: "彻底删除？"; case .empty: "清空废纸篓？"; case .deleteSelection(let count): "彻底删除选中的 \(count) 项？" }
    }
}

@MainActor @Observable public final class TrashStore {
    public private(set) var items: [TrashItem] = []
    public private(set) var today = ""
    public private(set) var loaded = false
    public private(set) var loadError = ""
    public private(set) var actionError = ""
    public private(set) var restoredTitle = ""
    public private(set) var pendingRestore: TrashItem?
    public private(set) var pendingDelete: TrashItem?
    public private(set) var pendingEmptyIDs: [Int]?
    public private(set) var selecting = false
    public private(set) var selection: Set<Int> = []
    public private(set) var batchNotice = ""
    public var allSelected: Bool { !items.isEmpty && items.allSatisfy { selection.contains($0.id) } }
    private var pendingSelectionIDs: [Int]?
    @ObservationIgnored private var batchWriting = false
    @ObservationIgnored private let bridge: any TrashBridgeProtocol
    @ObservationIgnored private let logicalDay: (any LogicalDayBridgeProtocol)?
    @ObservationIgnored private var active = false

    public init(bridge: any TrashBridgeProtocol, logicalDay: (any LogicalDayBridgeProtocol)? = nil) {
        self.bridge = bridge; self.logicalDay = logicalDay
        bridge.onChanged = { [weak self] in if self?.active == true && self?.batchWriting == false { self?.reload() } }
        logicalDay?.onChanged = { [weak self] in if self?.active == true && self?.batchWriting == false { self?.reload() } }
    }

    public var groups: [TrashGroup] { TrashFormat.groupItems(items, today: today) }
    public var confirmation: TrashConfirmation? {
        if let ids = pendingSelectionIDs { return .deleteSelection(ids.count) }
        if pendingRestore != nil { return .restore }
        if pendingDelete != nil { return .delete }
        if pendingEmptyIDs != nil { return .empty }
        return nil
    }
    public func cancelConfirmation() { pendingRestore = nil; pendingDelete = nil; pendingEmptyIDs = nil; pendingSelectionIDs = nil }
    public func requestRestore(_ item: TrashItem) {
        guard item.restorable else { return }
        cancelConfirmation(); pendingRestore = item
    }
    public func cancelRestore() { pendingRestore = nil }
    public func confirmRestore() {
        guard let item = pendingRestore else { return }
        pendingRestore = nil; restore(item)
    }
    public func dismissNotice() { restoredTitle = ""; actionError = ""; batchNotice = "" }

    public func activate() { active = true; actionError = ""; do { _ = try bridge.purgeExpired() } catch { actionError = error.localizedDescription }; reload() }
    public func deactivate() { active = false; endSelection(); cancelConfirmation() }
    public func reload() {
        do {
            let result = try bridge.readItems()
            items = result.items; today = result.today; loaded = true; loadError = ""
            selection.formIntersection(Set(items.map(\.id)))
        } catch { loadError = error.localizedDescription }
    }
    public func retry() { reload() }
    public func restore(_ item: TrashItem) {
        do {
            let result = try bridge.restore(id: item.id)
            if result.error.isEmpty { restoredTitle = result.title.isEmpty ? item.title : result.title; actionError = ""; reload() }
            else { actionError = Self.restoreFailure(item: item, result: result, today: today); if result.code == "gone" { reload() } }
        } catch { actionError = error.localizedDescription }
    }
    public func requestDelete(_ item: TrashItem) { cancelConfirmation(); pendingDelete = item }
    public func cancelDelete() { pendingDelete = nil }
    public func confirmDelete() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        do { let result = try bridge.delete(id: item.id); finish(result) }
        catch { actionError = error.localizedDescription }
    }
    public func requestEmpty() { guard !items.isEmpty else { return }; cancelConfirmation(); pendingEmptyIDs = items.map(\.id) }
    public func cancelEmpty() { pendingEmptyIDs = nil }
    public func confirmEmpty() {
        guard let ids = pendingEmptyIDs else { return }
        pendingEmptyIDs = nil
        do { finish(try bridge.empty(ids: ids)) }
        catch { actionError = error.localizedDescription }
    }
    private func finish(_ result: TrashActionResult) {
        if result.error.isEmpty { actionError = ""; reload() }
        else { actionError = result.error; if result.code == "gone" { reload() } }
    }

    public func beginSelection() { cancelConfirmation(); selecting = true; selection = []; dismissNotice() }
    public func endSelection() { selecting = false; selection = []; pendingSelectionIDs = nil }
    public func toggleSelection(_ id: Int) {
        guard selecting, items.contains(where: { $0.id == id }) else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    public func toggleSelectAll() {
        guard selecting else { return }
        selection = allSelected ? [] : Set(items.map(\.id))
    }
    public func restoreSelection() {
        let selected = items.filter { selection.contains($0.id) }
        guard selecting, !selected.isEmpty else { return }
        // 恢复是逐条独立事务；同步通知先抑制，整批结束仅重读一次，避免每恢复一条重建列表。
        batchWriting = true
        defer { batchWriting = false; reload() }
        var failures: [String] = []
        var restored = 0
        batchNotice = ""; actionError = ""
        for item in selected {
            let result: TrashActionResult
            if !item.restorable {
                let reason = TrashFormat.blockedText(item.blockedReason)
                result = TrashActionResult(error: reason.isEmpty ? "此项目无法恢复" : reason)
            } else {
                do { result = try bridge.restore(id: item.id) }
                catch { result = TrashActionResult(error: error.localizedDescription) }
            }
            if result.error.isEmpty { selection.remove(item.id); restored += 1 }
            else { failures.append(TrashFormat.restoreFailure(item: item, result: result, today: today)) }
        }
        if failures.isEmpty { endSelection(); batchNotice = "已恢复 \(restored) 项" }
        else { actionError = "有 \(failures.count) 项没能恢复：" + failures.joined(separator: "\n") }
    }
    public func requestDeleteSelection() {
        let ids = items.map(\.id).filter { selection.contains($0) }
        guard selecting, !ids.isEmpty else { return }
        // 固定确认打开时的编号和顺序；确认期间新增条目不能被扩大到这次删除里。
        cancelConfirmation(); pendingSelectionIDs = ids
    }
    public func confirmDeleteSelection() {
        guard let ids = pendingSelectionIDs else { return }
        pendingSelectionIDs = nil; batchWriting = true
        defer { batchWriting = false }
        do {
            let result = try bridge.empty(ids: ids)
            guard result.error.isEmpty else { actionError = result.error; return }
            actionError = ""; endSelection(); reload()
        } catch { actionError = error.localizedDescription }
    }

    public static func restoreFailure(item: TrashItem, result: TrashActionResult, today: String) -> String {
        TrashFormat.restoreFailure(item: item, result: result, today: today)
    }
    public static func groupLabel(_ deletedDate: String, today: String) -> String {
        TrashFormat.groupLabel(deletedDate, today: today)
    }
}
