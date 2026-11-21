import Foundation
import Observation

@MainActor @Observable public final class SettingsSyncStore {
    public private(set) var snapshot = SyncSnapshot()
    public private(set) var logs: [SyncLogEntry] = []
    public private(set) var errorMessage = ""
    public private(set) var notice = ""
    public private(set) var pairingSheetRequested = false
    @ObservationIgnored private let bridge: any SyncBridgeProtocol
    @ObservationIgnored private let flushEdits: () -> Bool
    @ObservationIgnored private let commitPending: () -> Bool
    @ObservationIgnored private var pairingJoinStarted = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var logsActive = false
    @ObservationIgnored private var needsRefresh = true
    @ObservationIgnored private var needsLogsReload = true
    // 记录最近一次成功读取日志时的服务端 logRevision；普通状态变化不改变该版本号，避免重读 200 条日志。
    @ObservationIgnored private var loadedLogRevision: Int?
    public init(bridge: any SyncBridgeProtocol, flushEdits: @escaping () -> Bool = { true }, commitPending: @escaping () -> Bool = { true }) {
        self.bridge = bridge; self.flushEdits = flushEdits; self.commitPending = commitPending
        // 非活跃态只记待刷新标记，避免每次同步状态跳动都在后台重查快照和 200 条冲突日志。
        bridge.onChanged = { [weak self] in
            guard let self else { return }
            if self.active || self.logsActive || self.pairingSheetRequested {
                self.refresh()
                let logsStale = self.loadedLogRevision == nil || self.snapshot.logRevision != self.loadedLogRevision
                if self.logsActive {
                    if logsStale { self.reloadLogs() }
                } else if logsStale {
                    self.needsLogsReload = true
                }
            } else {
                self.needsRefresh = true
                self.needsLogsReload = true
            }
        }
        bridge.onNotice = { [weak self] in self?.notice = $0 }
        bridge.onCopyRequested = { [weak self] _ in self?.notice = "已复制丢失值" }
    }
    public func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value && needsRefresh { refresh() }
    }
    public func setLogsActive(_ value: Bool) {
        guard logsActive != value else { return }
        logsActive = value
        if value {
            if needsRefresh { refresh() }
            if needsLogsReload && (loadedLogRevision == nil || snapshot.logRevision != loadedLogRevision) {
                reloadLogs()
            } else {
                needsLogsReload = false
            }
        }
    }
    public func prepareForRestore() {
        loadedLogRevision = nil
        needsRefresh = true
        needsLogsReload = true
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
        needsRefresh = false
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
        needsLogsReload = false
        do {
            logs = try bridge.syncLog(limit: 200)
            loadedLogRevision = snapshot.logRevision
            errorMessage = ""
        }
        catch { errorMessage = error.localizedDescription }
    }
    // 提示只属于当前页面和本次动作；清理在动作开始前完成，不能抹掉动作回调刚送来的新提示。
    public func clearNotice() { notice = "" }
    private func flushBeforeCriticalSyncAction() -> Bool {
        guard flushEdits() else { errorMessage = "备忘录还有未保存的修改，请先回备忘录处理"; return false }
        guard commitPending() else { errorMessage = "待删项提交失败，加入同步已取消"; return false }
        return true
    }
    // 桥接拒绝派发时显示本次原因；已派发动作的进度和失败仍由原通知与状态承接。
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
    public func setEnabled(_ enabled: Bool) {
        clearNotice()
        do { try bridge.setEnabled(enabled); refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    public func confirmJoin() {
        clearNotice()
        guard flushBeforeCriticalSyncAction() else { return }
        perform { try bridge.confirmJoin() }
    }
    public func syncNow() { clearNotice(); perform { try bridge.syncNow() } }
    public func chooseFolder() { clearNotice(); perform { try bridge.chooseFolder() } }
    public func rebuildFolder() {
        clearNotice()
        guard flushBeforeCriticalSyncAction() else { return }
        perform { try bridge.rebuildFolder() }
    }
    public func requestPairingSheet() {
        // 清理命令可能同步通知；显式刷新也保证未发通知时快照立即更新。
        bridge.clearTransportProblem()
        refresh()
        pairingSheetRequested = true
    }
    public func cancelPairingSheet() {
        let shouldCancelSwitch = pairingJoinStarted || snapshot.switchingTransport
        pairingSheetRequested = false
        pairingJoinStarted = false
        // 配对连接进行中点取消必须通知 C++ 撤销在途切换并作废迟到回调，保留原有传输方式与 iCloud 书签。
        if shouldCancelSwitch { bridge.cancelTransportSwitch() }
        bridge.clearTransportProblem()
        refresh()
    }
    public func selectTransport(_ transport: String) {
        clearNotice()
        if transport == "server" {
            if !isServerTransport { requestPairingSheet() }
            return
        }
        guard transport == "icloud", isServerTransport else { return }
        guard flushBeforeCriticalSyncAction() else { return }
        perform { try bridge.switchToICloud() }
    }
    public func submitPairingCode(_ code: String) {
        clearNotice()
        guard canSubmitPairingCode(code) else { return }
        guard flushBeforeCriticalSyncAction() else { return }
        pairingJoinStarted = true
        do {
            try bridge.joinWithPairingCode(code)
            refresh()
        } catch {
            pairingJoinStarted = false
            errorMessage = error.localizedDescription
        }
    }
    public func switchToICloud() {
        clearNotice()
        guard flushBeforeCriticalSyncAction() else { return }
        perform { try bridge.switchToICloud() }
    }
    public func copy(_ entry: SyncLogEntry) {
        clearNotice()
        guard entry.canCopyLostValue else { return }
        perform { try bridge.copyLostValue(entry.lostValue) }
    }
}
