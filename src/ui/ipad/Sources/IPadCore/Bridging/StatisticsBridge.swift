import Foundation
public struct DayStatistics: Equatable, Sendable {
    public var totalDuration: Int = 0
    public var completedTasks: Int = 0
    public var totalTasks: Int = 0
    public var completionRate: Double = 0
    public var sessionCount: Int = 0
    public var pomodoroCount: Int = 0
    public init() {}
}
public struct MonthStatistics: Equatable, Sendable {
    public var totalDuration: Int = 0
    public var effectiveDays: Int = 0
    public var sessionCount: Int = 0
    public var completedTasks: Int = 0
    public var totalTasks: Int = 0
    public init() {}
}
public struct ComparisonMetric: Equatable, Sendable {
    public var hasData: Bool = false
    public var currentValue: Int = 0
    public var previousValue: Int = 0
    public var changePercent: Double = 0
    public var trend: Int = 0
    public var displayText: String = ""
    public init() {}
}
public struct StatisticsComparison: Equatable, Sendable {
    public var hasData: Bool = false
    public var periodState: String = ""
    public var duration: ComparisonMetric = ComparisonMetric()
    public var sessionCount: ComparisonMetric = ComparisonMetric()
    public var taskCompletion: ComparisonMetric = ComparisonMetric()
    public var effectiveDays: ComparisonMetric = ComparisonMetric()
    public init() {}
}
public struct WeekDayStatistics: Equatable, Sendable {
    public var date: String = ""
    public var duration: Int = 0
    public var tasks: Int = 0
    public var completedTasks: Int = 0
    public init() {}
}
public struct CategoryStatisticsRow: Equatable, Sendable {
    public var name: String = ""
    public var color: String = ""
    public var duration: Int = 0
    public var percentage: Double = 0
    public init() {}
}
public struct CategoryStatistics: Equatable, Sendable {
    public var categories: [CategoryStatisticsRow] = []
    public var totalDuration: Int = 0
    public init() {}
}
public struct TaskStatisticsRow: Equatable, Sendable {
    public var taskId: Int = -1
    public var title: String = ""
    public var completed: Bool = false
    public var categoryName: String = ""
    public var color: String = ""
    public var focusedSeconds: Int = 0
    public var pomodoros: Int = 0
    public var unassigned: Bool = false
    public init() {}
}
public struct TaskStatistics: Equatable, Sendable {
    public var tasks: [TaskStatisticsRow] = []
    public var totalDuration: Int = 0
    public var taskCount: Int = 0
    public init() {}
}
public struct MonthWeekStatistics: Equatable, Sendable {
    public var label: String = ""
    public var duration: Int = 0
    public var startDate: String = ""
    public var endDate: String = ""
    public init() {}
}
public struct ReviewGoalDay: Equatable, Sendable {
    public var date: String = ""
    public var goalMinutes: Int = 0
    public var actualSeconds: Int = 0
    public var met: Bool = false
    public init() {}
}
public struct ReviewGoal: Equatable, Sendable {
    public var goalDays: Int = 0
    public var metDays: Int = 0
    public var goalMinutesTotal: Int = 0
    public var actualSecondsTotal: Int = 0
    public var days: [ReviewGoalDay] = []
    public init() {}
}
public struct ReviewTodayGoal: Equatable, Sendable {
    public var date: String = ""
    public var goalMinutes: Int = 0
    public var actualSeconds: Int = 0
    public var progressPercent: Double = 0
    public init() {}
}
public struct ReviewSubject: Equatable, Sendable {
    public var name: String = ""
    public var color: String = ""
    public var currentSeconds: Int = 0
    public var currentSharePercent: Double = 0
    public var pseudoSubject: Bool = false
    public var previousSeconds: Int? = nil
    public var deltaSeconds: Int? = nil
    public var previousSharePercent: Double? = nil
    public var deltaPoints: Double? = nil
    public init() {}
}
public struct ReviewPlannedRow: Equatable, Sendable {
    public var subject: String = ""
    public var color: String = ""
    public var plannedMinutes: Int = 0
    public var actualSeconds: Int = 0
    public var actualDisplayMinutes: Int = 0
    public var differenceDisplayMinutes: Int = 0
    public var investmentRatioPercent: Double = 0
    public init() {}
}
public struct ReviewPlannedTasks: Equatable, Sendable {
    public var rows: [ReviewPlannedRow] = []
    public var inProgress: Bool = false
    public var totalPlannedMinutes: Int = 0
    public var totalActualSeconds: Int = 0
    public var totalActualDisplayMinutes: Int = 0
    public var totalDifferenceDisplayMinutes: Int = 0
    public var totalInvestmentRatioPercent: Double? = nil
    public init() {}
}
public struct ReviewFact: Equatable, Sendable {
    public var type: String = ""
    public var date: String = ""
    public var subject: String = ""
    public var goalMinutes: Int? = nil
    public var actualSeconds: Int? = nil
    public var ratioPercent: Double? = nil
    public var currentSeconds: Int? = nil
    public var previousSeconds: Int? = nil
    public var currentSharePercent: Double? = nil
    public var deltaPoints: Double? = nil
    public var plannedMinutes: Int? = nil
    public var actualDisplayMinutes: Int? = nil
    public var shortfallDisplayMinutes: Int? = nil
    public init() {}
}
public struct WeeklyReview: Equatable, Sendable {
    public var weekStart: String = ""
    public var weekEnd: String = ""
    public var logicalTodayIso: String = ""
    public var periodState: String = ""
    public var loadState: String = ""
    public var errorMessage: String = ""
    public var hasData: Bool = false
    public var hasDisplayContent: Bool = false
    public var goal: ReviewGoal? = nil
    public var todayGoal: ReviewTodayGoal? = nil
    public var subjects: [ReviewSubject] = []
    public var plannedTasks: ReviewPlannedTasks? = nil
    public var facts: [ReviewFact] = []
    public init() {}
}
public struct FocusSummaryDay: Equatable, Sendable {
    public var date: String = ""
    public var seconds: Int = 0
    public var pomodoros: Int = 0
    public init() {}
}
public struct FocusSummaryCategory: Equatable, Sendable {
    public var categoryId: Int = -1
    public var name: String = ""
    public var seconds: Int = 0
    public init() {}
}
public struct FocusSummary: Equatable, Sendable {
    public var seconds: Int = 0
    public var pomodoros: Int = 0
    public var days: [FocusSummaryDay] = []
    public var categories: [FocusSummaryCategory] = []
    public init() {}
}
@MainActor public protocol StatisticsBridgeProtocol: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func dayStats(date: String) throws -> DayStatistics
    func todayStats() throws -> DayStatistics
    func dayComparison(date: String) throws -> StatisticsComparison
    func weekStats(startDate: String) throws -> [WeekDayStatistics]
    func currentWeekStats() throws -> [WeekDayStatistics]
    func weekComparison(startDate: String, logicalToday: String) throws -> StatisticsComparison
    func categoryStats(from: String, to: String) throws -> CategoryStatistics
    func dayTaskStats(date: String) throws -> TaskStatistics
    func todayTaskStats() throws -> TaskStatistics
    func monthStats(year: Int, month: Int) throws -> MonthStatistics
    func currentMonthStats() throws -> MonthStatistics
    func monthComparison(year: Int, month: Int) throws -> StatisticsComparison
    func monthComparison(year: Int, month: Int, current: MonthStatistics) throws -> StatisticsComparison
    func effectiveDays(from: String, to: String) throws -> Int
    // 今日目标编辑器的预填分钟（逻辑昨天实际专注向下取整的整小时，不足 1 小时为 0），口径在 C++。
    func suggestedDailyGoalMinutes(logicalToday: String) throws -> Int
    func focusSessionCount(from: String, to: String) throws -> Int
    func validPomodoroCount(from: String, to: String) throws -> Int
    func streakDays() throws -> Int
    func totalFocusDuration() throws -> Int
    func monthWeeklySummary(year: Int, month: Int) throws -> [MonthWeekStatistics]
    func currentMonthWeeklySummary() throws -> [MonthWeekStatistics]
    func weeklyReview(startDate: String, logicalToday: String) throws -> WeeklyReview
    func currentWeeklyReview() throws -> WeeklyReview
    func focusSummary(from: String, to: String, dayStartHour: Int) throws -> FocusSummary
}
