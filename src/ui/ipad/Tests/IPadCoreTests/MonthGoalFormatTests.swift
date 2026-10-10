import XCTest
@testable import IPadCore
final class MonthGoalFormatTests: XCTestCase {
    // 产品保证：历史页时间文字和日期显示逐条符合 Mac 的 P2B 对照表。
    func testCaliberFixtures() throws {
        let rows = try JSONSerialization.jsonObject(with: FixtureReader.load("month-goal-format")) as! [[String: Any]]
        XCTAssertEqual(rows.count, 12)
        for row in rows {
            let input = row["input"] as! [String: Any], args = input["args"] as! [Any]
            let expected = row["expected"] as! String
            if input["op"] as! String == "formatClock" {
                XCTAssertEqual(MonthGoalFormat.formatClock(args[0] as? String), expected)
            } else {
                let dateText = (args[0] as! [String: String])["date"]!
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
                XCTAssertEqual(MonthGoalFormat.isoDate(try XCTUnwrap(formatter.date(from: dateText))), expected)
            }
        }
    }
}
