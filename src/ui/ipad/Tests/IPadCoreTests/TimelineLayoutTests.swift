import XCTest
@testable import IPadCore

final class TimelineLayoutTests: XCTestCase {
    private func session(_ start: String, seconds: Int, rest: Bool = false) -> SessionValue {
        var value = SessionValue(); value.startTime = start; value.durationSeconds = seconds; value.isRest = rest
        return value
    }

    // 产品保证：色块按服务给的开始时刻与时长定位，次日凌晨（逻辑日内）的记录接在 24 点之后，不跑到当天开头。
    func testBlocksUseStartAndDurationAndContinuePastMidnight() {
        let blocks = TimelineLayout.blocks([session("2026-10-10T08:30:00", seconds: 45 * 60),
                                            session("2026-10-11T01:15:00", seconds: 30 * 60, rest: true)],
                                           day: "2026-10-10")
        XCTAssertEqual(blocks.map(\.startMinute), [8 * 60 + 30, 25 * 60 + 15])
        XCTAssertEqual(blocks.map(\.endMinute), [9 * 60 + 15, 25 * 60 + 45])
        XCTAssertTrue(blocks[1].session.isRest)
    }

    // 产品保证：没有记录时刻度是 8:00–20:00；更早、更晚或进行中的那段会把刻度扩到包住它的偶数整点。
    func testHourRangeDefaultsAndExpandsToEvenHours() {
        XCTAssertEqual(TimelineLayout.hourRange([]), 8...20)
        let blocks = TimelineLayout.blocks([session("2026-10-10T06:40:00", seconds: 20 * 60),
                                            session("2026-10-10T21:10:00", seconds: 30 * 60)], day: "2026-10-10")
        XCTAssertEqual(TimelineLayout.hourRange(blocks), 6...22)
        XCTAssertEqual(TimelineLayout.hourRange([], extraMinutes: [23 * 60 + 5]), 8...24)
    }

    // 产品保证：解析不了的时刻不画，不把它当成 0 点。
    // 产品保证：夏令时切换日（当天 23 或 25 小时）色块与时间文字仍按本地墙钟定位：09:00 的记录就在 9 点，
    // 次日凌晨 01:00 仍接在 24 点之后（25 点）。
    func testDaylightSavingDaysUseWallClock() throws {
        // 测试进程默认是本机时区（上海，无夏令时），用例无法区分「墙钟分钟」和「绝对经过分钟」；
        // 临时把进程时区换成有夏令时的洛杉矶。只改 NSTimeZone.default 不影响 TimeZone.current（10-11 实测），
        // 要改 TZ 环境变量并让 Foundation 重读系统时区；结束后原样还原。
        let saved = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", "America/Los_Angeles", 1); NSTimeZone.resetSystemTimeZone()
        defer {
            if let saved { setenv("TZ", saved, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        try XCTSkipUnless(TimeZone.current.identifier == "America/Los_Angeles", "无法切换进程时区，用例前提不成立")
        XCTAssertEqual(TimelineLayout.minute(of: "2026-03-08T09:00:00.000", day: "2026-03-08"), 9 * 60)
        XCTAssertEqual(TimelineLayout.minute(of: "2026-11-01T09:00:00.000", day: "2026-11-01"), 9 * 60)
        XCTAssertEqual(TimelineLayout.minute(of: "2026-03-09T01:00:00.000", day: "2026-03-08"), 25 * 60)
        XCTAssertEqual(TimelineLayout.minute(of: "2026-11-02T01:00:00.000", day: "2026-11-01"), 25 * 60)
    }

    func testUnparsableStartIsSkipped() {
        XCTAssertTrue(TimelineLayout.blocks([session("坏数据", seconds: 60)], day: "2026-10-10").isEmpty)
    }
}
