import IPadCore
import XCTest

final class SettingsFormatTests: XCTestCase {
    // 产品保证：重复日短标签、选择切换、坏数据回落逐条与 Mac 的共享对照表一致。
    func testRoutineWeekdaysCaliberTable() throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureReader.load("routine-weekdays")) as? [[String: Any]])
        for row in rows {
            let input = try XCTUnwrap(row["input"] as? [String: Int])
            let expected = try XCTUnwrap(row["expected"] as? [String: Any])
            let mask = try XCTUnwrap(input["mask"])
            let bit = try XCTUnwrap(expected["bit"] as? Int)
            XCTAssertEqual(RoutineWeekdaysFormat.text(mask), expected["text"] as? String, "\(row)")
            XCTAssertEqual(RoutineWeekdaysFormat.normalize(mask), expected["normalized"] as? Int)
            XCTAssertEqual(RoutineWeekdaysFormat.toggle(mask, bit: bit), expected["toggled"] as? Int)
        }
    }
}
