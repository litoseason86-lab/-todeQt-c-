import Foundation
import Observation

@MainActor @Observable public final class SettingsStore {
    public private(set) var snapshot = SettingsSnapshot()
    public private(set) var errorMessage = ""
    @ObservationIgnored private let bridge: any SettingsBridgeProtocol

    public init(bridge: any SettingsBridgeProtocol) {
        self.bridge = bridge
        bridge.onWriteFailed = { [weak self] _, message in self?.writeFailed(message) }
        bridge.onWriteSucceeded = { [weak self] _ in self?.refresh() }
        refresh()
    }
    public func refresh() { snapshot = bridge.snapshot() }
    private func writeFailed(_ message: String) { refresh(); errorMessage = message }
    private func write(_ operation: () throws -> Void) {
        let previous = snapshot
        do { try operation(); refresh(); errorMessage = "" }
        catch { snapshot = previous; errorMessage = error.localizedDescription }
    }
    public func setWorkMinutes(_ value: Int) { write { try bridge.setWorkMinutes(value) } }
    public func setBreakMinutes(_ value: Int) { write { try bridge.setBreakMinutes(value) } }
    public func setDayStartHour(_ value: Int) { write { try bridge.setDayStartHour(value) } }
    public func setBackgroundTheme(_ value: String) { write { try bridge.setBackgroundTheme(value) } }
    public func setSidebarOrder(_ value: [PageID]) {
        let order = value.filter { !PageID.fixed.contains($0) }.map(\.rawValue)
        write { try bridge.setSidebarOrder(order) }
    }
    public func resetSidebarOrder() { write { try bridge.resetSidebarOrder() } }
}
