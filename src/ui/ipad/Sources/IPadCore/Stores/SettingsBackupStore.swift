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
    @ObservationIgnored private let flushEdits: () -> Bool
    @ObservationIgnored private let commitPending: () -> Bool
    @ObservationIgnored private let restoreWarning: () -> String
    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var localURL: URL?
    private enum Operation { case backup, inspect, restore }
    public init(bridge: any BackupBridgeProtocol, files: any FileTransferWorkspaceProtocol,
                flushEdits: @escaping () -> Bool = { true },
                commitPending: @escaping () -> Bool, restoreWarning: @escaping () -> String) {
        self.bridge = bridge; self.files = files; self.flushEdits = flushEdits
        self.commitPending = commitPending; self.restoreWarning = restoreWarning
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
        // 备份前先同步冲刷备忘录编辑会话再提交待删槽；未保存草稿无法落盘时不生成残缺备份。
        guard flushEdits() else { errorMessage = "备忘录还有未保存的修改，请先回备忘录处理"; return }
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
    // 真实界面导入最大可达 512 MiB 的备份：将安全作用域读取与磁盘拷贝放到后台任务，避免阻塞主线程。
    public func importBackupAsync(_ source: URL) async {
        guard !working && exportURL == nil && restoreInfo == nil && !snapshot.busy else { return }
        let target: URL
        do {
            target = try files.prepareFile(name: source.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
            releaseFiles()
            return
        }
        localURL = target; errorMessage = ""; notice = ""; operation = .inspect; working = true
        do {
            try await Task.detached(priority: .userInitiated) {
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: target)
            }.value
            guard operation == .inspect, localURL == target else { return }
            bridge.requestBackupInfo(path: target.path)
        } catch {
            guard operation == .inspect, localURL == target else { return }
            operation = nil; working = false
            errorMessage = error.localizedDescription
            releaseFiles()
        }
    }
    private func infoReady(path: String, info: BackupInfo) {
        guard operation == .inspect, localURL?.path == path else { return }
        operation = nil; working = false
        guard info.valid else { errorMessage = info.reason; releaseFiles(); return }
        restoreInfo = info; confirmationWarning = restoreWarning()
    }
    public func confirmRestore() {
        guard restoreInfo?.valid == true, let localURL else { return }
        // 恢复换库前必须先冲刷备忘草稿并提交待删槽；任一失败均中止恢复，防止丢失未存修改或覆盖新库。
        guard flushEdits() else { errorMessage = "备忘录还有未保存的修改，请先回备忘录处理"; cancelRestore(); return }
        guard commitPending() else { errorMessage = "待删项提交失败，恢复已取消"; cancelRestore(); return }
        restoreInfo = nil; confirmationWarning = ""; operation = .restore; working = true
        bridge.requestRestore(path: localURL.path)
    }
    public func cancelRestore() {
        // confirmRestore 已把 restoreInfo 置空并转入恢复中；alert 收起回调不能误删正在恢复的临时副本。
        guard restoreInfo != nil else { return }
        restoreInfo = nil; confirmationWarning = ""; releaseFiles()
    }
    private func restoreCompleted(_ success: Bool, message: String) {
        guard operation == .restore else { return }
        operation = nil; working = false
        if success { notice = message; errorMessage = "" } else { errorMessage = message }
        releaseFiles(); refresh(); if success { reloadBackups() }
    }
    public func finishExport(error: Error?) {
        guard exportURL != nil else { return }
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
