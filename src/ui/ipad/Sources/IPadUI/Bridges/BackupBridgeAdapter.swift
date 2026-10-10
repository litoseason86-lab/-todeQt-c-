import Foundation
import IPadCore
import PTBridge

@MainActor final class BackupBridgeAdapter: BackupBridgeProtocol {
    private let native = PTBackupBridge()
    var onChanged: (() -> Void)?
    var onBackupCompleted: ((Bool, String) -> Void)?
    var onBackupInfoReady: ((String, BackupInfo) -> Void)?
    var onRestoreCompleted: ((Bool, String) -> Void)?
    var onRestoreStarted: (() -> Void)?
    init() {
        // Qt 发主线程信号；回调不强持有适配器，根上的 Store 使用专用实例。
        native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        native.onBackupCompleted = { [weak self] ok, text in MainActor.assumeIsolated { self?.onBackupCompleted?(ok, text) } }
        native.onBackupInfoReady = { [weak self] path, info in
            MainActor.assumeIsolated { self?.onBackupInfoReady?(path, Self.info(info)) }
        }
        native.onRestoreCompleted = { [weak self] ok, text in MainActor.assumeIsolated { self?.onRestoreCompleted?(ok, text) } }
        native.onRestoreStarted = { [weak self] in MainActor.assumeIsolated { self?.onRestoreStarted?() } }
    }
    func autoBackupEnabled() -> Bool { native.autoBackupEnabled }
    func setAutoBackupEnabled(_ value: Bool) throws { try native.setAutoBackupEnabled(value) }
    func snapshot() -> BackupSnapshot {
        var value = BackupSnapshot()
        value.lastBackupTimeIso = native.lastBackupTimeIso; value.busy = native.busy
        value.operationBlocksUI = native.operationBlocksUi; value.operationText = native.operationText
        value.lastError = native.lastError
        return value
    }
    func requestBackup(path: String) { native.requestBackup(path) }
    func requestBackupInfo(path: String) { native.requestBackupInfo(path) }
    func requestRestore(path: String) { native.requestRestore(path) }
    func readBackupInfo(path: String) -> BackupInfo { Self.info(native.readBackupInfo(path)) }
    func readBackups() throws -> [BackupEntry] {
        try native.readBackups().map { item in
            BackupEntry(path: item.path, name: item.name, modified: item.modified, sizeBytes: item.sizeBytes)
        }
    }
    func suggestedBackupFileName() -> String { native.suggestedBackupFileName() }
    func backupFileExtension() -> String { native.backupFileExtension() }
    private static func info(_ item: PTBackupInfoValue) -> BackupInfo {
        BackupInfo(valid: item.valid, reason: item.reason, createdAt: item.createdAt, appVersion: item.appVersion,
                   taskCount: item.taskCount, sessionCount: item.sessionCount)
    }
}
