import Foundation
import XCTest
@testable import IPadCore

final class ScheduleFormatTests: XCTestCase {
    // 产品保证：课表时分、周次标签和日期显示逐行匹配 Mac 对照表，不自行变更边界口径。
    func testFormatCalibers() throws {
        let rows = try JSONSerialization.jsonObject(with: FixtureReader.load("schedule-format")) as! [[String: Any]]
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let input = row["input"] as! [String: Any]
            let args = input["args"] as! [Any]
            let op = input["op"] as! String
            let expected = row["expected"]!
            switch op {
            case "formatMinutes": XCTAssertEqual(ScheduleFormat.formatMinutes(number(args[0])), expected as? String)
            case "parseMinutes": XCTAssertEqual(ScheduleFormat.parseMinutes(args[0] as? String ?? ""), (expected as! NSNumber).intValue)
            case "parityLabel": XCTAssertEqual(ScheduleFormat.parityLabel(number(args[0])), expected as? String)
            case "weekRangeLabel":
                XCTAssertEqual(ScheduleFormat.weekRangeLabel(start: number(args[0]), end: number(args[1]),
                                                            parity: number(args[2]), semesterWeeks: number(args[3])), expected as? String)
            case "displayDate":
                let actual = ScheduleFormat.displayDate(args[0] as? String ?? "")
                if expected is NSNull { XCTAssertNil(actual) }
                else {
                    XCTAssertNotNil(actual)
                    let calendar = Calendar(identifier: .gregorian)
                    let date = calendar.dateComponents([.year, .month, .day], from: try XCTUnwrap(actual))
                    XCTAssertEqual("\(date.year!)-" + String(format: "%02d-%02d", date.month!, date.day!), expected as? String)
                }
            default: XCTFail("未知课表格式操作：\(op)")
            }
        }
    }
    // 产品保证：泳道按最终绘制区间分簇，紧邻的新簇恢复整宽，上午冲突不缩窄下午课程。
    func testLayoutCalibers() throws {
        let rows = try JSONSerialization.jsonObject(with: FixtureReader.load("schedule-layout")) as! [[String: Any]]
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let input = row["input"] as! [String: Any], args = input["args"] as! [Any]
            let op = input["op"] as! String
            let entries = args[0] as? [[String: Any]] ?? []
            let visual = op == "layoutVisualEntries" || (op == "layoutEntries" && (args[3] as? Bool == true))
            let startRole = op == "layoutEntries" ? args[1] as! String : (visual ? "layoutStart" : "startMinutes")
            let endRole = op == "layoutEntries" ? args[2] as! String : (visual ? "layoutEnd" : "endMinutes")
            let intervals = entries.map { entry in
                ScheduleInterval(entry: visual ? entry["entry"] as! [String: Any] : entry,
                                 start: number(entry[startRole]!), end: number(entry[endRole]!),
                                 top: entry["top"] as? Double ?? 0, height: entry["height"] as? Double ?? 0)
            }
            let actual: [[String: Any]] = ScheduleLayout.place(intervals).map { item in
                var value: [String: Any] = ["entry": item.entry, "lane": item.lane, "laneCount": item.laneCount]
                if visual { value["top"] = item.top; value["height"] = item.height }
                return value
            }
            XCTAssertEqual(actual as NSArray, row["expected"] as! NSArray, row["reason"] as? String ?? "")
        }
    }
    private func number(_ value: Any) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? .nan }
        if value is NSNull { return 0 }
        return .nan
    }
}
