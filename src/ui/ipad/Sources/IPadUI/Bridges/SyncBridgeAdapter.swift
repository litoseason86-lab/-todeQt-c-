import Foundation
import IPadCore
import PTBridge
import UIKit
@MainActor final class SyncBridgeAdapter: SyncBridgeProtocol {
    private let native = PTSyncBridge(); var onChanged: (() -> Void)?; var onNotice: ((String) -> Void)?; var onCopyRequested: ((String) -> Void)?
    init() { native.onStatusChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onFolderChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onChoosingFolderChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onLogChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onNotice = { [weak self] value in MainActor.assumeIsolated { self?.onNotice?(value) } }; native.onCopyRequested = { [weak self] value in MainActor.assumeIsolated { UIPasteboard.general.string = value; self?.onCopyRequested?(value) } } }
    func snapshot() throws -> SyncSnapshot { var s = SyncSnapshot(); s.enabled = native.enabled; s.statusKey = native.statusKey; s.hasProblem = native.hasProblem; s.summaryText = native.summaryText; s.statusText = native.statusText; s.statusDetail = native.statusDetail; s.pendingCount = native.pendingCount; s.lastSyncedAt = native.lastSyncedAt; s.busy = native.busy; s.hasFolder = native.hasFolder; s.folderDisplayPath = native.folderDisplayPath; s.choosingFolder = native.choosingFolder; s.folderProblem = native.folderProblem; s.logRevision = native.logRevision; s.logCount = try native.readLogCount(); return s }
    func setEnabled(_ value: Bool) { native.setEnabled(value) }; func confirmJoin() { native.confirmJoin() }; func syncNow() { native.syncNow() }; func chooseFolder() { native.chooseFolder() }; func rebuildFolder() { native.rebuildFolder() }; func copyLostValue(_ text: String) { native.copyLostValue(text) }; func restoreWarning() -> String { native.restoreWarning() }
    func syncLog(limit: Int) throws -> [SyncLogEntry] {
        let result = native.syncLog(limit)
        guard result.valid else { throw NSError(domain: "PTSyncBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        return result.entries.map { entry in
            SyncLogEntry(id: entry.entryId, kind: entry.kind, kindLabel: entry.kindLabel, time: entry.time,
                         title: entry.title, summary: entry.summary, detail: entry.detail, fieldLabel: entry.fieldLabel,
                         lostValue: entry.lostValue, keptValue: entry.keptValue, canCopyLostValue: entry.canCopyLostValue)
        }
    }
}
