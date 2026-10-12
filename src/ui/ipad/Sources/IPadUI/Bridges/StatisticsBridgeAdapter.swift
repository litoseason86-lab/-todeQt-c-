import Foundation
import IPadCore
import PTBridge
@MainActor final class StatisticsBridgeAdapter: StatisticsBridgeProtocol {
    private let native = PTStatisticsBridge()
    var onFailure: ((String) -> Void)?
    init() {
        // Qt 接收上下文把信号排回主线程，背景失败只转发一次。
        native.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } }
    }
    private func checked(_ result: PTStatisticsResult) throws -> PTStatisticsResult {
        guard result.valid else { throw NSError(domain: "PTStatisticsBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }; return result
    }
    private func value(_ item: PTDayStatistics) -> DayStatistics {
        var result = DayStatistics()
        result.totalDuration = item.totalDuration
        result.completedTasks = item.completedTasks
        result.totalTasks = item.totalTasks
        result.completionRate = item.completionRate
        result.sessionCount = item.sessionCount
        result.pomodoroCount = item.pomodoroCount
        return result
    }
    private func value(_ item: PTMonthStatistics) -> MonthStatistics {
        var result = MonthStatistics()
        result.totalDuration = item.totalDuration
        result.effectiveDays = item.effectiveDays
        result.sessionCount = item.sessionCount
        result.completedTasks = item.completedTasks
        result.totalTasks = item.totalTasks
        return result
    }
    private func value(_ item: PTComparisonMetric) -> ComparisonMetric {
        var result = ComparisonMetric()
        result.hasData = item.hasData
        result.currentValue = item.currentValue
        result.previousValue = item.previousValue
        result.changePercent = item.changePercent
        result.trend = item.trend
        result.displayText = item.displayText
        return result
    }
    private func value(_ item: PTStatisticsComparison) -> StatisticsComparison {
        var result = StatisticsComparison()
        result.hasData = item.hasData
        result.periodState = item.periodState
        result.duration = value(item.duration)
        result.sessionCount = value(item.sessionCount)
        result.taskCompletion = value(item.taskCompletion)
        result.effectiveDays = value(item.effectiveDays)
        return result
    }
    private func value(_ item: PTWeekDayStatistics) -> WeekDayStatistics {
        var result = WeekDayStatistics()
        result.date = item.date
        result.duration = item.duration
        result.tasks = item.tasks
        result.completedTasks = item.completedTasks
        return result
    }
    private func value(_ item: PTCategoryStatisticsRow) -> CategoryStatisticsRow {
        var result = CategoryStatisticsRow()
        result.name = item.name
        result.color = item.color
        result.duration = item.duration
        result.percentage = item.percentage
        return result
    }
    private func value(_ item: PTCategoryStatistics) -> CategoryStatistics {
        var result = CategoryStatistics()
        result.categories = item.categories.map { value($0) }
        result.totalDuration = item.totalDuration
        return result
    }
    private func value(_ item: PTTaskStatisticsRow) -> TaskStatisticsRow {
        var result = TaskStatisticsRow()
        result.taskId = item.taskId
        result.title = item.title
        result.completed = item.completed
        result.categoryName = item.categoryName
        result.color = item.color
        result.focusedSeconds = item.focusedSeconds
        result.pomodoros = item.pomodoros
        result.unassigned = item.unassigned
        return result
    }
    private func value(_ item: PTTaskStatistics) -> TaskStatistics {
        var result = TaskStatistics()
        result.tasks = item.tasks.map { value($0) }
        result.totalDuration = item.totalDuration
        result.taskCount = item.taskCount
        return result
    }
    private func value(_ item: PTMonthWeekStatistics) -> MonthWeekStatistics {
        var result = MonthWeekStatistics()
        result.label = item.label
        result.duration = item.duration
        result.startDate = item.startDate
        result.endDate = item.endDate
        return result
    }
    private func value(_ item: PTReviewGoalDay) -> ReviewGoalDay {
        var result = ReviewGoalDay()
        result.date = item.date
        result.goalMinutes = item.goalMinutes
        result.actualSeconds = item.actualSeconds
        result.met = item.met
        return result
    }
    private func value(_ item: PTReviewGoal) -> ReviewGoal {
        var result = ReviewGoal()
        result.goalDays = item.goalDays
        result.metDays = item.metDays
        result.goalMinutesTotal = item.goalMinutesTotal
        result.actualSecondsTotal = item.actualSecondsTotal
        result.days = item.days.map { value($0) }
        return result
    }
    private func value(_ item: PTReviewTodayGoal) -> ReviewTodayGoal {
        var result = ReviewTodayGoal()
        result.date = item.date
        result.goalMinutes = item.goalMinutes
        result.actualSeconds = item.actualSeconds
        result.progressPercent = item.progressPercent
        return result
    }
    private func value(_ item: PTReviewSubject) -> ReviewSubject {
        var result = ReviewSubject()
        result.name = item.name
        result.color = item.color
        result.currentSeconds = item.currentSeconds
        result.currentSharePercent = item.currentSharePercent
        result.pseudoSubject = item.pseudoSubject
        result.previousSeconds = item.previousSeconds?.intValue
        result.deltaSeconds = item.deltaSeconds?.intValue
        result.previousSharePercent = item.previousSharePercent?.doubleValue
        result.deltaPoints = item.deltaPoints?.doubleValue
        return result
    }
    private func value(_ item: PTReviewPlannedRow) -> ReviewPlannedRow {
        var result = ReviewPlannedRow()
        result.subject = item.subject
        result.color = item.color
        result.plannedMinutes = item.plannedMinutes
        result.actualSeconds = item.actualSeconds
        result.actualDisplayMinutes = item.actualDisplayMinutes
        result.differenceDisplayMinutes = item.differenceDisplayMinutes
        result.investmentRatioPercent = item.investmentRatioPercent
        return result
    }
    private func value(_ item: PTReviewPlannedTasks) -> ReviewPlannedTasks {
        var result = ReviewPlannedTasks()
        result.rows = item.rows.map { value($0) }
        result.inProgress = item.inProgress
        result.totalPlannedMinutes = item.totalPlannedMinutes
        result.totalActualSeconds = item.totalActualSeconds
        result.totalActualDisplayMinutes = item.totalActualDisplayMinutes
        result.totalDifferenceDisplayMinutes = item.totalDifferenceDisplayMinutes
        result.totalInvestmentRatioPercent = item.totalInvestmentRatioPercent?.doubleValue
        return result
    }
    private func value(_ item: PTReviewFact) -> ReviewFact {
        var result = ReviewFact()
        result.type = item.type
        result.date = item.date
        result.subject = item.subject
        result.goalMinutes = item.goalMinutes?.intValue
        result.actualSeconds = item.actualSeconds?.intValue
        result.ratioPercent = item.ratioPercent?.doubleValue
        result.currentSeconds = item.currentSeconds?.intValue
        result.previousSeconds = item.previousSeconds?.intValue
        result.currentSharePercent = item.currentSharePercent?.doubleValue
        result.deltaPoints = item.deltaPoints?.doubleValue
        result.plannedMinutes = item.plannedMinutes?.intValue
        result.actualDisplayMinutes = item.actualDisplayMinutes?.intValue
        result.shortfallDisplayMinutes = item.shortfallDisplayMinutes?.intValue
        return result
    }
    private func value(_ item: PTWeeklyReview) -> WeeklyReview {
        var result = WeeklyReview()
        result.weekStart = item.weekStart
        result.weekEnd = item.weekEnd
        result.logicalTodayIso = item.logicalTodayIso
        result.periodState = item.periodState
        result.loadState = item.loadState
        result.errorMessage = item.errorMessage
        result.hasData = item.hasData
        result.hasDisplayContent = item.hasDisplayContent
        result.goal = item.goal.map { value($0) }
        result.todayGoal = item.todayGoal.map { value($0) }
        result.subjects = item.subjects.map { value($0) }
        result.plannedTasks = item.plannedTasks.map { value($0) }
        result.facts = item.facts.map { value($0) }
        return result
    }
    private func value(_ item: PTFocusSummaryDay) -> FocusSummaryDay {
        var result = FocusSummaryDay()
        result.date = item.date
        result.seconds = item.seconds
        result.pomodoros = item.pomodoros
        return result
    }
    private func value(_ item: PTFocusSummaryCategory) -> FocusSummaryCategory {
        var result = FocusSummaryCategory()
        result.categoryId = item.categoryId
        result.name = item.name
        result.seconds = item.seconds
        return result
    }
    private func value(_ item: PTFocusSummary) -> FocusSummary {
        var result = FocusSummary()
        result.seconds = item.seconds
        result.pomodoros = item.pomodoros
        result.days = item.days.map { value($0) }
        result.categories = item.categories.map { value($0) }
        return result
    }
    func dayStats(date: String) throws -> DayStatistics {
        return value(try checked(native.dayStats(date: date)).day)
    }
    func todayStats() throws -> DayStatistics {
        return value(try checked(native.todayStats()).day)
    }
    func dayComparison(date: String) throws -> StatisticsComparison {
        return value(try checked(native.dayComparison(date: date)).comparison)
    }
    func weekStats(startDate: String) throws -> [WeekDayStatistics] {
        return try checked(native.weekStats(startDate: startDate)).weekDays.map { value($0) }
    }
    func currentWeekStats() throws -> [WeekDayStatistics] {
        return try checked(native.currentWeekStats()).weekDays.map { value($0) }
    }
    func weekComparison(startDate: String, logicalToday: String) throws -> StatisticsComparison {
        return value(try checked(native.weekComparison(startDate: startDate, logicalToday: logicalToday)).comparison)
    }
    func categoryStats(from: String, to: String) throws -> CategoryStatistics {
        return value(try checked(native.categoryStats(from: from, to: to)).categoryStats)
    }
    func dayTaskStats(date: String) throws -> TaskStatistics {
        return value(try checked(native.dayTaskStats(date: date)).taskStats)
    }
    func todayTaskStats() throws -> TaskStatistics {
        return value(try checked(native.todayTaskStats()).taskStats)
    }
    func monthStats(year: Int, month: Int) throws -> MonthStatistics {
        return value(try checked(native.monthStats(year: year, month: month)).month)
    }
    func currentMonthStats() throws -> MonthStatistics {
        return value(try checked(native.currentMonthStats()).month)
    }
    func monthComparison(year: Int, month: Int) throws -> StatisticsComparison {
        return value(try checked(native.monthComparison(year: year, month: month)).comparison)
    }
    func monthComparison(year: Int, month: Int, current: MonthStatistics) throws -> StatisticsComparison {
        let input = PTMonthStatisticsInput()
        input.totalDuration = current.totalDuration
        input.effectiveDays = current.effectiveDays
        input.sessionCount = current.sessionCount
        input.completedTasks = current.completedTasks
        input.totalTasks = current.totalTasks
        return value(try checked(native.monthComparison(year: year, month: month, current: input)).comparison)
    }
    func effectiveDays(from: String, to: String) throws -> Int {
        return try checked(native.effectiveDays(from: from, to: to)).count
    }
    func suggestedDailyGoalMinutes(logicalToday: String) throws -> Int {
        return try checked(native.suggestedDailyGoal(logicalToday: logicalToday)).count
    }
    func focusSessionCount(from: String, to: String) throws -> Int {
        return try checked(native.focusSessionCount(from: from, to: to)).count
    }
    func validPomodoroCount(from: String, to: String) throws -> Int {
        return try checked(native.validPomodoroCount(from: from, to: to)).count
    }
    func streakDays() throws -> Int {
        return try checked(native.streakDays()).count
    }
    func totalFocusDuration() throws -> Int {
        return try checked(native.totalFocusDuration()).count
    }
    func monthWeeklySummary(year: Int, month: Int) throws -> [MonthWeekStatistics] {
        return try checked(native.monthWeeklySummary(year: year, month: month)).monthWeeks.map { value($0) }
    }
    func currentMonthWeeklySummary() throws -> [MonthWeekStatistics] {
        return try checked(native.currentMonthWeeklySummary()).monthWeeks.map { value($0) }
    }
    func weeklyReview(startDate: String, logicalToday: String) throws -> WeeklyReview {
        return value(try checked(native.weeklyReview(startDate: startDate, logicalToday: logicalToday)).review)
    }
    func currentWeeklyReview() throws -> WeeklyReview {
        return value(try checked(native.currentWeeklyReview()).review)
    }
    func focusSummary(from: String, to: String, dayStartHour: Int) throws -> FocusSummary {
        return value(try checked(native.focusSummary(from: from, to: to, dayStartHour: dayStartHour)).summary)
    }
}
