import Foundation
import XCTest
@testable import IPadCore

@MainActor final class LogicalDateNavigationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }

    // 产品保证：空串和非法日期退回桥接给出的逻辑今天，合法日期仍保持原日且不读取兜底。
    func testDateFallbackUsesLogicalTodayAndPreservesValidDate() throws {
        let naturalToday = calendar.startOfDay(for: Date())
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: naturalToday))
        var logicalToday = LogicalDateNavigation.isoDate(previousDay)
        XCTAssertNotEqual(logicalToday, LogicalDateNavigation.isoDate(naturalToday))
        let originalProvider = LogicalDateNavigation.logicalTodayProvider
        defer { LogicalDateNavigation.logicalTodayProvider = originalProvider }
        var reads = 0
        // 注入一个与手机自然日不同的日期，不依赖测试恰好在凌晨运行；结束后还原共享入口。
        LogicalDateNavigation.logicalTodayProvider = { reads += 1; return logicalToday }
        for invalid in ["", "不是日期", "2026-02-30", "2026-13-01"] {
            XCTAssertNil(LogicalDateNavigation.date(invalid))
            XCTAssertEqual(LogicalDateNavigation.isoDate(LogicalDateNavigation.dateOrLogicalToday(invalid)), logicalToday, invalid)
        }
        XCTAssertEqual(reads, 4)
        let valid = "2024-02-29"
        XCTAssertNotNil(LogicalDateNavigation.date(valid))
        XCTAssertEqual(LogicalDateNavigation.isoDate(LogicalDateNavigation.dateOrLogicalToday(valid)), valid)
        XCTAssertEqual(reads, 4)
        // 逻辑日变化后再次求值须重读 provider，不能缓存装配时的那一天。
        logicalToday = "2024-03-01"
        XCTAssertEqual(LogicalDateNavigation.isoDate(LogicalDateNavigation.dateOrLogicalToday("")), logicalToday)
        XCTAssertEqual(reads, 5)
    }

    // 产品保证：补录日期缺失或非法时初值是逻辑今天上午九点，合法历史日期仍取原日九点。
    func testInitialSessionStartUsesLogicalTodayAtNine() throws {
        let naturalToday = calendar.startOfDay(for: Date())
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: naturalToday))
        let logicalToday = LogicalDateNavigation.isoDate(previousDay)
        XCTAssertNotEqual(logicalToday, LogicalDateNavigation.isoDate(naturalToday))
        let originalProvider = LogicalDateNavigation.logicalTodayProvider
        defer { LogicalDateNavigation.logicalTodayProvider = originalProvider }
        LogicalDateNavigation.logicalTodayProvider = { logicalToday }
        for (input, expected) in [("", logicalToday), ("日期损坏", logicalToday), ("2026-02-30", logicalToday), ("2024-02-29", "2024-02-29")] {
            let value = LogicalDateNavigation.initialSessionStart(date: input)
            XCTAssertEqual(LogicalDateNavigation.isoDate(value), expected, input)
            XCTAssertEqual(calendar.component(.hour, from: value), 9)
            XCTAssertEqual(calendar.component(.minute, from: value), 0)
            XCTAssertEqual(calendar.component(.second, from: value), 0)
        }
    }

    // 产品保证：仅当输入和逻辑今日都不能解析时才用当前时间兜底，补录初值仍是该自然日九点。
    func testInvalidLogicalTodayKeepsLastResortAvailable() {
        let originalProvider = LogicalDateNavigation.logicalTodayProvider
        defer { LogicalDateNavigation.logicalTodayProvider = originalProvider }
        for invalid in ["", "日期损坏", "2026-02-30"] {
            LogicalDateNavigation.logicalTodayProvider = { invalid }
            let before = Date()
            let fallback = LogicalDateNavigation.dateOrLogicalToday("")
            let after = Date()
            XCTAssertGreaterThanOrEqual(fallback, before)
            XCTAssertLessThanOrEqual(fallback, after)
            let beforeDay = LogicalDateNavigation.isoDate(Date())
            let start = LogicalDateNavigation.initialSessionStart(date: "")
            let afterDay = LogicalDateNavigation.isoDate(Date())
            // 若测试正好跨过午夜，前后任一天都合法，不能把系统换日当产品失败。
            XCTAssertTrue([beforeDay, afterDay].contains(LogicalDateNavigation.isoDate(start)))
            XCTAssertEqual(calendar.component(.hour, from: start), 9)
        }
    }
}
