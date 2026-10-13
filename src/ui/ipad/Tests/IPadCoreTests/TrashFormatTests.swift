import IPadCore
import XCTest

final class TrashFormatTests: XCTestCase {
    // 产品保证：废纸篓全部 53 条显示口径逐条与 Mac 共享表一致，分组保持服务次序。
    func testTrashCaliberTable() throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureReader.load("trash-format")) as? [[String: Any]])
        for row in rows {
            let input = try XCTUnwrap(row["input"] as? [String: Any])
            let op = try XCTUnwrap(input["op"] as? String)
            let args = try XCTUnwrap(input["args"] as? [Any])
            let expected = row["expected"]
            func text(_ index: Int) -> String { args[index] as? String ?? "" }
            func map(_ index: Int) -> [String: Any] { args[index] as? [String: Any] ?? [:] }
            switch op {
            case "parseIso":
                let parts = TrashFormat.parseIso(text(0))
                if let expected = expected as? [String: Int] {
                    XCTAssertEqual(parts?.year, expected["year"]); XCTAssertEqual(parts?.month, expected["month"]); XCTAssertEqual(parts?.day, expected["day"])
                } else { XCTAssertNil(parts) }
            case "pad": XCTAssertEqual(TrashFormat.pad(args[0] as! Int), expected as? String)
            case "dateLabel": XCTAssertEqual(TrashFormat.dateLabel(text(0), today: text(1)), expected as? String)
            case "dateLabelWithYear": XCTAssertEqual(TrashFormat.dateLabelWithYear(text(0)), expected as? String)
            case "yesterdayOf": XCTAssertEqual(TrashFormat.yesterdayOf(text(0)), expected as? String)
            case "groupLabel": XCTAssertEqual(TrashFormat.groupLabel(text(0), today: text(1)), expected as? String)
            case "timeOf": XCTAssertEqual(TrashFormat.timeOf(text(0)), expected as? String)
            case "sessionSpan": XCTAssertEqual(TrashFormat.sessionSpan(details(map(0)), today: text(1)), expected as? String)
            case "blockedText": XCTAssertEqual(TrashFormat.blockedText(text(0)), expected as? String)
            case "scheduleParts": XCTAssertEqual(TrashFormat.scheduleParts(details(map(0))), expected as? [String])
            case "metaText": XCTAssertEqual(TrashFormat.metaText(item(map(0)), today: text(1)), expected as? String, "\(row)")
            case "groupHeading":
                let group = map(0)
                XCTAssertEqual(TrashFormat.groupHeading(label: group["label"] as? String ?? "", count: (group["items"] as? [Any])?.count ?? 0), expected as? String)
            case "groupItems":
                let groups = TrashFormat.groupItems((args[0] as! [[String: Any]]).map(item), today: text(1))
                let wanted = expected as! [[String: Any]]
                XCTAssertEqual(groups.count, wanted.count)
                for (actual, wanted) in zip(groups, wanted) {
                    XCTAssertEqual(actual.key, wanted["key"] as? String); XCTAssertEqual(actual.label, wanted["label"] as? String)
                    XCTAssertEqual(actual.remainingLabel, wanted["remaining"] as? String)
                    XCTAssertEqual(actual.items.map(\.id), (wanted["items"] as! [[String: Any]]).map { $0["id"] as! Int })
                }
            case "restoreFailureText":
                let result = map(1)
                XCTAssertEqual(TrashFormat.restoreFailure(item: item(map(0)), result: TrashActionResult(error: result["error"] as? String ?? "", conflict: result["conflict"] as? String ?? ""), today: text(2)), expected as? String)
            default: XCTFail("未实现的废纸篓口径：\(op)")
            }
        }
    }
    private func details(_ map: [String: Any]) -> TrashDetails {
        var value = TrashDetails()
        value.date = map["date"] as? String ?? ""; value.startTime = map["startTime"] as? String ?? ""
        value.endTime = map["endTime"] as? String ?? ""; value.durationSeconds = map["durationSeconds"] as? Int ?? 0
        value.dueDate = map["dueDate"] as? String ?? ""; value.weekdays = map["weekdays"] as? Int ?? 0
        value.weekday = map["weekday"] as? Int ?? 0; value.startMinutes = map["startMinutes"] as? Int
        value.endMinutes = map["endMinutes"] as? Int; value.weekStart = map["weekStart"] as? Int ?? 0
        value.weekEnd = map["weekEnd"] as? Int ?? 0; value.weekParity = map["weekParity"] as? Int ?? 0
        value.location = map["location"] as? String ?? ""; value.targetDate = map["targetDate"] as? String ?? ""
        return value
    }
    private func item(_ map: [String: Any]) -> TrashItem {
        TrashItem(id: map["id"] as? Int ?? 0, kind: map["kind"] as? String ?? "", title: map["title"] as? String ?? "",
            deletedAt: "", deletedDate: map["deletedDate"] as? String ?? "", remainingDays: map["remainingDays"] as? Int ?? 0,
            originSyncID: "", categoryName: map["categoryName"] as? String ?? "", categoryColor: "",
            restorable: map["restorable"] as? Bool ?? true, blockedReason: map["blockedReason"] as? String ?? "",
            details: details(map["details"] as? [String: Any] ?? [:]))
    }
    // 产品保证：日期标签只拆 ASCII 日期前缀，不校验日历合法性；非 ASCII 数字和未补零日期不能误入。
    func testDatePrefixPreservesDisplayOnlyBoundaries() {
        let parts = TrashFormat.parseIso("0001-99-00T中文后缀")
        XCTAssertEqual(parts?.year, 1); XCTAssertEqual(parts?.month, 99); XCTAssertEqual(parts?.day, 0)
        XCTAssertEqual(TrashFormat.dateLabel("2024-02-29T12:30", today: "2025-01-01"), "2024年2月29日")
        for invalid in ["２０２４-02-29", "2024-٠٢-29", "2024-2-29", "2024-02-2", "x2024-02-29", "2024/02/29", ""] {
            XCTAssertNil(TrashFormat.parseIso(invalid), invalid)
        }
    }
}
