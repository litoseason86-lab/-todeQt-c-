import Foundation
import IPadCore
import PTBridge
@MainActor final class ExportBridgeAdapter: ExportBridgeProtocol {
    private let native = PTExportBridge(); var onProgress: ((Int, Int) -> Void)?; var onCompleted: ((Bool, String) -> Void)?; var onBusyChanged: (() -> Void)?
    init() { native.onProgress = { [weak self] a, b in MainActor.assumeIsolated { self?.onProgress?(a, b) } }; native.onCompleted = { [weak self] ok, text in MainActor.assumeIsolated { self?.onCompleted?(ok, text) } }; native.onBusyChanged = { [weak self] in MainActor.assumeIsolated { self?.onBusyChanged?() } } }
    func isBusy() -> Bool { native.busy }; func exportTasks(startDate: String, endDate: String, path: String) { native.exportTasks(from: startDate, to: endDate, path: path) }; func exportFocusSessions(startDate: String, endDate: String, path: String) { native.exportFocusSessions(from: startDate, to: endDate, path: path) }; func exportAll(startDate: String, endDate: String, directory: String) { native.exportAll(from: startDate, to: endDate, directory: directory) }; func generateFileName(type: String, startDate: String, endDate: String) -> String { native.generateFileName(type, startDate: startDate, endDate: endDate) }
}
