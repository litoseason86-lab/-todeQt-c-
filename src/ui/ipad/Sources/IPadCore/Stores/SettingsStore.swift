import Foundation
import Observation

@MainActor @Observable public final class SettingsStore {
    public private(set) var snapshot = SettingsSnapshot()
    public private(set) var errorMessage = ""
    @ObservationIgnored private let bridge: any SettingsBridgeProtocol

    public init(bridge: any SettingsBridgeProtocol) {
        self.bridge = bridge
        bridge.onWriteFailed = { [weak self] _, message in self?.writeFailed(message) }
        bridge.onWriteSucceeded = { [weak self] _ in self?.writeSucceeded() }
        // 使用根装配提供的专用适配器，外部设置变化不占用专注页的单回调槽。
        bridge.onWorkMinutesChanged = { [weak self] in self?.refresh() }
        bridge.onBreakMinutesChanged = { [weak self] in self?.refresh() }
        bridge.onFreeTimerWarningHoursChanged = { [weak self] in self?.refresh() }
        bridge.onSoundEnabledChanged = { [weak self] in self?.refresh() }
        bridge.onSlimClockFontChanged = { [weak self] in self?.refresh() }
        bridge.onBackgroundThemeChanged = { [weak self] in self?.refresh() }
        bridge.onDayStartHourChanged = { [weak self] in self?.refresh() }
        bridge.onNicknameChanged = { [weak self] in self?.refresh() }
        bridge.onSidebarOrderChanged = { [weak self] in self?.refresh() }
        bridge.onSidebarOrderIsDefaultChanged = { [weak self] in self?.refresh() }
        bridge.onDashboardTimerVisibleChanged = { [weak self] in self?.refresh() }
        bridge.onAutoStartBreakChanged = { [weak self] in self?.refresh() }
        bridge.onAutoStartNextPomodoroChanged = { [weak self] in self?.refresh() }
        bridge.onQuickStartEnabledChanged = { [weak self] in self?.refresh() }
        bridge.onLongBreakEnabledChanged = { [weak self] in self?.refresh() }
        bridge.onLongBreakMinutesChanged = { [weak self] in self?.refresh() }
        bridge.onLongBreakIntervalChanged = { [weak self] in self?.refresh() }
        refresh()
    }
    public func refresh() { snapshot = bridge.snapshot() }
    private func writeSucceeded() { refresh(); errorMessage = "" }
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
    public func setFreeTimerWarningHours(_ value: Int) { write { try bridge.setFreeTimerWarningHours(value) } }
    public func setSoundEnabled(_ value: Bool) { write { try bridge.setSoundEnabled(value) } }
    public func setSlimClockFont(_ value: Bool) { write { try bridge.setSlimClockFont(value) } }
    public func setNickname(_ value: String) { write { try bridge.setNickname(value) } }
    public func setDashboardTimerVisible(_ value: Bool) { write { try bridge.setDashboardTimerVisible(value) } }
    public func setAutoStartBreak(_ value: Bool) { write { try bridge.setAutoStartBreak(value) } }
    public func setAutoStartNextPomodoro(_ value: Bool) { write { try bridge.setAutoStartNextPomodoro(value) } }
    public func setQuickStartEnabled(_ value: Bool) { write { try bridge.setQuickStartEnabled(value) } }
    public func setLongBreakEnabled(_ value: Bool) { write { try bridge.setLongBreakEnabled(value) } }
    public func setLongBreakMinutes(_ value: Int) { write { try bridge.setLongBreakMinutes(value) } }
    public func setLongBreakInterval(_ value: Int) { write { try bridge.setLongBreakInterval(value) } }
    public func setSidebarOrder(_ value: [PageID]) {
        let order = value.filter { !PageID.fixed.contains($0) }.map(\.rawValue)
        write { try bridge.setSidebarOrder(order) }
    }
    public func resetSidebarOrder() { write { try bridge.resetSidebarOrder() } }
}
