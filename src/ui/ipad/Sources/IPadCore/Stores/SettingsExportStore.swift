import Foundation
import Observation

public enum ExportKind: String, CaseIterable, Sendable { case tasks, focus = "focus_sessions", all }
@MainActor @Observable public final class SettingsExportStore {
    public var startDate = "2020-01-01"
    public var endDate: String
    public private(set) var busy = false
    public private(set) var progress = 0
    public private(set) var total = 0
    public private(set) var exportURL: URL?
    public private(set) var kind = ExportKind.tasks
    public private(set) var errorMessage = ""
    public private(set) var notice = ""
    @ObservationIgnored private let bridge: any ExportBridgeProtocol
    @ObservationIgnored private let files: any FileTransferWorkspaceProtocol
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private var localURL: URL?
    @ObservationIgnored private var working = false
    public init(bridge: any ExportBridgeProtocol, files: any FileTransferWorkspaceProtocol, logicalDay: any LogicalDayBridgeProtocol) {
        self.bridge = bridge; self.files = files; self.logicalDay = logicalDay; endDate = logicalDay.today
        bridge.onProgress = { [weak self] current, total in self?.progress = current; self?.total = total }
        bridge.onBusyChanged = { [weak self] in self?.busy = self?.bridge.isBusy() ?? false }
        bridge.onCompleted = { [weak self] in self?.completed($0, message: $1) }
    }
    public func selectRange(_ range: String) {
        do {
            let period = try logicalDay.period(anchor: logicalDay.today, range: range, shift: 0, logicalToday: logicalDay.today)
            startDate = period.start; endDate = logicalDay.today; errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }
    public func start(_ kind: ExportKind) {
        guard !busy && !working && exportURL == nil else { return }
        self.kind = kind; progress = 0; total = 0; errorMessage = ""; notice = ""
        do {
            let url: URL
            if kind == .all { url = try files.prepareDirectory(name: "番茄Todo导出") }
            else { url = try files.prepareFile(name: bridge.generateFileName(type: kind.rawValue, startDate: startDate, endDate: endDate)) }
            localURL = url; working = true; busy = true
            switch kind {
            case .tasks: bridge.exportTasks(startDate: startDate, endDate: endDate, path: url.path)
            case .focus: bridge.exportFocusSessions(startDate: startDate, endDate: endDate, path: url.path)
            case .all: bridge.exportAll(startDate: startDate, endDate: endDate, directory: url.path)
            }
        } catch { errorMessage = error.localizedDescription; releaseFiles() }
    }
    private func completed(_ success: Bool, message: String) {
        guard working else { return }
        working = false; busy = bridge.isBusy()
        if success { exportURL = localURL; notice = message }
        else { errorMessage = message; releaseFiles() }
    }
    public func finishExport(error: Error?) {
        // 系统保存只在服务生成成功后出现；生成期间没有可取消的系统导出会话。
        guard !working && exportURL != nil else { return }
        if let error {
            let value = error as NSError
            if value.domain != NSCocoaErrorDomain || value.code != NSUserCancelledError { errorMessage = error.localizedDescription }
        }
        exportURL = nil; releaseFiles()
    }
    private func releaseFiles() {
        do { try files.cleanup(); localURL = nil; exportURL = nil }
        catch { errorMessage += (errorMessage.isEmpty ? "" : "\n") + "临时文件清理失败：" + error.localizedDescription }
        busy = bridge.isBusy()
    }
}
