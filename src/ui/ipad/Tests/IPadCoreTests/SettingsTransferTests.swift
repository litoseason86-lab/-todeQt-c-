import IPadCore
import XCTest

@MainActor final class SettingsTransferTests: XCTestCase {
    // 产品保证：恢复确认显示同步提醒；待删项提交失败绝不调用恢复，并清理导入副本。
    func testRestoreCommitFailurePreventsRestoreAndKeepsWarning() throws {
        let bridge = SettingsBackupFake(); let files = SettingsFilesFake()
        var commits = 0
        let store = SettingsBackupStore(bridge: bridge, files: files,
            commitPending: { commits += 1; return false }, restoreWarning: { "下次同步会影响其它设备" })
        try store.importBackup(URL(fileURLWithPath: "/external/backup.tomatobackup"))
        XCTAssertEqual(bridge.calls.last, "inspect:/owned/import.tomatobackup")
        bridge.onBackupInfoReady?("/owned/import.tomatobackup", BackupInfo(valid: true))
        XCTAssertEqual(store.confirmationWarning, "下次同步会影响其它设备")
        XCTAssertNotNil(store.restoreInfo)
        store.confirmRestore()
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(bridge.calls.contains { $0.hasPrefix("restore:") })
        XCTAssertEqual(files.cleanups, 1)
        XCTAssertFalse(store.errorMessage.isEmpty)
    }

    // 产品保证：恢复只用沙盒副本，先提交待删项；完成、取消确认、信息失败都清理。
    func testRestoreUsesOwnedCopyAndCleansAllOutcomes() throws {
        for outcome in ["success", "failure", "cancel", "invalid"] {
            let bridge = SettingsBackupFake(); let files = SettingsFilesFake()
            var order: [String] = []
            bridge.onRestoreCall = { order.append("restore") }
            let store = SettingsBackupStore(bridge: bridge, files: files,
                commitPending: { order.append("commit"); return true }, restoreWarning: { "" })
            try store.importBackup(URL(fileURLWithPath: "/external/input"))
            bridge.onBackupInfoReady?("/owned/import.tomatobackup", BackupInfo(valid: outcome != "invalid", reason: "文件无效"))
            if outcome == "cancel" { store.cancelRestore() }
            else if outcome != "invalid" {
                store.confirmRestore()
                XCTAssertEqual(order, ["commit", "restore"])
                XCTAssertTrue(bridge.calls.contains("restore:/owned/import.tomatobackup"))
                bridge.onRestoreCompleted?(outcome == "success", "恢复结果")
            }
            XCTAssertEqual(files.cleanups, 1, outcome)
            XCTAssertNil(store.restoreInfo)
        }
    }

    // 产品保证：备份支持连续操作，服务失败、系统保存成功或取消都会释放临时文件。
    func testBackupRepeatedOperationsCleanSuccessCancelAndFailure() {
        let bridge = SettingsBackupFake(); let files = SettingsFilesFake()
        let store = SettingsBackupStore(bridge: bridge, files: files, commitPending: { true }, restoreWarning: { "" })
        for outcome in ["success", "cancel", "failure"] {
            store.createBackup()
            XCTAssertNotNil(bridge.onBackupCompleted)
            bridge.onBackupCompleted?(outcome != "failure", "备份结果")
            if outcome != "failure" {
                XCTAssertNotNil(store.exportURL)
                store.finishExport(error: outcome == "cancel" ? CocoaError(.userCancelled) : nil)
            }
            XCTAssertNil(store.exportURL)
        }
        XCTAssertEqual(files.cleanups, 3)
        XCTAssertEqual(bridge.calls.filter { $0.hasPrefix("backup:") }.count, 3)
    }

    // 产品保证：导出全部交目录给服务；单文件与目录在成功、取消和失败后均清理。
    func testExportAllUsesDirectoryAndCleansEveryOutcome() {
        for kind in ExportKind.allCases {
            for outcome in ["success", "cancel", "failure"] {
                let bridge = SettingsExportFake(); let files = SettingsFilesFake()
                let store = SettingsExportStore(bridge: bridge, files: files, logicalDay: LogicalDayBridgeFake())
                store.start(kind)
                XCTAssertEqual(bridge.calls.last, kind == .all ? "all:/owned/export" : "\(kind.rawValue):/owned/output.csv")
                bridge.onCompleted?(outcome != "failure", "导出结果")
                if outcome != "failure" {
                    XCTAssertNotNil(store.exportURL)
                    store.finishExport(error: outcome == "cancel" ? CocoaError(.userCancelled) : nil)
                }
                XCTAssertEqual(files.cleanups, 1)
                XCTAssertNil(store.exportURL)
            }
        }
    }

