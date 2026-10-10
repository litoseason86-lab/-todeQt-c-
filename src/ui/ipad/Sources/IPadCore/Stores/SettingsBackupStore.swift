import Foundation
import Observation

@MainActor @Observable public final class SettingsBackupStore {
    public private(set) var snapshot = BackupSnapshot()
    public private(set) var autoBackupEnabled = false
    public private(set) var backups: [BackupEntry] = []
    public private(set) var errorMessage = ""
    public private(set) var notice = ""
    public private(set) var exportURL: URL?
    public private(set) var restoreInfo: BackupInfo?
    public private(set) var confirmationWarning = ""
    public private(set) var working = false
    @ObservationIgnored private let bridge: any BackupBridgeProtocol
    @ObservationIgnored private let files: any FileTransferWorkspaceProtocol
    @ObservationIgnored private let commitPending: () -> Bool
    @ObservationIgnored private let restoreWarning: () -> String
    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var localURL: URL?
    private enum Operation { case backup, inspect, restore }
    public init(bridge: any BackupBridgeProtocol, files: any FileTransferWorkspaceProtocol,
                commitPending: @escaping () -> Bool, restoreWarning: @escaping () -> String) {
        self.bridge = bridge; self.files = files; self.commitPending = commitPending; self.restoreWarning = restoreWarning
        bridge.onChanged = { [weak self] in self?.refresh() }
        bridge.onBackupCompleted = { [weak self] in self?.backupCompleted($0, message: $1) }
        bridge.onBackupInfoReady = { [weak self] in self?.infoReady(path: $0, info: $1) }
        bridge.onRestoreCompleted = { [weak self] in self?.restoreCompleted($0, message: $1) }
        refresh(); reloadBackups()
    }
    public func refresh() { snapshot = bridge.snapshot(); autoBackupEnabled = bridge.autoBackupEnabled() }
    public func reloadBackups() {
        do { backups = try bridge.readBackups(); errorMessage = "" }
        catch { errorMessage = error.localizedDescription }
    }
    public func setAutoBackupEnabled(_ value: Bool) {
        let previous = autoBackupEnabled
        do { try bridge.setAutoBackupEnabled(value); refresh(); errorMessage = "" }
        catch { autoBackupEnabled = previous; errorMessage = error.localizedDescription }
    }
    public func createBackup() {
        guard !working && exportURL == nil && restoreInfo == nil && !snapshot.busy else { return }
        guard commitPending() else { errorMessage = "待删项提交失败，备份已取消"; return }
        do {
            localURL = try files.prepareFile(name: bridge.suggestedBackupFileName())
            errorMessage = ""; notice = ""; operation = .backup; working = true
            bridge.requestBackup(path: localURL!.path)
        } catch { errorMessage = error.localizedDescription; releaseFiles() }
    }
    private func backupCompleted(_ success: Bool, message: String) {
        guard operation == .backup else { return }
        operation = nil; working = false
        if success { exportURL = localURL; notice = message; reloadBackups() }
        else { errorMessage = message; releaseFiles() }
        refresh()
    }
    public func importBackup(_ source: URL) throws {
        guard !working && exportURL == nil && restoreInfo == nil && !snapshot.busy else { return }
        do {
            localURL = try files.importFile(from: source)
            errorMessage = ""; notice = ""; operation = .inspect; working = true
            bridge.requestBackupInfo(path: localURL!.path)
        } catch { errorMessage = error.localizedDescription; releaseFiles(); throw error }
    }
    private func infoReady(path: String, info: BackupInfo) {
        guard operation == .inspect, localURL?.path == path else { return }
        operation = nil; working = false
        guard info.valid else { errorMessage = info.reason; releaseFiles(); return }
        restoreInfo = info; confirmationWarning = restoreWarning()
    }
    public func confirmRestore() {
        guard restoreInfo?.valid == true, let localURL else { return }
        // 提交待删槽必须早于任何恢复调用；失败时不让服务替换当前数据库。
        guard commitPending() else { errorMessage = "待删项提交失败，恢复已取消"; cancelRestore(); return }
        restoreInfo = nil; confirmationWarning = ""; operation = .restore; working = true
        bridge.requestRestore(path: localURL.path)
    }
    public func cancelRestore() { restoreInfo = nil; confirmationWarning = ""; releaseFiles() }
    private func restoreCompleted(_ success: Bool, message: String) {
        guard operation == .restore else { return }
        operation = nil; working = false
        if success { notice = message; errorMessage = "" } else { errorMessage = message }
        releaseFiles(); refresh(); if success { reloadBackups() }
    }
    public func finishExport(error: Error?) {
        if let error, !Self.isCancellation(error) { errorMessage = error.localizedDescription }
        exportURL = nil; releaseFiles()
    }
    public func importFailed(_ error: Error) {
        if !Self.isCancellation(error) { errorMessage = error.localizedDescription }
        releaseFiles()
    }
    private static func isCancellation(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError
    }
    private func releaseFiles() {
        do { try files.cleanup(); localURL = nil; exportURL = nil }
        catch { errorMessage += (errorMessage.isEmpty ? "" : "\n") + "临时文件清理失败：" + error.localizedDescription }
    }
}
