import Foundation
public struct BackupSnapshot: Equatable, Sendable {
    public var lastBackupTimeIso = ""
    public var busy = false
    public var operationBlocksUI = false
    public var operationText = ""
    public var lastError = ""
    public init() {}
}
public struct BackupInfo: Equatable, Sendable {
    public var valid: Bool
    public var reason: String
    public var createdAt: String
    public var appVersion: String
    public var taskCount: Int
    public var sessionCount: Int
    public init(valid: Bool, reason: String = "", createdAt: String = "", appVersion: String = "", taskCount: Int = 0, sessionCount: Int = 0) {
        self.valid = valid; self.reason = reason; self.createdAt = createdAt; self.appVersion = appVersion
        self.taskCount = taskCount; self.sessionCount = sessionCount
    }
}
public struct BackupEntry: Equatable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public let modified: String
    public let sizeBytes: Int64
    public var id: String { path }
    public init(path: String, name: String, modified: String, sizeBytes: Int64) {
        self.path = path; self.name = name; self.modified = modified; self.sizeBytes = sizeBytes
    }
}
@MainActor public protocol BackupBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var onBackupCompleted: ((Bool, String) -> Void)? { get set }
    var onBackupInfoReady: ((String, BackupInfo) -> Void)? { get set }
    var onRestoreCompleted: ((Bool, String) -> Void)? { get set }
    var onRestoreStarted: (() -> Void)? { get set }
    func autoBackupEnabled() -> Bool
    func setAutoBackupEnabled(_ value: Bool) throws
    func snapshot() -> BackupSnapshot
    func requestBackup(path: String)
    func requestBackupInfo(path: String)
    func requestRestore(path: String)
    func readBackupInfo(path: String) -> BackupInfo
    func readBackups() throws -> [BackupEntry]
    func suggestedBackupFileName() -> String
    func backupFileExtension() -> String
}
