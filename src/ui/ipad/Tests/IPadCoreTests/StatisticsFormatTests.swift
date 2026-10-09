import XCTest
@testable import IPadCore
final class StatisticsFormatTests: XCTestCase {
    private func number(_ value: Any) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? .nan }
        if let special = (value as? [String: String])?["special"] {
            if special == "Infinity" { return .infinity }
            if special == "-Infinity" { return -.infinity }
        }
        // JSON 中 special:NaN 代表 JS 的假值，旧格式函数会先按 0 处理；非数字串保留 NaN。
        return 0
    }
    private func dateString(_ value: Any) -> String {
        (value as? [String: String])?["date"] ?? (value as? String) ?? ""
    }
    // 产品保证：统计格式的 64 个边界逐条与 Mac 共用 P2B 对照表，不另发明显示口径。
    func testStatisticsCaliberFixtures() throws {
        let rows = try JSONSerialization.jsonObject(with: FixtureReader.load("statistics-format")) as! [[String: Any]]
        XCTAssertEqual(rows.count, 64)
        for row in rows {
            let input = row["input"] as! [String: Any], args = input["args"] as! [Any], op = input["op"] as! String
            if op == "levelOf" {
                let actual = StatisticsFormat.levelOf(number(args[0])), expected = row["expected"] as! [String: Any]
                XCTAssertEqual(actual.lv, expected["lv"] as? Int); XCTAssertEqual(actual.min, expected["min"] as? Int)
                XCTAssertEqual(actual.name, expected["name"] as? String)
                continue
            }
            let actual: String
            switch op {
            case "formatDuration": actual = StatisticsFormat.formatDuration(number(args[0]))
            case "decimalHours": actual = StatisticsFormat.decimalHours(number(args[0]))
            case "totalDurationValue": actual = StatisticsFormat.totalDurationValue(number(args[0]))
            case "totalDurationUnit": actual = StatisticsFormat.totalDurationUnit(number(args[0]))
            case "mondayOf": actual = MonthGoalFormat.isoDate(StatisticsFormat.mondayOf(try XCTUnwrap(StatisticsFormat.parseDate(dateString(args[0])))))
            case "endOfWeek": actual = MonthGoalFormat.isoDate(StatisticsFormat.endOfWeek(try XCTUnwrap(StatisticsFormat.parseDate(dateString(args[0])))))
            case "dayStart": actual = MonthGoalFormat.isoDate(StatisticsFormat.dayStart(try XCTUnwrap(StatisticsFormat.parseDate(dateString(args[0])))))
            case "formatWeekRange": actual = StatisticsFormat.formatWeekRange(try XCTUnwrap(StatisticsFormat.parseDate(dateString(args[0]))), try XCTUnwrap(StatisticsFormat.parseDate(dateString(args[1]))))
            case "weekdayLabel": actual = StatisticsFormat.weekdayLabel(dateString(args[0]), index: Int(number(args[1])))
            default: XCTFail("未覆盖对照表操作 \(op)"); continue
            }
            XCTAssertEqual(actual, row["expected"] as? String, "\(op)：\(args)")
        }
    }
    // 产品保证：复盘的分钟与秒显示沿用 Duration.js 的同源对照表，不能混用统计卡格式。
    func testReviewDurationFixtures() throws {
        let rows = try JSONSerialization.jsonObject(with: FixtureReader.load("duration")) as! [[String: Any]]
        var covered = 0
        for row in rows {
            let input = row["input"] as! [String: Any], args = input["args"] as! [Any], op = input["op"] as! String
            guard op == "format" || op == "formatSeconds" else { continue }
            covered += 1
            let actual = op == "format" ? StatisticsFormat.reviewMinutes(number(args[0])) : StatisticsFormat.reviewSeconds(number(args[0]))
            XCTAssertEqual(actual, row["expected"] as? String)
        }
        XCTAssertGreaterThan(covered, 15)
    }
    // 产品保证：复盘事实按登记句式展示，不输出未知类型，也不重复顶部整周总量比较。
    func testReviewFactsMatchQmlSentencesAndUnknownTypesStayHidden() {
        var goal = ReviewFact(); goal.type = "goalShortfall"; goal.date = "2026-09-09"; goal.goalMinutes = 120; goal.actualSeconds = 3600; goal.ratioPercent = 50
        XCTAssertEqual(StatisticsFormat.factText(goal), "9 月 9 日：目标 2 小时，实际 1 小时，投入为目标的 50%。")
        var share = ReviewFact(); share.type = "subjectShareChange"; share.subject = "数学"; share.currentSeconds = 36000
        share.previousSeconds = 21600; share.currentSharePercent = 45.2; share.deltaPoints = -12.4
        XCTAssertEqual(StatisticsFormat.factText(share), "数学：当周 10 小时，前一周 6 小时，占比 45%，比前一周减少 12 个百分点。")
        var estimate = ReviewFact(); estimate.type = "estimateShortfall"; estimate.subject = "英语"; estimate.plannedMinutes = 180
        estimate.actualDisplayMinutes = 60; estimate.shortfallDisplayMinutes = 120
        XCTAssertEqual(StatisticsFormat.factText(estimate), "英语：计划 3 小时，实际 1 小时，差 2 小时。")
        var onTrack = ReviewFact(); onTrack.type = "estimateOnTrack"
        XCTAssertEqual(StatisticsFormat.factText(onTrack), "当周有预计用时的任务，其总投入接近计划。")
        var unknown = ReviewFact(); unknown.type = "somethingNew"
        XCTAssertEqual(StatisticsFormat.factText(unknown), "")
    }
}
