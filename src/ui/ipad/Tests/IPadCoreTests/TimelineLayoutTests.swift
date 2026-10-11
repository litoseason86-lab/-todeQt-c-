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
    func testUnparsableStartIsSkipped() {
        XCTAssertTrue(TimelineLayout.blocks([session("坏数据", seconds: 60)], day: "2026-10-10").isEmpty)
    }
}
