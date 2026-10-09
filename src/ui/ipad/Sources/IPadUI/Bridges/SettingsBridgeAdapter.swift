import IPadCore
import PTBridge
@MainActor final class SettingsBridgeAdapter: SettingsBridgeProtocol {
    private let native = PTSettingsBridge()
    var onWriteSucceeded: ((String) -> Void)?
    var onWriteFailed: ((String, String) -> Void)?
    var onLastModeChanged: (() -> Void)?
    var onWorkMinutesChanged: (() -> Void)?
    var onBreakMinutesChanged: (() -> Void)?
    var onFreeTimerWarningHoursChanged: (() -> Void)?
    var onSoundEnabledChanged: (() -> Void)?
    var onReduceMotionChanged: (() -> Void)?
    var onSlimClockFontChanged: (() -> Void)?
    var onRolloverIgnoredDateChanged: (() -> Void)?
    var onBackgroundThemeChanged: (() -> Void)?
    var onDayStartHourChanged: (() -> Void)?
    var onNicknameChanged: (() -> Void)?
    var onSidebarVisibleChanged: (() -> Void)?
    var onSidebarOrderChanged: (() -> Void)?
    var onSidebarOrderIsDefaultChanged: (() -> Void)?
    var onDashboardTimerVisibleChanged: (() -> Void)?
    var onReduceTransparencyChanged: (() -> Void)?
    var onNaturalCompletionNoticeShownChanged: (() -> Void)?
    var onAutoStartBreakChanged: (() -> Void)?
    var onAutoStartNextPomodoroChanged: (() -> Void)?
    var onQuickStartEnabledChanged: (() -> Void)?
    var onLongBreakEnabledChanged: (() -> Void)?
    var onLongBreakMinutesChanged: (() -> Void)?
    var onLongBreakIntervalChanged: (() -> Void)?
    var onSemesterStartDateChanged: (() -> Void)?
    var onSemesterWeeksChanged: (() -> Void)?
    var onScheduleDisplayModeChanged: (() -> Void)?
    var onScheduleShowWeekendChanged: (() -> Void)?
    var onDailyFocusGoalChanged: (() -> Void)?
    init() {
        // Qt 上下文保证在主线程回调，Swift 只转发变化，不复写设置归一化规则。
        native.onWriteSucceeded = { [weak self] key in MainActor.assumeIsolated { self?.onWriteSucceeded?(key) } }
        native.onWriteFailed = { [weak self] key, message in MainActor.assumeIsolated { self?.onWriteFailed?(key, message) } }
        native.onLastModeChanged = { [weak self] in MainActor.assumeIsolated { self?.onLastModeChanged?() } }
        native.onWorkMinutesChanged = { [weak self] in MainActor.assumeIsolated { self?.onWorkMinutesChanged?() } }
        native.onBreakMinutesChanged = { [weak self] in MainActor.assumeIsolated { self?.onBreakMinutesChanged?() } }
        native.onFreeTimerWarningHoursChanged = { [weak self] in MainActor.assumeIsolated { self?.onFreeTimerWarningHoursChanged?() } }
        native.onSoundEnabledChanged = { [weak self] in MainActor.assumeIsolated { self?.onSoundEnabledChanged?() } }
        native.onReduceMotionChanged = { [weak self] in MainActor.assumeIsolated { self?.onReduceMotionChanged?() } }
        native.onSlimClockFontChanged = { [weak self] in MainActor.assumeIsolated { self?.onSlimClockFontChanged?() } }
        native.onRolloverIgnoredDateChanged = { [weak self] in MainActor.assumeIsolated { self?.onRolloverIgnoredDateChanged?() } }
        native.onBackgroundThemeChanged = { [weak self] in MainActor.assumeIsolated { self?.onBackgroundThemeChanged?() } }
        native.onDayStartHourChanged = { [weak self] in MainActor.assumeIsolated { self?.onDayStartHourChanged?() } }
        native.onNicknameChanged = { [weak self] in MainActor.assumeIsolated { self?.onNicknameChanged?() } }
        native.onSidebarVisibleChanged = { [weak self] in MainActor.assumeIsolated { self?.onSidebarVisibleChanged?() } }
        native.onSidebarOrderChanged = { [weak self] in MainActor.assumeIsolated { self?.onSidebarOrderChanged?() } }
        native.onSidebarOrderIsDefaultChanged = { [weak self] in MainActor.assumeIsolated { self?.onSidebarOrderIsDefaultChanged?() } }
        native.onDashboardTimerVisibleChanged = { [weak self] in MainActor.assumeIsolated { self?.onDashboardTimerVisibleChanged?() } }
        native.onReduceTransparencyChanged = { [weak self] in MainActor.assumeIsolated { self?.onReduceTransparencyChanged?() } }
        native.onNaturalCompletionNoticeShownChanged = { [weak self] in MainActor.assumeIsolated { self?.onNaturalCompletionNoticeShownChanged?() } }
        native.onAutoStartBreakChanged = { [weak self] in MainActor.assumeIsolated { self?.onAutoStartBreakChanged?() } }
        native.onAutoStartNextPomodoroChanged = { [weak self] in MainActor.assumeIsolated { self?.onAutoStartNextPomodoroChanged?() } }
        native.onQuickStartEnabledChanged = { [weak self] in MainActor.assumeIsolated { self?.onQuickStartEnabledChanged?() } }
        native.onLongBreakEnabledChanged = { [weak self] in MainActor.assumeIsolated { self?.onLongBreakEnabledChanged?() } }
        native.onLongBreakMinutesChanged = { [weak self] in MainActor.assumeIsolated { self?.onLongBreakMinutesChanged?() } }
        native.onLongBreakIntervalChanged = { [weak self] in MainActor.assumeIsolated { self?.onLongBreakIntervalChanged?() } }
        native.onSemesterStartDateChanged = { [weak self] in MainActor.assumeIsolated { self?.onSemesterStartDateChanged?() } }
        native.onSemesterWeeksChanged = { [weak self] in MainActor.assumeIsolated { self?.onSemesterWeeksChanged?() } }
        native.onScheduleDisplayModeChanged = { [weak self] in MainActor.assumeIsolated { self?.onScheduleDisplayModeChanged?() } }
        native.onScheduleShowWeekendChanged = { [weak self] in MainActor.assumeIsolated { self?.onScheduleShowWeekendChanged?() } }
        native.onDailyFocusGoalChanged = { [weak self] in MainActor.assumeIsolated { self?.onDailyFocusGoalChanged?() } }
    }
    func snapshot() -> SettingsSnapshot {
        let item = native.snapshot(); var value = SettingsSnapshot()
        value.lastMode = item.lastMode
        value.workMinutes = item.workMinutes
        value.breakMinutes = item.breakMinutes
        value.freeTimerWarningHours = item.freeTimerWarningHours
        value.soundEnabled = item.soundEnabled
        value.reduceMotion = item.reduceMotion
        value.slimClockFont = item.slimClockFont
        value.rolloverIgnoredDate = item.rolloverIgnoredDate
        value.backgroundTheme = item.backgroundTheme
        value.dayStartHour = item.dayStartHour
        value.nickname = item.nickname
        value.sidebarVisible = item.sidebarVisible
        value.sidebarOrder = item.sidebarOrder
        value.sidebarOrderIsDefault = item.sidebarOrderIsDefault
        value.dashboardTimerVisible = item.dashboardTimerVisible
        value.reduceTransparency = item.reduceTransparency
        value.naturalCompletionNoticeShown = item.naturalCompletionNoticeShown
        value.autoStartBreak = item.autoStartBreak
        value.autoStartNextPomodoro = item.autoStartNextPomodoro
        value.quickStartEnabled = item.quickStartEnabled
        value.longBreakEnabled = item.longBreakEnabled
        value.longBreakMinutes = item.longBreakMinutes
        value.longBreakInterval = item.longBreakInterval
        value.semesterStartDate = item.semesterStartDate
        value.semesterWeeks = item.semesterWeeks
        value.scheduleDisplayMode = item.scheduleDisplayMode
        value.scheduleShowWeekend = item.scheduleShowWeekend
        return value
    }
    func setLastMode(_ value: Int) throws { try native.setLastMode(value) }
    func setWorkMinutes(_ value: Int) throws { try native.setWorkMinutes(value) }
    func setBreakMinutes(_ value: Int) throws { try native.setBreakMinutes(value) }
    func setFreeTimerWarningHours(_ value: Int) throws { try native.setFreeTimerWarningHours(value) }
    func setSoundEnabled(_ value: Bool) throws { try native.setSoundEnabled(value) }
    func setReduceMotion(_ value: Bool) throws { try native.setReduceMotion(value) }
    func setSlimClockFont(_ value: Bool) throws { try native.setSlimClockFont(value) }
    func setRolloverIgnoredDate(_ value: String) throws { try native.setRolloverIgnoredDate(value) }
    func setBackgroundTheme(_ value: String) throws { try native.setBackgroundTheme(value) }
    func setDayStartHour(_ value: Int) throws { try native.setDayStartHour(value) }
    func setNickname(_ value: String) throws { try native.setNickname(value) }
    func setSidebarVisible(_ value: Bool) throws { try native.setSidebarVisible(value) }
    func setSidebarOrder(_ value: [String]) throws { try native.setSidebarOrder(value) }
    func setDashboardTimerVisible(_ value: Bool) throws { try native.setDashboardTimerVisible(value) }
    func setReduceTransparency(_ value: Bool) throws { try native.setReduceTransparency(value) }
    func setNaturalCompletionNoticeShown(_ value: Bool) throws { try native.setNaturalCompletionNoticeShown(value) }
    func setAutoStartBreak(_ value: Bool) throws { try native.setAutoStartBreak(value) }
    func setAutoStartNextPomodoro(_ value: Bool) throws { try native.setAutoStartNextPomodoro(value) }
    func setQuickStartEnabled(_ value: Bool) throws { try native.setQuickStartEnabled(value) }
    func setLongBreakEnabled(_ value: Bool) throws { try native.setLongBreakEnabled(value) }
    func setLongBreakMinutes(_ value: Int) throws { try native.setLongBreakMinutes(value) }
    func setLongBreakInterval(_ value: Int) throws { try native.setLongBreakInterval(value) }
    func setScheduleDisplayMode(_ value: String) throws { try native.setScheduleDisplayMode(value) }
    func resetSidebarOrder() throws { try native.resetSidebarOrder() }
    func dailyFocusGoal(date: String) -> Int { native.dailyFocusGoal(date) }
    func setDailyFocusGoal(date: String, minutes: Int) throws { try native.setDailyFocusGoal(date, minutes: minutes) }
}
