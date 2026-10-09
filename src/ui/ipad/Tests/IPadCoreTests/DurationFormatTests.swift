import XCTest
@testable import IPadCore

final class DurationFormatTests: XCTestCase {
    // 产品保证：全部任务用时显示逐条符合 P2B 共用口径表，秒数向下取整到分钟。
    func testDurationCaliberFixture() throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureReader.load("duration")) as? [[String: Any]])
        XCTAssertEqual(rows.count, 23)
        for row in rows {
            let input = try XCTUnwrap(row["input"] as? [String: Any]); let args = try XCTUnwrap(input["args"] as? [Any])
            let op = try XCTUnwrap(input["op"] as? String); let expected = try XCTUnwrap(row["expected"] as? String)
            let arg = try XCTUnwrap(args.first)
            let actual: String
            if let text = arg as? String { actual = DurationFormat.minutes(text) }
            else {
                let number: Double
                if let special = arg as? [String: String] { number = special["special"] == "Infinity" ? .infinity : .nan }
                else if let value = arg as? NSNumber { number = value.doubleValue }
                else { XCTAssertTrue(arg is NSNull); number = 0 }
                actual = op == "formatSeconds" ? DurationFormat.seconds(number) : DurationFormat.minutes(number)
            }
            XCTAssertEqual(actual, expected, "\(op): \(arg)")
        }
    }
}
