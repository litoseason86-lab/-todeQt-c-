import Foundation
import IPadCore
import PTBridge
import UIKit
@MainActor final class SyncBridgeAdapter: SyncBridgeProtocol {
    private let native = PTSyncBridge(); var onChanged: (() -> Void)?; var onNotice: ((String) -> Void)?; var onCopyRequested: ((String) -> Void)?
    init() { native.onStatusChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onFolderChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onChoosingFolderChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onLogChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onNotice = { [weak self] value in MainActor.assumeIsolated { self?.onNotice?(value) } }; native.onCopyRequested = { [weak self] value in MainActor.assumeIsolated { UIPasteboard.general.string = value; self?.onCopyRequested?(value) } } }
    func snapshot() -> SyncSnapshot { var s = SyncSnapshot(); s.enabled = native.enabled; s.statusKey = native.statusKey; s.hasProblem = native.hasProblem; s.summaryText = native.summaryText; s.statusText = native.statusText; s.statusDetail = native.statusDetail; s.pendingCount = native.pendingCount; s.lastSyncedAt = native.lastSyncedAt; s.busy = native.busy; s.hasFolder = native.hasFolder; s.folderDisplayPath = native.folderDisplayPath; s.choosingFolder = native.choosingFolder; s.folderProblem = native.folderProblem; s.logRevision = native.logRevision; s.logCount = native.logCount; return s }
    func setEnabled(_ value: Bool) { native.setEnabled(value) }; func confirmJoin() { native.confirmJoin() }; func syncNow() { native.syncNow() }; func chooseFolder() { native.chooseFolder() }; func rebuildFolder() { native.rebuildFolder() }; func copyLostValue(_ text: String) { native.copyLostValue(text) }; func restoreWarning() -> String { native.restoreWarning() }
    func syncLog(limit: Int) throws -> [SyncLogEntry] {
        let result = native.syncLog(limit)
        guard result.valid else { throw NSError(domain: "PTSyncBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        return result.entries.compactMap { raw in
            guard let id = (raw["id"] as? NSNumber)?.int64Value else { return nil }
            func text(_ key: String) -> String { raw[key] as? String ?? "" }
            return SyncLogEntry(id: id, kind: text("kind"), kindLabel: text("kindLabel"), time: text("time"),
                                title: text("title"), summary: text("summary"), detail: text("detail"),
                                fieldLabel: text("fieldLabel"), lostValue: text("lostValue"), keptValue: text("keptValue"))
        }
    }
}
