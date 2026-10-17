import Foundation
import Observation

@MainActor @Observable public final class SettingsSyncStore {
    public private(set) var snapshot = SyncSnapshot()
    public private(set) var logs: [SyncLogEntry] = []
    public private(set) var errorMessage = ""
    public private(set) var notice = ""
    @ObservationIgnored private let bridge: any SyncBridgeProtocol
    public init(bridge: any SyncBridgeProtocol) {
        self.bridge = bridge
        bridge.onChanged = { [weak self] in self?.refresh(); self?.reloadLogs() }
        bridge.onNotice = { [weak self] in self?.notice = $0 }
        bridge.onCopyRequested = { [weak self] _ in self?.notice = "已复制丢失值" }
        refresh()
    }
    public var folderActionTitle: String { snapshot.hasFolder ? "重新选择文件夹" : "选择同步文件夹" }
    public var pendingText: String { "\(snapshot.pendingCount) 项" }
    public func refresh() {
        do { snapshot = try bridge.snapshot(); errorMessage = "" }
        catch { errorMessage = error.localizedDescription }
    }
    public func reloadLogs() {
        do { logs = try bridge.syncLog(limit: 200); errorMessage = "" }
        catch { errorMessage = error.localizedDescription }
    }
    // 桥接拒绝派发时显示本次原因；已派发动作的进度和失败仍由原通知与状态承接。
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
    public func setEnabled(_ enabled: Bool) {
        do { try bridge.setEnabled(enabled); refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    public func confirmJoin() { perform { try bridge.confirmJoin() } }
    public func syncNow() { perform { try bridge.syncNow() } }
    public func chooseFolder() { perform { try bridge.chooseFolder() } }
    public func rebuildFolder() { perform { try bridge.rebuildFolder() } }
    public func copy(_ entry: SyncLogEntry) {
        guard entry.canCopyLostValue else { return }
        perform { try bridge.copyLostValue(entry.lostValue) }
    }
}
