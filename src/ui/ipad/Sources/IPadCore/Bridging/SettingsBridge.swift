import Foundation
public struct SettingsSnapshot: Equatable, Sendable {
    public var lastMode: Int = 0
    public var workMinutes: Int = 0
    public var breakMinutes: Int = 0
    public var freeTimerWarningHours: Int = 0
    public var soundEnabled: Bool = false
    public var reduceMotion: Bool = false
    public var slimClockFont: Bool = false
    public var rolloverIgnoredDate: String = ""
    public var backgroundTheme: String = ""
    public var dayStartHour: Int = 0
    public var nickname: String = ""
    public var sidebarVisible: Bool = false
    public var sidebarOrder: [String] = []
    public var sidebarOrderIsDefault: Bool = false
    public var dashboardTimerVisible: Bool = false
    public var reduceTransparency: Bool = false
    public var naturalCompletionNoticeShown: Bool = false
    public var autoStartBreak: Bool = false
    public var autoStartNextPomodoro: Bool = false
    public var quickStartEnabled: Bool = false
    public var longBreakEnabled: Bool = false
    public var longBreakMinutes: Int = 0
    public var longBreakInterval: Int = 0
    public var semesterStartDate: String = ""
    public var semesterWeeks: Int = 0
    public var scheduleDisplayMode: String = ""
    public var scheduleShowWeekend: Bool = false
    public init() {}
}
@MainActor public protocol SettingsBridgeProtocol: AnyObject {
    var onWriteSucceeded: ((String) -> Void)? { get set }
    var onWriteFailed: ((String, String) -> Void)? { get set }
    var onLastModeChanged: (() -> Void)? { get set }
    var onWorkMinutesChanged: (() -> Void)? { get set }
    var onBreakMinutesChanged: (() -> Void)? { get set }
    var onFreeTimerWarningHoursChanged: (() -> Void)? { get set }
    var onSoundEnabledChanged: (() -> Void)? { get set }
    var onReduceMotionChanged: (() -> Void)? { get set }
    var onSlimClockFontChanged: (() -> Void)? { get set }
    var onRolloverIgnoredDateChanged: (() -> Void)? { get set }
    var onBackgroundThemeChanged: (() -> Void)? { get set }
    var onDayStartHourChanged: (() -> Void)? { get set }
    var onNicknameChanged: (() -> Void)? { get set }
    var onSidebarVisibleChanged: (() -> Void)? { get set }
    var onSidebarOrderChanged: (() -> Void)? { get set }
    var onSidebarOrderIsDefaultChanged: (() -> Void)? { get set }
    var onDashboardTimerVisibleChanged: (() -> Void)? { get set }
    var onReduceTransparencyChanged: (() -> Void)? { get set }
    var onNaturalCompletionNoticeShownChanged: (() -> Void)? { get set }
    var onAutoStartBreakChanged: (() -> Void)? { get set }
    var onAutoStartNextPomodoroChanged: (() -> Void)? { get set }
    var onQuickStartEnabledChanged: (() -> Void)? { get set }
    var onLongBreakEnabledChanged: (() -> Void)? { get set }
    var onLongBreakMinutesChanged: (() -> Void)? { get set }
    var onLongBreakIntervalChanged: (() -> Void)? { get set }
    var onSemesterStartDateChanged: (() -> Void)? { get set }
    var onSemesterWeeksChanged: (() -> Void)? { get set }
    var onScheduleDisplayModeChanged: (() -> Void)? { get set }
    var onScheduleShowWeekendChanged: (() -> Void)? { get set }
    var onDailyFocusGoalChanged: (() -> Void)? { get set }
    func snapshot() -> SettingsSnapshot
    func setLastMode(_ value: Int) throws
    func setWorkMinutes(_ value: Int) throws
    func setBreakMinutes(_ value: Int) throws
    func setFreeTimerWarningHours(_ value: Int) throws
    func setSoundEnabled(_ value: Bool) throws
    func setReduceMotion(_ value: Bool) throws
    func setSlimClockFont(_ value: Bool) throws
    func setRolloverIgnoredDate(_ value: String) throws
    func setBackgroundTheme(_ value: String) throws
    func setDayStartHour(_ value: Int) throws
    func setNickname(_ value: String) throws
    func setSidebarVisible(_ value: Bool) throws
    func setSidebarOrder(_ value: [String]) throws
    func setDashboardTimerVisible(_ value: Bool) throws
    func setReduceTransparency(_ value: Bool) throws
    func setNaturalCompletionNoticeShown(_ value: Bool) throws
    func setAutoStartBreak(_ value: Bool) throws
    func setAutoStartNextPomodoro(_ value: Bool) throws
    func setQuickStartEnabled(_ value: Bool) throws
    func setLongBreakEnabled(_ value: Bool) throws
    func setLongBreakMinutes(_ value: Int) throws
    func setLongBreakInterval(_ value: Int) throws
    func setScheduleDisplayMode(_ value: String) throws
    func resetSidebarOrder() throws
    func dailyFocusGoal(date: String) -> Int
    func setDailyFocusGoal(date: String, minutes: Int) throws
}
