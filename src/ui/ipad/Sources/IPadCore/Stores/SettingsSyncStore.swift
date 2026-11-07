import Foundation
import Observation

@MainActor @Observable public final class SettingsSyncStore {
    public private(set) var snapshot = SyncSnapshot()
    public private(set) var logs: [SyncLogEntry] = []
    public private(set) var errorMessage = ""
    public private(set) var notice = ""
    public private(set) var pairingSheetRequested = false
    @ObservationIgnored private let bridge: any SyncBridgeProtocol
    @ObservationIgnored private var pairingJoinStarted = false
    public init(bridge: any SyncBridgeProtocol) {
        self.bridge = bridge
        bridge.onChanged = { [weak self] in self?.refresh(); self?.reloadLogs() }
        bridge.onNotice = { [weak self] in self?.notice = $0 }
        bridge.onCopyRequested = { [weak self] _ in self?.notice = "已复制丢失值" }
        refresh()
    }
    public var folderActionTitle: String { snapshot.hasFolder ? "重新选择文件夹" : "选择同步文件夹" }
    public var pendingText: String { "\(snapshot.pendingCount) 项" }
    public var isServerTransport: Bool { snapshot.transport == "server" }
    public var transportProblem: String { snapshot.transportProblem }
    public var joinWarningText: String { bridge.joinWarning() }
    public var joinTitle: String {
        isServerTransport ? "加入同步空间？" : "加入同步文件夹？"
    }
    public var joinConfirmationText: String {
        let base = isServerTransport
            ? "本机数据先自动备份，再换成 Mac 的数据。"
            : "本机数据先自动备份，再换成同步文件夹里的数据。"
        let warning = joinWarningText
        return warning.isEmpty ? base : base + "\n" + warning
    }
    public func canSubmitPairingCode(_ code: String) -> Bool {
        !snapshot.switchingTransport && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public func refresh() {
        do {
            snapshot = try bridge.snapshot()
            errorMessage = ""
            // 重新配对失败后 transport 仍可能是旧的 server；必须等本次切换结束且无问题，
            // 才能关表单，格式错误和网络失败都留在表单里供用户修正重试。
            if pairingJoinStarted && isServerTransport && !snapshot.switchingTransport
                && snapshot.transportProblem.isEmpty {
                pairingSheetRequested = false
                pairingJoinStarted = false
            }
        }
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
    public func requestPairingSheet() { pairingSheetRequested = true }
    public func cancelPairingSheet() {
        pairingSheetRequested = false
        pairingJoinStarted = false
    }
    public func selectTransport(_ transport: String) {
        if transport == "server" {
            if !isServerTransport { requestPairingSheet() }
            return
        }
        guard transport == "icloud", isServerTransport else { return }
        perform { try bridge.switchToICloud() }
    }
    public func submitPairingCode(_ code: String) {
        guard canSubmitPairingCode(code) else { return }
        pairingJoinStarted = true
        do {
            try bridge.joinWithPairingCode(code)
            refresh()
        } catch {
            pairingJoinStarted = false
            errorMessage = error.localizedDescription
        }
    }
    public func switchToICloud() { perform { try bridge.switchToICloud() } }
    public func copy(_ entry: SyncLogEntry) {
        guard entry.canCopyLostValue else { return }
        perform { try bridge.copyLostValue(entry.lostValue) }
    }
}
