import XCTest
@testable import IPadCore

final class DashboardFormatTests: XCTestCase {
    // 产品保证：问候语的每个小时边界与 Mac DashboardFormat 一致。
    func testGreetingBoundaries() {
        XCTAssertEqual(DashboardFormat.greeting(for: 4), "夜深了")
        XCTAssertEqual(DashboardFormat.greeting(for: 5), "早上好")
        XCTAssertEqual(DashboardFormat.greeting(for: 11), "中午好")
        XCTAssertEqual(DashboardFormat.greeting(for: 13), "下午好")
        XCTAssertEqual(DashboardFormat.greeting(for: 18), "晚上好")
        XCTAssertEqual(DashboardFormat.greeting(for: 23), "夜深了")
    }

    // 产品保证：累计时长按小时显示，百小时后舍弃无意义的小数。
    func testTotalHoursAndDays() {
        XCTAssertEqual(DashboardFormat.totalHoursText(seconds: 3600), "1.0")
        XCTAssertEqual(DashboardFormat.totalHoursText(seconds: 3600 * 101 + 1800), "102")
        XCTAssertEqual(DashboardFormat.equivalentDaysText(seconds: 86400 + 4320), "1.1")
    }
}
