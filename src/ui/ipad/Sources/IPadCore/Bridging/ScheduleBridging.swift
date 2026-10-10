import Foundation

public struct ScheduleEntry: Equatable, Sendable, Identifiable {
    public var id = -1
    public var title = ""
    public var location = ""
    public var weekday = 1
    public var startMinutes = 480
    public var endMinutes = 525
    public var durationMinutes = 45
    public var weekStart = 1
    public var weekEnd = 20
    public var weekParity = 0
    public var categoryID = -1
    public var categoryName = ""
    public var categoryColor = ""
    public init() {}
}

public struct SchedulePeriod: Equatable, Sendable {
    public var index: Int
    public var startMinutes: Int
    public var endMinutes: Int
    public init(index: Int = 0, startMinutes: Int, endMinutes: Int) {
        self.index = index; self.startMinutes = startMinutes; self.endMinutes = endMinutes
    }
}

public struct ScheduleSettings: Equatable, Sendable {
    public var semesterStartDate: String
    public var semesterWeeks: Int
    public var showWeekend: Bool
    public init(semesterStartDate: String = "", semesterWeeks: Int = 20, showWeekend: Bool = true) {
        self.semesterStartDate = semesterStartDate; self.semesterWeeks = semesterWeeks; self.showWeekend = showWeekend
    }
}

// nil 表示未改；categoryID = -1 与 location = "" 明确清空，不能省略。
public struct ScheduleChanges: Equatable, Sendable {
    public var title: String?
    public var location: String?
    public var weekday: Int?
    public var startMinutes: Int?
    public var endMinutes: Int?
    public var weekStart: Int?
    public var weekEnd: Int?
    public var weekParity: Int?
    public var categoryID: Int?
    public init() {}
}

@MainActor public protocol ScheduleBridging: AnyObject {
    var onScheduleChanged: (() -> Void)? { get set }
    var onPeriodsChanged: (() -> Void)? { get set }
    var onSemesterStartDateChanged: (() -> Void)? { get set }
    var onSemesterWeeksChanged: (() -> Void)? { get set }
    var onShowWeekendChanged: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var maxTitleLength: Int { get }
    var maxLocationLength: Int { get }
    var maxWeekIndex: Int { get }
    var maxPeriodCount: Int { get }
    func entries() throws -> [ScheduleEntry]
    func entries(week: Int) throws -> [ScheduleEntry]
    func conflicts(weekday: Int, startMinutes: Int, endMinutes: Int, weekStart: Int, weekEnd: Int,
                   parity: Int, excluding: Int) throws -> [ScheduleEntry]
    func add(_ entry: ScheduleEntry) throws
    func update(id: Int, changes: ScheduleChanges) throws
    func delete(id: Int) throws
    func periods() throws -> [SchedulePeriod]
    func savePeriods(_ periods: [SchedulePeriod]) throws
    func settings() throws -> ScheduleSettings
    func saveSettings(_ settings: ScheduleSettings) throws
    // 周次由 C++ 计算；无效输入保留空串或零，不在 Swift 补日期计算。
    func mondayOf(date: String) -> String
    func parseSemesterStart(_ start: String) -> String
    func weekIndex(start: String, date: String) -> Int
    func mondayOfWeek(start: String, week: Int) -> String
    func dateOfWeekday(start: String, week: Int, weekday: Int) -> String
    func overlaps(start: Double, end: Double, otherStart: Double, otherEnd: Double) -> Bool
}
