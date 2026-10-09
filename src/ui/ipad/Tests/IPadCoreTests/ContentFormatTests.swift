import XCTest
@testable import IPadCore

final class ContentFormatTests: XCTestCase {
    // 产品保证：Swift 逐条复用 P2B 的备忘录口径，包括 UTF-16 与拆开代理项的已知缺陷。
    func testMemoFormatCaliberTable() throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureReader.load("memo-format")) as? [[String: Any]])
        let zone = TimeZone(secondsFromGMT: 0)!
        for row in rows {
            let input = try XCTUnwrap(row["input"] as? [String: Any]); let op = try XCTUnwrap(input["op"] as? String); let args = try XCTUnwrap(input["args"] as? [Any])
            switch op {
            case "characterCount": XCTAssertEqual(MemoFormat.characterCount(args[0] as! String), row["expected"] as? Int, "\(row)")
            case "pad": XCTAssertEqual(MemoFormat.pad(args[0] as! Int), row["expected"] as? String)
            case "firstCharacters":
                let actual = MemoFormat.firstCharacters(args[0] as! String, count: args[1] as! Int)
                if let expected = row["expected"] as? [String: [Int]] { XCTAssertEqual(actual.map(Int.init), expected["utf16"]) }
                else { XCTAssertEqual(actual, Array((row["expected"] as! String).utf16)) }
            case "formatUpdatedAt":
                func text(_ arg: Any) -> String { (arg as? [String: String])?["date"] ?? arg as? String ?? "" }
                let date = text(args[0]), now = MemoFormat.parse(text(args[1]), timeZone: zone)
                let actual = now.map { MemoFormat.formatUpdatedAt(date, now: $0, timeZone: zone) } ?? ""
                XCTAssertEqual(actual, row["expected"] as? String, "\(row)")
            default: XCTFail("没有实现的口径：\(op)")
            }
        }
    }
    // 产品保证：空标题的显示与删除确认采用正文首行，纯空白显示新备忘录。
    func testDisplayTitleAndUTF16Boundary() {
        XCTAssertEqual(MemoFormat.shownTitle(title: " ", body: "第一行\n第二行"), "第一行")
        XCTAssertEqual(MemoFormat.shownTitle(title: "", body: "\n第二行"), "新备忘录")
        XCTAssertEqual(MemoFormat.characterCount("🍅"), 2)
    }
}
