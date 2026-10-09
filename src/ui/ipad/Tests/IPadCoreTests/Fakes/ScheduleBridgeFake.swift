import IPadCore

// 所有结果都由场景配置；替身不实现另一套周次、冲突或日期规则。
@MainActor final class ScheduleBridgeFake: ScheduleBridging {
    var onScheduleChanged: (() -> Void)?
    var onPeriodsChanged: (() -> Void)?
    var onSemesterStartDateChanged: (() -> Void)?
    var onSemesterWeeksChanged: (() -> Void)?
    var onShowWeekendChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var maxTitleLength = 60
    var maxLocationLength = 60
    var maxWeekIndex = 60
    var maxPeriodCount = 24
    var entryValues: [ScheduleEntry] = []
    var periodValues: [SchedulePeriod] = []
    var conflictValues: [ScheduleEntry] = []
    var settingsValue = ScheduleSettings()
    var mondayValue = ""
    var parsedStartValue = ""
    var weekValue = 0
    var weekMondayValue = ""
    var weekdayDateValue = ""
    var overlapsValue = false
    var overlapResult: ((Double, Double, Double, Double) -> Bool)?
    var settingsError: Error?
    var periodWriteErrorAfterFirst: Error?
    var readError: Error?
    var writeError: Error?
    var calls: [String] = []
    var requestedWeeks: [Int] = []
    var weekInputs: [(String, String)] = []
    var weekdayInputs: [(String, Int, Int)] = []
    var conflictInputs: [[Int]] = []
    var additions: [ScheduleEntry] = []
    var updates: [(Int, ScheduleChanges)] = []
    var deletions: [Int] = []
    var savedPeriods: [[SchedulePeriod]] = []
    var savedSettings: [ScheduleSettings] = []
    private func read(_ name: String) throws { calls.append(name); if let readError { throw readError } }
    private func write(_ name: String) throws { calls.append(name); if let writeError { throw writeError } }
    func entries() throws -> [ScheduleEntry] { try read("entries"); return entryValues }
    func entries(week: Int) throws -> [ScheduleEntry] { requestedWeeks.append(week); try read("entriesForWeek"); return entryValues }
    func conflicts(weekday: Int, startMinutes: Int, endMinutes: Int, weekStart: Int, weekEnd: Int,
                   parity: Int, excluding: Int) throws -> [ScheduleEntry] {
        conflictInputs.append([weekday, startMinutes, endMinutes, weekStart, weekEnd, parity, excluding])
        try read("conflicts"); return conflictValues
    }
    func add(_ entry: ScheduleEntry) throws { additions.append(entry); try write("add") }
    func update(id: Int, changes: ScheduleChanges) throws { updates.append((id, changes)); try write("update") }
    func delete(id: Int) throws { deletions.append(id); try write("delete") }
    func periods() throws -> [SchedulePeriod] { try read("periods"); return periodValues }
    func savePeriods(_ periods: [SchedulePeriod]) throws {
        savedPeriods.append(periods); try write("savePeriods")
        if savedPeriods.count > 1, let periodWriteErrorAfterFirst { throw periodWriteErrorAfterFirst }
        periodValues = periods
    }
    func settings() throws -> ScheduleSettings { try read("settings"); return settingsValue }
    func saveSettings(_ settings: ScheduleSettings) throws {
        savedSettings.append(settings); try write("saveSettings"); if let settingsError { throw settingsError }; settingsValue = settings
    }
    func mondayOf(date: String) -> String { calls.append("mondayOf"); return mondayValue }
    func parseSemesterStart(_ start: String) -> String { calls.append("parseSemesterStart"); return parsedStartValue }
    func weekIndex(start: String, date: String) -> Int { weekInputs.append((start, date)); return weekValue }
    func mondayOfWeek(start: String, week: Int) -> String { calls.append("mondayOfWeek"); return weekMondayValue }
    func dateOfWeekday(start: String, week: Int, weekday: Int) -> String {
        weekdayInputs.append((start, week, weekday)); return weekdayDateValue
    }
    func overlaps(start: Double, end: Double, otherStart: Double, otherEnd: Double) -> Bool { overlapResult?(start, end, otherStart, otherEnd) ?? overlapsValue }
}
