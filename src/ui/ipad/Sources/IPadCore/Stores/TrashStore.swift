import Foundation
import Observation

public struct TrashGroup: Equatable, Identifiable {
    public let key: String
    public let label: String
    public let remainingLabel: String
    public let items: [TrashItem]
    public var id: String { key }
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
    @ObservationIgnored private let bridge: any TrashBridgeProtocol
    @ObservationIgnored private let logicalDay: (any LogicalDayBridgeProtocol)?
    @ObservationIgnored private var active = false

    public init(bridge: any TrashBridgeProtocol, logicalDay: (any LogicalDayBridgeProtocol)? = nil) {
        self.bridge = bridge; self.logicalDay = logicalDay
        bridge.onChanged = { [weak self] in if self?.active == true { self?.reload() } }
        logicalDay?.onChanged = { [weak self] in if self?.active == true { self?.reload() } }
    }

    public var groups: [TrashGroup] { TrashFormat.groupItems(items, today: today) }
    public func requestRestore(_ item: TrashItem) { pendingRestore = item }
    public func cancelRestore() { pendingRestore = nil }
    public func confirmRestore() {
        guard let item = pendingRestore else { return }
        pendingRestore = nil; restore(item)
    }
    public func dismissNotice() { restoredTitle = ""; actionError = "" }

    public func activate() { active = true; actionError = ""; do { _ = try bridge.purgeExpired() } catch { actionError = error.localizedDescription }; reload() }
    public func deactivate() { active = false }
    public func reload() {
        do {
            let result = try bridge.readItems()
            items = result.items; today = result.today; loaded = true; loadError = ""
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
    public func requestDelete(_ item: TrashItem) { pendingDelete = item }
    public func cancelDelete() { pendingDelete = nil }
    public func confirmDelete() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        do { let result = try bridge.delete(id: item.id); finish(result) }
        catch { actionError = error.localizedDescription }
    }
    public func requestEmpty() { guard !items.isEmpty else { return }; pendingEmptyIDs = items.map(\.id) }
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

    public static func restoreFailure(item: TrashItem, result: TrashActionResult, today: String) -> String {
        TrashFormat.restoreFailure(item: item, result: result, today: today)
    }
    public static func groupLabel(_ deletedDate: String, today: String) -> String {
        TrashFormat.groupLabel(deletedDate, today: today)
    }
}
