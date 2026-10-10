import Foundation
import Observation

public enum ScheduleDisplayMode: String, CaseIterable, Sendable { case time, period }

@MainActor @Observable public final class ScheduleStore {
    public private(set) var entries: [ScheduleEntry] = []
    public private(set) var periods: [SchedulePeriod] = []
    public private(set) var settings = ScheduleSettings()
    public private(set) var error = ""
    public private(set) var weekIndex = 1
    public private(set) var currentWeekIndex = 0
    public private(set) var selectedWeekday: Int
    public private(set) var todayDate: String
    public private(set) var todayWeekday: Int
    public private(set) var displayMode: ScheduleDisplayMode = .time
    @ObservationIgnored private let bridge: any ScheduleBridging
    @ObservationIgnored private let settingsBridge: any SettingsBridgeProtocol
    @ObservationIgnored private var logicalDay: (any LogicalDayBridgeProtocol)?
    @ObservationIgnored private var writing = false
    public var maxWeekIndex: Int { bridge.maxWeekIndex }
    public var maxPeriodCount: Int { bridge.maxPeriodCount }
    public var visibleWeekdays: [Int] { Array(1...(settings.showWeekend ? 7 : 5)) }
    public var visibleEntries: [ScheduleEntry] { entries.filter { settings.showWeekend || $0.weekday <= 5 } }
    public var hiddenWeekendEntries: [ScheduleEntry] { settings.showWeekend ? [] : entries.filter { $0.weekday > 5 } }
    public var unplacedEntries: [ScheduleEntry] {
        displayMode == .period ? visibleEntries.filter { periodRange($0) == nil } : []
    }
    public var axisStartMinutes: Int {
        max(0, Int(floor(Double(visibleEntries.map(\.startMinutes).min().map { min(480, $0) } ?? 480) / 60)) * 60)
    }
    public var axisEndMinutes: Int {
        min(1440, Int(ceil(Double(visibleEntries.map(\.endMinutes).max().map { max(1320, $0) } ?? 1320) / 60)) * 60)
    }
    // 测试或宿主可注入服务给出的日期和星期；正式装配使用下面的逻辑日构造器。
    public init(bridge: any ScheduleBridging, settingsBridge: any SettingsBridgeProtocol, todayDate: String, todayWeekday: Int) {
        self.bridge = bridge; self.settingsBridge = settingsBridge; self.logicalDay = nil
        self.todayDate = todayDate; self.todayWeekday = todayWeekday
        selectedWeekday = todayWeekday
        displayMode = ScheduleDisplayMode(rawValue: settingsBridge.snapshot().scheduleDisplayMode) ?? .time
        // 使用独立设置适配器订阅版式变化，避免与外壳覆盖同一个单槽回调。
        settingsBridge.onScheduleDisplayModeChanged = { [weak self] in
            guard let self else { return }
            self.displayMode = ScheduleDisplayMode(rawValue: self.settingsBridge.snapshot().scheduleDisplayMode) ?? .time
        }
        bridge.onScheduleChanged = { [weak self] in self?.refreshFromSignal() }
        bridge.onPeriodsChanged = { [weak self] in self?.refreshFromSignal() }
        bridge.onSemesterStartDateChanged = { [weak self] in self?.refreshFromSignal() }
        bridge.onSemesterWeeksChanged = { [weak self] in self?.refreshFromSignal() }
        bridge.onShowWeekendChanged = { [weak self] in self?.refreshFromSignal() }
        bridge.onFailure = { [weak self] in self?.error = $0 }
        refresh(initial: true)
    }
    // 正式装配使用逻辑今日；自然日不再由页面或系统时钟推断。
    public convenience init(bridge: any ScheduleBridging, settingsBridge: any SettingsBridgeProtocol,
                            logicalDay: any LogicalDayBridgeProtocol) {
        self.init(bridge: bridge, settingsBridge: settingsBridge,
                  todayDate: logicalDay.today, todayWeekday: 1)
        self.logicalDay = logicalDay
        logicalDay.observeChanges { [weak self] in self?.refreshFromSignal() }
        refresh(initial: true)
    }
    @discardableResult public func setDisplayMode(_ mode: ScheduleDisplayMode) -> Bool {
        do { try settingsBridge.setScheduleDisplayMode(mode.rawValue); displayMode = mode; error = ""; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func clampedWeek(_ value: Int, settings: ScheduleSettings) -> Int { max(1, min(settings.semesterWeeks, value)) }
    private func refreshFromSignal() { if !writing { refresh() } }
    public func refresh() { refresh(initial: false) }
    private func refresh(initial: Bool) {
        do {
            let newSettings = try bridge.settings()
            let effectiveDate = logicalDay?.today ?? todayDate
            let dateChanged = todayDate != effectiveDate
            let followingCurrentWeek = initial || (dateChanged && weekIndex == currentWeekIndex)
            let newCurrentWeek = bridge.weekIndex(start: newSettings.semesterStartDate, date: effectiveDate)
            let newWeek = clampedWeek(followingCurrentWeek ? newCurrentWeek : weekIndex, settings: newSettings)
            let newEntries = try bridge.entries(week: newWeek), newPeriods = try bridge.periods()
            // 以逻辑今日所在的自然周反查星期，学期尚未设置时也能选对列；Swift 不另算星期。
            let newWeekday = logicalDay == nil ? todayWeekday : ((1...7).first(where: {
                bridge.dateOfWeekday(start: effectiveDate, week: 1, weekday: $0) == effectiveDate
            }) ?? todayWeekday)
            // 全部读取成功才替换快照，节次读取失败时也保留上一版课程和设置。
            settings = newSettings; todayDate = effectiveDate
            if initial || (dateChanged && selectedWeekday == todayWeekday) { selectedWeekday = newWeekday }
            todayWeekday = newWeekday
            currentWeekIndex = newCurrentWeek; weekIndex = newWeek
            entries = newEntries; periods = newPeriods; error = ""
        } catch { self.error = error.localizedDescription }
    }
    public func selectWeekday(_ day: Int) { if (1...7).contains(day) { selectedWeekday = day } }
    public func updateToday(date: String, weekday: Int) {
        let following = weekIndex == currentWeekIndex
        todayDate = date; todayWeekday = weekday
        let newWeek = bridge.weekIndex(start: settings.semesterStartDate, date: date)
        if following { weekIndex = clampedWeek(newWeek, settings: settings) }
        refresh()
    }
    public func goToWeek(_ week: Int) { weekIndex = clampedWeek(week, settings: settings); refresh() }
    public func goToCurrentWeek() { goToWeek(currentWeekIndex) }
    public func dateForWeekday(_ day: Int) -> String {
        bridge.dateOfWeekday(start: settings.semesterStartDate, week: weekIndex, weekday: day)
    }
    private func periodRange(_ entry: ScheduleEntry) -> ClosedRange<Int>? {
        var first: Int?, last: Int?
        for (index, period) in periods.enumerated() {
            if bridge.overlaps(start: Double(entry.startMinutes), end: Double(entry.endMinutes),
                               otherStart: Double(period.startMinutes), otherEnd: Double(period.endMinutes)) {
                if first == nil { first = index }; last = index
            }
        }
        guard let first, let last else { return nil }
        return first...last
    }
    // 几何只决定屏幕位置；节次相交由 C++ 给结果，泳道按最终可点击区间分配。
    public func layout(weekday: Int, pixelsPerMinute: Double = 1.1, periodRowHeight: Double = 72) -> [SchedulePlacement<ScheduleEntry>] {
        let intervals: [ScheduleInterval<ScheduleEntry>] = visibleEntries.filter { $0.weekday == weekday }.compactMap { entry in
            let top: Double, height: Double
            if displayMode == .period {
                guard let range = periodRange(entry) else { return nil }
                top = Double(range.lowerBound) * (periodRowHeight + 4)
                height = Double(range.count) * (periodRowHeight + 4) - 4
            } else {
                top = Double(entry.startMinutes - axisStartMinutes) * pixelsPerMinute
                height = max(44, Double(entry.durationMinutes) * pixelsPerMinute)
            }
            return ScheduleInterval(entry: entry, start: top, end: top + height, top: top, height: height)
        }
        return ScheduleLayout.place(intervals)
    }
    public func minutesAtOffset(_ offset: Double, pixelsPerMinute: Double = 1.1, periodRowHeight: Double = 72) -> Int {
        if displayMode == .period {
            let index = Int(floor(max(0, offset) / (periodRowHeight + 4)))
            return periods.indices.contains(index) ? periods[index].startMinutes : (periods.first?.startMinutes ?? 480)
        }
        return max(0, min(1435, Int((Double(axisStartMinutes) + offset / pixelsPerMinute) / 5.0 + 0.5) * 5))
    }
    @discardableResult public func saveEntry(_ draft: ScheduleEntry, original: ScheduleEntry?) -> Bool {
        writing = true; defer { writing = false }
        do {
            if let original { try bridge.update(id: original.id, changes: changes(original: original, draft: draft)) }
            else { try bridge.add(draft) }
            refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func changes(original: ScheduleEntry, draft: ScheduleEntry) -> ScheduleChanges {
        var changes = ScheduleChanges()
        if draft.title != original.title { changes.title = draft.title }
        if draft.location != original.location { changes.location = draft.location }
        if draft.weekday != original.weekday { changes.weekday = draft.weekday }
        if draft.startMinutes != original.startMinutes { changes.startMinutes = draft.startMinutes }
        if draft.endMinutes != original.endMinutes { changes.endMinutes = draft.endMinutes }
        if draft.weekStart != original.weekStart { changes.weekStart = draft.weekStart }
        if draft.weekEnd != original.weekEnd { changes.weekEnd = draft.weekEnd }
        if draft.weekParity != original.weekParity { changes.weekParity = draft.weekParity }
        if draft.categoryID != original.categoryID { changes.categoryID = draft.categoryID }
        return changes
    }
    @discardableResult public func deleteEntry(id: Int) -> Bool {
        writing = true; defer { writing = false }
        do { try bridge.delete(id: id); refresh(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    public func conflicts(for entry: ScheduleEntry) throws -> [ScheduleEntry] {
        try bridge.conflicts(weekday: entry.weekday, startMinutes: entry.startMinutes, endMinutes: entry.endMinutes,
                             weekStart: entry.weekStart, weekEnd: entry.weekEnd, parity: entry.weekParity, excluding: entry.id)
    }
    @discardableResult public func saveSettings(_ draft: ScheduleSettings, periods newPeriods: [SchedulePeriod]) -> Bool {
        writing = true; defer { writing = false }
        do {
            // 节次与设置属于不同存储，沿用 Mac 的补偿流程；先读库里的最新节次，失败后恢复它。
            let oldPeriods = try bridge.periods()
            let periodChanged = oldPeriods.count != newPeriods.count || zip(oldPeriods, newPeriods).contains {
                $0.startMinutes != $1.startMinutes || $0.endMinutes != $1.endMinutes
            }
            if periodChanged { try bridge.savePeriods(newPeriods) }
            do { try bridge.saveSettings(draft) }
            catch {
                var message = error.localizedDescription
                if periodChanged {
                    do { try bridge.savePeriods(oldPeriods) }
                    catch { message += "；" + error.localizedDescription }
                }
                self.error = message; return false
            }
            refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
