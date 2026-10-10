import Foundation
import IPadCore
import PTBridge

@MainActor final class ScheduleBridgeAdapter: ScheduleBridging {
    private let native = PTScheduleBridge()
    var onScheduleChanged: (() -> Void)?
    var onPeriodsChanged: (() -> Void)?
    var onSemesterStartDateChanged: (() -> Void)?
    var onSemesterWeeksChanged: (() -> Void)?
    var onShowWeekendChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var maxTitleLength: Int { native.maxTitleLength }
    var maxLocationLength: Int { native.maxLocationLength }
    var maxWeekIndex: Int { native.maxWeekIndex }
    var maxPeriodCount: Int { native.maxPeriodCount }
    init() {
        // Qt 的接收上下文保证主线程，进入主 actor 后只投影数据与信号。
        native.onScheduleChanged = { [weak self] in MainActor.assumeIsolated { self?.onScheduleChanged?() } }
        native.onPeriodsChanged = { [weak self] in MainActor.assumeIsolated { self?.onPeriodsChanged?() } }
        native.onSemesterStartDateChanged = { [weak self] in MainActor.assumeIsolated { self?.onSemesterStartDateChanged?() } }
        native.onSemesterWeeksChanged = { [weak self] in MainActor.assumeIsolated { self?.onSemesterWeeksChanged?() } }
        native.onShowWeekendChanged = { [weak self] in MainActor.assumeIsolated { self?.onShowWeekendChanged?() } }
        native.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } }
    }
    private func check(_ result: PTScheduleResult) throws {
        guard result.valid else {
            throw NSError(domain: "PTBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error])
        }
    }
    private func values(_ result: PTScheduleResult) throws -> [ScheduleEntry] {
        try check(result)
        return result.entries.map { item in
            var value = ScheduleEntry()
            value.id = item.entryId; value.title = item.title; value.location = item.location
            value.weekday = item.weekday; value.startMinutes = item.startMinutes; value.endMinutes = item.endMinutes
            value.durationMinutes = item.durationMinutes; value.weekStart = item.weekStart; value.weekEnd = item.weekEnd
            value.weekParity = item.weekParity; value.categoryID = item.categoryId
            value.categoryName = item.categoryName; value.categoryColor = item.categoryColor
            return value
        }
    }
    func entries() throws -> [ScheduleEntry] { try values(native.entries()) }
    func entries(week: Int) throws -> [ScheduleEntry] { try values(native.entries(forWeek: week)) }
    func conflicts(weekday: Int, startMinutes: Int, endMinutes: Int, weekStart: Int, weekEnd: Int,
                   parity: Int, excluding: Int) throws -> [ScheduleEntry] {
        try values(native.conflicts(weekday, startMinutes: startMinutes, endMinutes: endMinutes,
                                    weekStart: weekStart, weekEnd: weekEnd, parity: parity, excluding: excluding))
    }
    func add(_ entry: ScheduleEntry) throws {
        try native.addEntry(entry.title, weekday: entry.weekday, startMinutes: entry.startMinutes,
                            endMinutes: entry.endMinutes, location: entry.location, categoryId: entry.categoryID,
                            weekStart: entry.weekStart, weekEnd: entry.weekEnd, parity: entry.weekParity)
    }
    func update(id: Int, changes: ScheduleChanges) throws {
        // 逐字段转成 has 标记；默认值不能写回未编辑的字段。
        let change = PTScheduleChanges()
        if let value = changes.title { change.title = value }
        if let value = changes.location { change.location = value }
        if let value = changes.weekday { change.weekday = value }
        if let value = changes.startMinutes { change.startMinutes = value }
        if let value = changes.endMinutes { change.endMinutes = value }
        if let value = changes.weekStart { change.weekStart = value }
        if let value = changes.weekEnd { change.weekEnd = value }
        if let value = changes.weekParity { change.weekParity = value }
        if let value = changes.categoryID { change.categoryId = value }
        try native.updateEntry(id, changes: change)
    }
    func delete(id: Int) throws { try native.deleteEntry(id) }
    func periods() throws -> [SchedulePeriod] {
        let result = native.periods(); try check(result)
        return result.periods.map { SchedulePeriod(index: $0.index, startMinutes: $0.startMinutes, endMinutes: $0.endMinutes) }
    }
    func savePeriods(_ periods: [SchedulePeriod]) throws {
        try native.savePeriods(periods.map { value in
            PTSchedulePeriod(startMinutes: value.startMinutes, endMinutes: value.endMinutes)
        })
    }
    func settings() throws -> ScheduleSettings {
        let value = try native.readSettings()
        return ScheduleSettings(semesterStartDate: value.semesterStartDate, semesterWeeks: value.semesterWeeks,
                                showWeekend: value.showWeekend)
    }
    func saveSettings(_ settings: ScheduleSettings) throws {
        try native.saveSettings(settings.semesterStartDate, weeks: settings.semesterWeeks, showWeekend: settings.showWeekend)
    }
    func mondayOf(date: String) -> String { native.monday(of: date) }
    func parseSemesterStart(_ start: String) -> String { native.parseSemesterStart(start) }
    func weekIndex(start: String, date: String) -> Int { native.weekIndex(forDate: start, date: date) }
    func mondayOfWeek(start: String, week: Int) -> String { native.monday(ofWeek: start, week: week) }
    func dateOfWeekday(start: String, week: Int, weekday: Int) -> String { native.date(ofWeekday: start, week: week, weekday: weekday) }
    func overlaps(start: Double, end: Double, otherStart: Double, otherEnd: Double) -> Bool {
        native.overlaps(start, end: end, otherStart: otherStart, otherEnd: otherEnd)
    }
}
