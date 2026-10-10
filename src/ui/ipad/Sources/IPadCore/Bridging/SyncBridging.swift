import Foundation
public struct SyncSnapshot: Equatable, Sendable { public var enabled = false; public var statusKey = ""; public var hasProblem = false; public var summaryText = ""; public var statusText = ""; public var statusDetail = ""; public var pendingCount = 0; public var lastSyncedAt = ""; public var busy = false; public var hasFolder = false; public var folderDisplayPath = ""; public var choosingFolder = false; public var folderProblem = ""; public var logRevision = 0; public var logCount = 0; public init() {} }
public struct SyncLogEntry: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let kind: String
    public let kindLabel: String
    public let time: String
    public let title: String
    public let summary: String
    public let detail: String
    public let fieldLabel: String
    public let lostValue: String
    public let keptValue: String
    public init(id: Int64, kind: String, kindLabel: String, time: String, title: String,
                summary: String, detail: String, fieldLabel: String, lostValue: String, keptValue: String) {
        self.id = id; self.kind = kind; self.kindLabel = kindLabel; self.time = time; self.title = title
        self.summary = summary; self.detail = detail; self.fieldLabel = fieldLabel; self.lostValue = lostValue; self.keptValue = keptValue
    }
}
@MainActor public protocol SyncBridgeProtocol: AnyObject { var onChanged: (() -> Void)? { get set }; var onNotice: ((String) -> Void)? { get set }; var onCopyRequested: ((String) -> Void)? { get set }; func snapshot() -> SyncSnapshot; func setEnabled(_ value: Bool); func confirmJoin(); func syncNow(); func chooseFolder(); func rebuildFolder(); func syncLog(limit: Int) throws -> [SyncLogEntry]; func copyLostValue(_ text: String); func restoreWarning() -> String }
