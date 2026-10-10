import Foundation
import Observation

public struct TrashGroup: Equatable, Identifiable {
    public let key: String
    public let label: String
    public let remainingLabel: String
    public let items: [TrashItem]
    public var id: String { key }
}

@MainActor @Observable public final class TrashStore {
    public private(set) var items: [TrashItem] = []
    public private(set) var today = ""
    public private(set) var loaded = false
    public private(set) var loadError = ""
    public private(set) var actionError = ""
    public private(set) var restoredTitle = ""
    public private(set) var pendingDelete: TrashItem?
    public private(set) var pendingEmptyIDs: [Int]?
    @ObservationIgnored private let bridge: any TrashBridgeProtocol
    @ObservationIgnored private var active = false

    public init(bridge: any TrashBridgeProtocol) {
        self.bridge = bridge
        bridge.onChanged = { [weak self] in if self?.active == true { self?.reload() } }
    }

    public var groups: [TrashGroup] {
        var result: [TrashGroup] = []
        var positions: [String: Int] = [:]
        for item in items {
            let key = item.deletedDate
            if let index = positions[key] { result[index] = TrashGroup(key: key, label: result[index].label,
                remainingLabel: result[index].remainingLabel, items: result[index].items + [item]) }
            else {
                let label = Self.groupLabel(key, today: today)
                let remaining = key.isEmpty ? "" : "还剩 \(item.remainingDays) 天"
                positions[key] = result.count
                result.append(TrashGroup(key: key, label: label, remainingLabel: remaining, items: [item]))
            }
        }
        return result
    }

    public func activate() { active = true; actionError = ""; do { _ = try bridge.purgeExpired() } catch { actionError = error.localizedDescription }; reload() }
    public func deactivate() { active = false }
    public func reload() {
        do {
            let result = try bridge.readItems()
            items = result.items; today = result.today; loaded = true; loadError = ""
        } catch { loadError = error.localizedDescription }
    }
    public func retry() { reload() }
    public func restore(_ item: TrashItem) {
        do {
            let result = try bridge.restore(id: item.id)
            if result.error.isEmpty { restoredTitle = result.title.isEmpty ? item.title : result.title; actionError = ""; reload() }
            else { actionError = Self.restoreFailure(item: item, result: result, today: today); if result.code == "gone" { reload() } }
        } catch { actionError = error.localizedDescription }
    }
    public func requestDelete(_ item: TrashItem) { pendingDelete = item }
    public func cancelDelete() { pendingDelete = nil }
    public func confirmDelete() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        do { let result = try bridge.delete(id: item.id); finish(result) }
        catch { actionError = error.localizedDescription }
    }
    public func requestEmpty() { guard !items.isEmpty else { return }; pendingEmptyIDs = items.map(\.id) }
    public func cancelEmpty() { pendingEmptyIDs = nil }
    public func confirmEmpty() {
        guard let ids = pendingEmptyIDs else { return }
        pendingEmptyIDs = nil
        do { finish(try bridge.empty(ids: ids)) }
        catch { actionError = error.localizedDescription }
    }
    private func finish(_ result: TrashActionResult) {
        if result.error.isEmpty { actionError = ""; reload() }
        else { actionError = result.error; if result.code == "gone" { reload() } }
    }

    public static func restoreFailure(item: TrashItem, result: TrashActionResult, today: String) -> String {
        let reason = result.error
        let conflict = result.conflict.isEmpty ? "" : sessionSpan(item.details, today: today) + " "
        return "没能恢复「\(item.title)」：\(conflict)\(reason)"
    }
    public static func groupLabel(_ deletedDate: String, today: String) -> String {
        guard parseDate(deletedDate) != nil else { return "删除时间不详" }
        guard parseDate(today) != nil else { return dateLabel(deletedDate, today: "") }
        if deletedDate == today { return "今天" }
        if yesterday(of: today) == deletedDate { return "昨天" }
        return dateLabel(deletedDate, today: today)
    }
    private static func sessionSpan(_ details: TrashDetails, today: String) -> String {
        let date = dateLabel(String(details.startTime.prefix(10)), today: today)
        let start = time(details.startTime); let end = time(details.endTime)
        let clock = !start.isEmpty && !end.isEmpty ? "\(start)–\(end)" : start
        return [date, clock].filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func time(_ value: String) -> String {
        guard value.count >= 16 else { return "" }
        let chars = Array(value)
        return chars[11...15].contains(":") ? String(chars[11...15]) : ""
    }
    private static func dateLabel(_ value: String, today: String) -> String {
        guard let date = parseDate(value) else { return "" }
        let currentYear = parseDate(today)?.year
        let core = "\(date.month)月\(date.day)日"
        return currentYear == date.year ? core : "\(date.year)年\(core)"
    }
    private static func yesterday(of value: String) -> String {
        guard let parts = parseDate(value) else { return "" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents(); components.calendar = calendar; components.timeZone = calendar.timeZone
        components.year = parts.year; components.month = parts.month; components.day = parts.day
        guard let date = calendar.date(from: components), let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return "" }
        let moved = calendar.dateComponents([.year, .month, .day], from: yesterday)
        guard let year = moved.year, let month = moved.month, let day = moved.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
    private static func parseDate(_ value: String) -> (year: Int, month: Int, day: Int)? {
        guard value.count >= 10 else { return nil }
        let text = Array(value.prefix(10))
        guard text.count == 10, text[4] == "-", text[7] == "-",
              let year = Int(String(text[0..<4])), let month = Int(String(text[5..<7])),
              let day = Int(String(text[8..<10])), year > 0, (1...12).contains(month) else { return nil }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        return (year, month, day)
    }
}
