import IPadCore
@MainActor final class StatisticsBridgeFake: StatisticsBridgeProtocol {
    var onFailure: ((String) -> Void)?
    var error: Error?
    var calls: [(String, [String], [Int])] = []
    var suppliedMonths: [MonthStatistics] = []
    var day: DayStatistics = DayStatistics()
    var month: MonthStatistics = MonthStatistics()
    var comparison: StatisticsComparison = StatisticsComparison()
    var weekDays: [WeekDayStatistics] = []
    var categoryStats: CategoryStatistics = CategoryStatistics()
    var taskStats: TaskStatistics = TaskStatistics()
    var monthWeeks: [MonthWeekStatistics] = []
    var review: WeeklyReview = WeeklyReview()
    var summary: FocusSummary = FocusSummary()
    var count: Int = 0
    private func record(_ name: String, dates: [String] = [], numbers: [Int] = []) throws { calls.append((name, dates, numbers)); if let error { throw error } }
    func dayStats(date: String) throws -> DayStatistics { try record("dayStats", dates: [date], numbers: []); return self.day }
    func todayStats() throws -> DayStatistics { try record("todayStats", dates: [], numbers: []); return self.day }
    func dayComparison(date: String) throws -> StatisticsComparison { try record("dayComparison", dates: [date], numbers: []); return self.comparison }
    func weekStats(startDate: String) throws -> [WeekDayStatistics] { try record("weekStats", dates: [startDate], numbers: []); return self.weekDays }
    func currentWeekStats() throws -> [WeekDayStatistics] { try record("currentWeekStats", dates: [], numbers: []); return self.weekDays }
    func weekComparison(startDate: String, logicalToday: String) throws -> StatisticsComparison { try record("weekComparison", dates: [startDate, logicalToday], numbers: []); return self.comparison }
    func categoryStats(from: String, to: String) throws -> CategoryStatistics { try record("categoryStats", dates: [from, to], numbers: []); return self.categoryStats }
    func dayTaskStats(date: String) throws -> TaskStatistics { try record("dayTaskStats", dates: [date], numbers: []); return self.taskStats }
    func todayTaskStats() throws -> TaskStatistics { try record("todayTaskStats", dates: [], numbers: []); return self.taskStats }
    func monthStats(year: Int, month: Int) throws -> MonthStatistics { try record("monthStats", dates: [], numbers: [year, month]); return self.month }
    func currentMonthStats() throws -> MonthStatistics { try record("currentMonthStats", dates: [], numbers: []); return self.month }
    func monthComparison(year: Int, month: Int) throws -> StatisticsComparison { try record("monthComparison", dates: [], numbers: [year, month]); return self.comparison }
    func monthComparison(year: Int, month: Int, current: MonthStatistics) throws -> StatisticsComparison { suppliedMonths.append(current); try record("monthComparison", dates: [], numbers: [year, month]); return self.comparison }
    func effectiveDays(from: String, to: String) throws -> Int { try record("effectiveDays", dates: [from, to], numbers: []); return self.count }
    func focusSessionCount(from: String, to: String) throws -> Int { try record("focusSessionCount", dates: [from, to], numbers: []); return self.count }
    func validPomodoroCount(from: String, to: String) throws -> Int { try record("validPomodoroCount", dates: [from, to], numbers: []); return self.count }
    func streakDays() throws -> Int { try record("streakDays", dates: [], numbers: []); return self.count }
    func totalFocusDuration() throws -> Int { try record("totalFocusDuration", dates: [], numbers: []); return self.count }
    func monthWeeklySummary(year: Int, month: Int) throws -> [MonthWeekStatistics] { try record("monthWeeklySummary", dates: [], numbers: [year, month]); return self.monthWeeks }
    func currentMonthWeeklySummary() throws -> [MonthWeekStatistics] { try record("currentMonthWeeklySummary", dates: [], numbers: []); return self.monthWeeks }
    func weeklyReview(startDate: String, logicalToday: String) throws -> WeeklyReview { try record("weeklyReview", dates: [startDate, logicalToday], numbers: []); return self.review }
    func currentWeeklyReview() throws -> WeeklyReview { try record("currentWeeklyReview", dates: [], numbers: []); return self.review }
    func focusSummary(from: String, to: String, dayStartHour: Int) throws -> FocusSummary { try record("focusSummary", dates: [from, to], numbers: [dayStartHour]); return self.summary }
}