    // 产品保证：临时工作区只清理自有目录，导入原文件和其它工作区都保留。
    func testRealWorkspaceCopiesAndRemovesOnlyOwnedFiles() throws {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("pt-P4-5-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.tomatobackup")
        try Data("backup".utf8).write(to: source)
        let first = FileTransferWorkspace(base: base), second = FileTransferWorkspace(base: base)
        let imported = try first.importFile(from: source)
        let other = try second.prepareFile(name: "output.csv")
        try Data("csv".utf8).write(to: other)
        XCTAssertNotEqual(imported.deletingLastPathComponent(), other.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: imported), Data("backup".utf8))
        try first.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        try second.cleanup()
    }

    // 产品保证：同步日志读取失败保留旧条目，复制的是未经截断的原始丢失值。
    func testSyncFailureAndLostValueCopy() {
        let bridge = SettingsSyncFake()
        let entry = SyncLogEntry(id: 1, kind: "edit", kindLabel: "修改冲突", time: "今天", title: "备忘录",
            summary: "冲突", detail: "详情", fieldLabel: "正文", lostValue: "  第一行\n🍅\n", keptValue: "新版", canCopyLostValue: true)
        bridge.logs = [entry]
        let store = SettingsSyncStore(bridge: bridge)
        store.reloadLogs(); XCTAssertEqual(store.logs, [entry])
        store.copy(entry); XCTAssertEqual(bridge.copied, entry.lostValue)
        XCTAssertEqual(store.notice, "已复制丢失值")
        bridge.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据库读取失败"])
        store.reloadLogs(); XCTAssertEqual(store.logs, [entry]); XCTAssertEqual(store.errorMessage, "数据库读取失败")
    }

    // 产品保证：只有服务允许复制的同步日志提供复制动作，有原文而不可复制的日志不会写剪贴板。
    func testSyncCopyRespectsServiceCapability() {
        let bridge = SettingsSyncFake()
        let entry = SyncLogEntry(id: 2, kind: "delete", kindLabel: "删除冲突", time: "今天", title: "任务",
            summary: "删除赢过修改", detail: "详情", fieldLabel: "标题", lostValue: "未生效的任务名", keptValue: "", canCopyLostValue: false)
        XCTAssertFalse(entry.lostValue.isEmpty)
        XCTAssertFalse(entry.canCopyLostValue)
        let store = SettingsSyncStore(bridge: bridge)
        store.copy(entry)
        XCTAssertEqual(bridge.copied, "")
        XCTAssertEqual(store.notice, "")
    }

    // 产品保证：系统保存失败与备份服务失败都展示原因，并清理已生成的文件。
    func testSystemSaveFailuresAreReportedAndCleaned() {
        let failure = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "文件保存失败"])
        let backup = SettingsBackupFake(); let backupFiles = SettingsFilesFake()
        let backupStore = SettingsBackupStore(bridge: backup, files: backupFiles, commitPending: { true }, restoreWarning: { "" })
        backupStore.createBackup(); backup.onBackupCompleted?(true, "完成")
        backupStore.finishExport(error: failure)
        XCTAssertEqual(backupStore.errorMessage, "文件保存失败")
        XCTAssertEqual(backupFiles.cleanups, 1)
        let export = SettingsExportFake(); let exportFiles = SettingsFilesFake()
        let exportStore = SettingsExportStore(bridge: export, files: exportFiles, logicalDay: LogicalDayBridgeFake())
        exportStore.start(.tasks); export.onCompleted?(true, "完成")
        exportStore.finishExport(error: failure)
        XCTAssertEqual(exportStore.errorMessage, "文件保存失败")
        XCTAssertEqual(exportFiles.cleanups, 1)
    }

    // 产品保证：同步开关显示服务接受的值；状态变化刷新，文件夹和同步动作原样转发。
    func testSyncShowsAcceptedStateAndForwardsActions() {
        let bridge = SettingsSyncFake(); let store = SettingsSyncStore(bridge: bridge)
        store.setEnabled(true)
        XCTAssertFalse(store.snapshot.enabled)
        XCTAssertEqual(bridge.calls, ["enabled:true"])
        bridge.result.enabled = true; bridge.result.statusKey = "needsConfirmation"
        bridge.result.folderProblem = "所选目录不是同步文件夹"
        bridge.onChanged?()
        XCTAssertTrue(store.snapshot.enabled)
        XCTAssertEqual(store.snapshot.statusKey, "needsConfirmation")
        XCTAssertEqual(store.snapshot.folderProblem, "所选目录不是同步文件夹")
        store.chooseFolder(); store.confirmJoin(); store.rebuildFolder(); store.syncNow()
        XCTAssertEqual(Array(bridge.calls.suffix(4)), ["choose", "join", "rebuild", "sync"])
        bridge.onNotice?("目录选择取消")
        XCTAssertEqual(store.notice, "目录选择取消")
    }

    // 产品保证：服务仍在生成导出文件时，不伪造取消或清理服务正在写入的目录。
    func testExportCannotPretendCancellationWhileServiceIsWorking() {
        let bridge = SettingsExportFake(); let files = SettingsFilesFake()
        let store = SettingsExportStore(bridge: bridge, files: files, logicalDay: LogicalDayBridgeFake())
        store.start(.tasks); XCTAssertTrue(store.busy); XCTAssertNil(store.exportURL)
        store.finishExport(error: CocoaError(.userCancelled))
        XCTAssertTrue(store.busy); XCTAssertEqual(files.cleanups, 0)
        bridge.onProgress?(4, 10)
        XCTAssertEqual(store.progress, 4); XCTAssertEqual(store.total, 10)
        bridge.onCompleted?(false, "导出数据库不可读")
        XCTAssertEqual(store.errorMessage, "导出数据库不可读")
        XCTAssertEqual(files.cleanups, 1)
    }
    // 产品保证：六个同步动作未能派发时都显示桥接原因，不伪称复制成功或静默忽略。
    func testSyncActionFailuresPreserveBridgeReason() {
        for action in 0..<6 {
            let bridge = SettingsSyncFake()
            let store = SettingsSyncStore(bridge: bridge)
            XCTAssertEqual(store.errorMessage, "")
            bridge.actionError = NSError(domain: "测试", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "同步服务未登记或已释放"])
            switch action {
            case 0: store.setEnabled(true)
            case 1: store.confirmJoin()
            case 2: store.syncNow()
            case 3: store.chooseFolder()
            case 4: store.rebuildFolder()
            default: store.copy(SyncLogEntry(id: 1, kind: "edit", kindLabel: "", time: "", title: "",
                summary: "", detail: "", fieldLabel: "", lostValue: "原文", keptValue: "", canCopyLostValue: true))
            }
            XCTAssertEqual(store.errorMessage, "同步服务未登记或已释放")
            XCTAssertEqual(store.notice, "")
        }
    }
}

