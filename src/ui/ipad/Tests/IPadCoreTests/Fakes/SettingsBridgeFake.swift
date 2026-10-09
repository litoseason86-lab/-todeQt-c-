import IPadCore
@MainActor final class SettingsBridgeFake: SettingsBridgeProtocol {
    var result = SettingsSnapshot()
    var goal = 0
    var error: Error?
    var calls: [(String, SettingsFakeValue)] = []
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
    private func record(_ name: String, _ value: SettingsFakeValue) throws { calls.append((name, value)); if let error { throw error } }
    func snapshot() -> SettingsSnapshot { calls.append(("snapshot", .none)); return result }
    func setLastMode(_ value: Int) throws { try record("setLastMode", .integer(value)); result.lastMode = value; onLastModeChanged?() }
    func setWorkMinutes(_ value: Int) throws { try record("setWorkMinutes", .integer(value)); result.workMinutes = value; onWorkMinutesChanged?() }
    func setBreakMinutes(_ value: Int) throws { try record("setBreakMinutes", .integer(value)); result.breakMinutes = value; onBreakMinutesChanged?() }
    func setFreeTimerWarningHours(_ value: Int) throws { try record("setFreeTimerWarningHours", .integer(value)); result.freeTimerWarningHours = value; onFreeTimerWarningHoursChanged?() }
    func setSoundEnabled(_ value: Bool) throws { try record("setSoundEnabled", .boolean(value)); result.soundEnabled = value; onSoundEnabledChanged?() }
    func setReduceMotion(_ value: Bool) throws { try record("setReduceMotion", .boolean(value)); result.reduceMotion = value; onReduceMotionChanged?() }
    func setSlimClockFont(_ value: Bool) throws { try record("setSlimClockFont", .boolean(value)); result.slimClockFont = value; onSlimClockFontChanged?() }
    func setRolloverIgnoredDate(_ value: String) throws { try record("setRolloverIgnoredDate", .string(value)); result.rolloverIgnoredDate = value; onRolloverIgnoredDateChanged?() }
    func setBackgroundTheme(_ value: String) throws { try record("setBackgroundTheme", .string(value)); result.backgroundTheme = value; onBackgroundThemeChanged?() }
    func setDayStartHour(_ value: Int) throws { try record("setDayStartHour", .integer(value)); result.dayStartHour = value; onDayStartHourChanged?() }
    func setNickname(_ value: String) throws { try record("setNickname", .string(value)); result.nickname = value; onNicknameChanged?() }
    func setSidebarVisible(_ value: Bool) throws { try record("setSidebarVisible", .boolean(value)); result.sidebarVisible = value; onSidebarVisibleChanged?() }
    func setSidebarOrder(_ value: [String]) throws { try record("setSidebarOrder", .strings(value)); result.sidebarOrder = value; onSidebarOrderChanged?() }
    func setDashboardTimerVisible(_ value: Bool) throws { try record("setDashboardTimerVisible", .boolean(value)); result.dashboardTimerVisible = value; onDashboardTimerVisibleChanged?() }
    func setReduceTransparency(_ value: Bool) throws { try record("setReduceTransparency", .boolean(value)); result.reduceTransparency = value; onReduceTransparencyChanged?() }
    func setNaturalCompletionNoticeShown(_ value: Bool) throws { try record("setNaturalCompletionNoticeShown", .boolean(value)); result.naturalCompletionNoticeShown = value; onNaturalCompletionNoticeShownChanged?() }
    func setAutoStartBreak(_ value: Bool) throws { try record("setAutoStartBreak", .boolean(value)); result.autoStartBreak = value; onAutoStartBreakChanged?() }
    func setAutoStartNextPomodoro(_ value: Bool) throws { try record("setAutoStartNextPomodoro", .boolean(value)); result.autoStartNextPomodoro = value; onAutoStartNextPomodoroChanged?() }
    func setQuickStartEnabled(_ value: Bool) throws { try record("setQuickStartEnabled", .boolean(value)); result.quickStartEnabled = value; onQuickStartEnabledChanged?() }
    func setLongBreakEnabled(_ value: Bool) throws { try record("setLongBreakEnabled", .boolean(value)); result.longBreakEnabled = value; onLongBreakEnabledChanged?() }
    func setLongBreakMinutes(_ value: Int) throws { try record("setLongBreakMinutes", .integer(value)); result.longBreakMinutes = value; onLongBreakMinutesChanged?() }
    func setLongBreakInterval(_ value: Int) throws { try record("setLongBreakInterval", .integer(value)); result.longBreakInterval = value; onLongBreakIntervalChanged?() }
    func setScheduleDisplayMode(_ value: String) throws { try record("setScheduleDisplayMode", .string(value)); result.scheduleDisplayMode = value; onScheduleDisplayModeChanged?() }
    func resetSidebarOrder() throws { try record("resetSidebarOrder", .none) }
    func dailyFocusGoal(date: String) -> Int { calls.append(("dailyFocusGoal", .string(date))); return goal }
    func setDailyFocusGoal(date: String, minutes: Int) throws { try record("setDailyFocusGoal", .goal(date, minutes)); goal = minutes; onDailyFocusGoalChanged?() }
}
enum SettingsFakeValue: Equatable { case none, integer(Int), boolean(Bool), string(String), strings([String]), goal(String, Int) }
