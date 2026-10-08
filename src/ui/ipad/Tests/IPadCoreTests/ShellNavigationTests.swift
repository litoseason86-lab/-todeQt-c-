import XCTest
@testable import IPadCore

final class ShellNavigationTests: XCTestCase {
    // 产品保证：侧栏保留有效顺序、补全遗漏入口，废纸篓与设置固定在最后。
    func testOrderKeepsValidPreferenceAndFixedEntries() {
        let result = PageID.ordered(["settings", "memo", "memo", "unknown", "today", "trash"])
        XCTAssertEqual(Array(result.prefix(2)), [.memo, .today])
        XCTAssertEqual(Array(result.suffix(2)), [.trash, .settings])
        XCTAssertEqual(Set(result), Set(PageID.allCases))
        XCTAssertEqual(result.count, PageID.allCases.count)
    }

    // 产品保证：Swift 测试能读取口径输入输出表，后续各页可沿用相同的读取入口。
    func testFixtureCanBeRead() throws {
        struct Row: Decodable { let input: Int; let expected: String; let reason: String }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "display-clock", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        XCTAssertEqual(rows.map(\.input), [65, 3601])
        for row in rows { XCTAssertEqual(ShellDisplay.clock(row.input), row.expected, row.reason) }
        XCTAssertFalse(rows.contains { $0.reason.isEmpty || $0.expected.isEmpty })
    }
}
