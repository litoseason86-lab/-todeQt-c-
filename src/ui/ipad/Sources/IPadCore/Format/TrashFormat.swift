import Foundation

public enum TrashFormat {
    public struct DateParts: Equatable, Sendable { public let year: Int; public let month: Int; public let day: Int }
    private static let typeNames = ["task": "任务", "focus_session": "专注记录", "rest_session": "休息记录",
        "knowledge_gap": "知识缺口", "memo": "备忘录", "routine": "每日例行", "schedule_entry": "课表", "countdown_goal": "倒计时"]
    // 展示层只拆 ISO 前缀，不替服务校验日期；与 TrashFormat.js 和共享对照表保持一致。
    public static func parseIso(_ text: String) -> DateParts? {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) != nil else { return nil }
        let parts = text.prefix(10).split(separator: "-")
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return DateParts(year: year, month: month, day: day)
    }
    public static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
    public static func dateLabel(_ iso: String, today: String) -> String {
        guard let parts = parseIso(iso) else { return "" }
        let core = "\(parts.month)月\(parts.day)日"
        return parseIso(today)?.year == parts.year ? core : "\(parts.year)年" + core
    }
    public static func dateLabelWithYear(_ iso: String) -> String {
        guard let parts = parseIso(iso) else { return "" }
        return "\(parts.year)年\(parts.month)月\(parts.day)日"
    }
    public static func yesterdayOf(_ today: String) -> String {
        guard let parts = parseIso(today) else { return "" }
        // 仅拼分组文案：重写 JS 的 Date.UTC 前一天，不参与业务日期归属；UTC 避开夏令时。
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = (0...99).contains(parts.year) ? parts.year + 1900 : parts.year
        guard let date = calendar.date(from: DateComponents(year: year, month: parts.month, day: parts.day - 1)) else { return "" }
        let moved = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = moved.year, let month = moved.month, let day = moved.day else { return "" }
        return "\(year)-\(pad(month))-\(pad(day))"
    }
    public static func groupLabel(_ deletedDate: String, today: String) -> String {
        guard !deletedDate.isEmpty, parseIso(deletedDate) != nil else { return "删除时间不详" }
        if deletedDate == today { return "今天" }
        if deletedDate == yesterdayOf(today) { return "昨天" }
        return dateLabel(deletedDate, today: today)
    }
    public static func groupItems(_ items: [TrashItem], today: String) -> [TrashGroup] {
        var groups: [TrashGroup] = []; var positions: [String: Int] = [:]
        for item in items {
            let key = item.deletedDate
            if let index = positions[key] {
                let group = groups[index]
                groups[index] = TrashGroup(key: key, label: group.label, remainingLabel: group.remainingLabel, items: group.items + [item])
            } else {
                // 保持服务排序，剩余天数取同组第一条；不重新按标题或日期排序。
                positions[key] = groups.count
                groups.append(TrashGroup(key: key, label: groupLabel(key, today: today),
                    remainingLabel: key.isEmpty ? "" : "还剩 \(item.remainingDays) 天", items: [item]))
            }
        }
        return groups
    }
    public static func groupHeading(label: String, count: Int) -> String { "\(label) · \(count)" }
    public static func timeOf(_ iso: String) -> String {
        guard iso.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}", options: .regularExpression) != nil else { return "" }
        return String(iso.dropFirst(11).prefix(5))
    }
    public static func sessionSpan(_ details: TrashDetails, today: String) -> String {
        let date = dateLabel(details.startTime, today: today)
        let start = timeOf(details.startTime), end = timeOf(details.endTime)
        let clock = !start.isEmpty && !end.isEmpty ? start + "–" + end : start
        return [date, clock].filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func blockedText(_ reason: String) -> String {
        switch reason { case "corrupted": "内容已损坏，无法恢复"; case "needsUpdate": "需要更新应用后才能恢复"; default: "" }
    }
    public static func scheduleParts(_ details: TrashDetails) -> [String] {
        var parts: [String] = []
        if (1...7).contains(details.weekday) { parts.append(RoutineWeekdaysFormat.names[details.weekday - 1]) }
        if let start = details.startMinutes, let end = details.endMinutes {
            let clock = scheduleTime(start) + "–" + scheduleTime(end)
            if parts.isEmpty { parts.append(clock) } else { parts[0] += " " + clock }
        }
        if details.weekStart > 0 && details.weekEnd > 0 {
            parts.append(details.weekStart == details.weekEnd ? "第 \(details.weekStart) 周" : "第 \(details.weekStart)–\(details.weekEnd) 周")
        }
        if details.weekParity == 1 { parts.append("单周") }
        if details.weekParity == 2 { parts.append("双周") }
        if !details.location.isEmpty { parts.append(details.location) }
        return parts
    }
    private static func scheduleTime(_ value: Int) -> String {
        let safe = max(0, min(1440, value))
        return pad(safe / 60) + ":" + pad(safe % 60)
    }
    public static func metaText(_ item: TrashItem, today: String) -> String {
        let details = item.details; var parts = [typeNames[item.kind] ?? ""]
        let reason = item.restorable ? "" : blockedText(item.blockedReason)
        if !reason.isEmpty { parts.append(reason) }
        else {
            switch item.kind {
            case "task": parts += [dateLabel(details.date, today: today), item.categoryName]
            case "focus_session": parts += [sessionSpan(details, today: today), DurationFormat.seconds(Double(details.durationSeconds)), item.categoryName]
            case "rest_session": parts += [sessionSpan(details, today: today), DurationFormat.seconds(Double(details.durationSeconds))]
            case "memo": parts.append(item.categoryName)
            case "knowledge_gap":
                let due = dateLabel(details.dueDate, today: today)
                parts += [item.categoryName, due.isEmpty ? "" : "计划 " + due]
            case "routine": parts += [item.categoryName, RoutineWeekdaysFormat.text(details.weekdays)]
            case "schedule_entry": parts += scheduleParts(details)
            case "countdown_goal": parts.append(dateLabelWithYear(details.targetDate))
            default: break
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    public static func restoreFailure(item: TrashItem, result: TrashActionResult, today: String) -> String {
        let span = result.conflict.isEmpty ? "" : sessionSpan(item.details, today: today)
        return "没能恢复「\(item.title)」：" + (span.isEmpty ? "" : span + " ") + result.error
    }
}