@MainActor final class SettingsFilesFake: FileTransferWorkspaceProtocol {
    var cleanups = 0
    func prepareFile(name: String) throws -> URL { URL(fileURLWithPath: name.hasSuffix("csv") ? "/owned/output.csv" : "/owned/backup.tomatobackup") }
    func prepareDirectory(name: String) throws -> URL { URL(fileURLWithPath: "/owned/export") }
    func importFile(from: URL) throws -> URL { URL(fileURLWithPath: "/owned/import.tomatobackup") }
    func cleanup() throws { cleanups += 1 }
}
@MainActor final class SettingsBackupFake: BackupBridgeProtocol {
    var onChanged: (() -> Void)?
    var onBackupCompleted: ((Bool, String) -> Void)?
    var onBackupInfoReady: ((String, BackupInfo) -> Void)?
    var onRestoreCompleted: ((Bool, String) -> Void)?
    var onRestoreStarted: (() -> Void)?
    var onRestoreCall: (() -> Void)?
    var calls: [String] = []
    var enabled = true
    func autoBackupEnabled() -> Bool { enabled }
    func setAutoBackupEnabled(_ value: Bool) throws { enabled = value }
    func snapshot() -> BackupSnapshot { BackupSnapshot() }
    func requestBackup(path: String) { calls.append("backup:\(path)") }
    func requestBackupInfo(path: String) { calls.append("inspect:\(path)") }
    func requestRestore(path: String) { calls.append("restore:\(path)"); onRestoreCall?() }
    func readBackupInfo(path: String) -> BackupInfo { BackupInfo(valid: true) }
    func readBackups() throws -> [BackupEntry] { [] }
    func suggestedBackupFileName() -> String { "backup.tomatobackup" }
    func backupFileExtension() -> String { "tomatobackup" }

}
@MainActor final class SettingsExportFake: ExportBridgeProtocol {
    var onProgress: ((Int, Int) -> Void)?
    var onCompleted: ((Bool, String) -> Void)?
    var onBusyChanged: (() -> Void)?
    var calls: [String] = []
    func isBusy() -> Bool { false }
    func exportTasks(startDate: String, endDate: String, path: String) { calls.append("tasks:\(path)") }
    func exportFocusSessions(startDate: String, endDate: String, path: String) { calls.append("focus_sessions:\(path)") }
    func exportAll(startDate: String, endDate: String, directory: String) { calls.append("all:\(directory)") }
    func generateFileName(type: String, startDate: String, endDate: String) -> String { "output.csv" }
}
@MainActor final class SettingsSyncFake: SyncBridgeProtocol {
    var onChanged: (() -> Void)?
    var onNotice: ((String) -> Void)?
    var onCopyRequested: ((String) -> Void)?
    var logs: [SyncLogEntry] = []
    var error: Error?
    var actionError: Error?
    var copied = ""
    var result = SyncSnapshot()
    var calls: [String] = []
    func snapshot() throws -> SyncSnapshot { if let error { throw error }; return result }
    func setEnabled(_ value: Bool) throws { calls.append("enabled:\(value)"); if let actionError { throw actionError } }
    func confirmJoin() throws { calls.append("join"); if let actionError { throw actionError } }
    func syncNow() throws { calls.append("sync"); if let actionError { throw actionError } }
    func chooseFolder() throws { calls.append("choose"); if let actionError { throw actionError } }
    func rebuildFolder() throws { calls.append("rebuild"); if let actionError { throw actionError } }
    func syncLog(limit: Int) throws -> [SyncLogEntry] { if let error { throw error }; return logs }
    func copyLostValue(_ text: String) throws { if let actionError { throw actionError }; copied = text; onCopyRequested?(text) }
    func restoreWarning() -> String { "" }
}
