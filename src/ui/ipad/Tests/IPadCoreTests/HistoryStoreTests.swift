import XCTest
@testable import IPadCore

@MainActor final class HistoryStoreTests: XCTestCase {
    private func configuredDay() -> LogicalDayBridgeFake {
        let day = LogicalDayBridgeFake()
        day.today = "2024-02-15"
        day.periodHandler = { anchor, _, shift, today in
            var value = PeriodDates(); value.year = 2024
            value.month = shift == -1 ? 1 : shift == 1 ? 3 : Int(anchor.split(separator: "-")[1])!
            value.start = String(format: "2024-%02d-01", value.month)
            value.end = value.month == 2 ? "2024-02-29" : String(format: "2024-%02d-31", value.month)
            value.current = anchor == today; return value
        }
        for n in 1...29 {
            let date = String(format: "2024-02-%02d", n)
            day.relations[date + "/2024-02-15"] = n < 15 ? .earlier : n == 15 ? .same : .later
        }
        return day
    }
    // 产品保证：翻月使用桥接给的年月，闰月有 29 日，日历固定六周且周一为首列。
    func testMonthNavigationAndLeapGrid() {
        let day = configuredDay(), history = FocusHistoryBridgeFake()
        let store = HistoryStore(history: history, logicalDay: day)
        store.setActive(true)
        XCTAssertEqual(store.year, 2024); XCTAssertEqual(store.month, 2)
        XCTAssertEqual(store.cells.count, 42)
        XCTAssertEqual(store.cells.compactMap { $0.date }.count, 29)
        XCTAssertEqual(store.cells[3].date, "2024-02-01")
        store.moveMonth(-1)
        XCTAssertEqual(history.calls.last(where: { $0.0 == "monthSessions" })?.1, [2024, 1])
        XCTAssertEqual(day.periodCalls.last(where: { $0.2 == -1 })?.0, "2024-02-01")
    }
    // 产品保证：未来日是否可点只认桥接结果，系统日期和 Swift 日期大小不能改变结果。
    func testFutureSelectionUsesBridgeResult() {
        let day = configuredDay(), history = FocusHistoryBridgeFake()
        day.relations["2024-02-01/2024-02-15"] = .later
        let store = HistoryStore(history: history, logicalDay: day)
        store.setActive(true)
        XCTAssertEqual(store.selectedDate, "2024-02-15")
        XCTAssertTrue(store.cells.first { $0.date == "2024-02-01" }!.future)
        store.select("2024-02-01")
        XCTAssertEqual(store.selectedDate, "2024-02-15")
        store.select("2024-02-14")
        XCTAssertEqual(store.selectedDate, "2024-02-14")
    }
    // 产品保证：秒数以小数分钟交给 C++ 取档，显示直接使用桥接返回的档位。
    func testBandsConsumeFixtureInputsWithoutSwiftThresholds() throws {
        let rows = try JSONSerialization.jsonObject(with: FixtureReader.load("heatmap-bands")) as! [[String: Any]]
        let finiteRows = rows.filter { $0["input"] is NSNumber }
        XCTAssertEqual(finiteRows.count, 12)
        for row in finiteRows {
            let input = (row["input"] as! NSNumber).doubleValue
            guard input >= 0, input * 60 <= Double(Int.max) else { continue }
            let day = configuredDay(), history = FocusHistoryBridgeFake()
            history.dailyTotals["2024-02-14"] = Int((input * 60).rounded())
            // 故意给与阈值无关的结果，Store 自算档位必然与这个结果不同。
            history.suppliedBand = 2
            let store = HistoryStore(history: history, logicalDay: day)
            store.setActive(true)
            let cell = store.cells.first { $0.date == "2024-02-14" }!
            XCTAssertEqual(cell.band, 2)
            XCTAssertTrue(history.bandInputs.contains(Double(history.dailyTotals["2024-02-14"]!) / 60))
        }
        let day = configuredDay(), history = FocusHistoryBridgeFake()
        history.dailyTotals["2024-02-14"] = 30
        let store = HistoryStore(history: history, logicalDay: day)
        store.setActive(true)
        XCTAssertTrue(history.bandInputs.contains(0.5))
    }
    // 产品保证：清理只在确认后调用服务，取消不写，完成后重读，连续确认不能重复清理。
    func testCleanupNeedsConfirmationThenReloads() {
        let history = FocusHistoryBridgeFake(); history.count = 4
        let store = HistoryStore(history: history, logicalDay: configuredDay())
        store.setActive(true)
        let before = history.calls.filter { $0.0 == "monthSessions" }.count
        store.requestCleanup()
        XCTAssertTrue(store.cleanupConfirmationPresented)
        XCTAssertFalse(history.calls.contains { $0.0 == "cleanupInvalidSessions" })
        store.cancelCleanup(); store.confirmCleanup()
        XCTAssertFalse(history.calls.contains { $0.0 == "cleanupInvalidSessions" })
        store.requestCleanup()
        // 面板收起绑定不代替显式确认意图，隔离系统面板动作与显示状态的先后顺序。
        store.cleanupConfirmationPresented = false
        store.confirmCleanup(); store.confirmCleanup()
        XCTAssertEqual(history.calls.filter { $0.0 == "cleanupInvalidSessions" }.count, 1)
        XCTAssertEqual(history.calls.filter { $0.0 == "monthSessions" }.count, before + 1)
    }
    // 产品保证：跨日界跟随旧今日；用户选的历史日保留；隐藏页收到失效不查询，回来重读。
    func testLogicalBoundaryAndInactiveRefresh() {
        let day = configuredDay(), history = FocusHistoryBridgeFake()
        let store = HistoryStore(history: history, logicalDay: day)
        store.setActive(true)
        day.today = "2024-02-16"
        XCTAssertEqual(store.selectedDate, "2024-02-16")
        store.select("2024-02-14")
        day.today = "2024-02-17"
        XCTAssertEqual(store.selectedDate, "2024-02-14")
        store.setActive(false)
        let before = history.calls.count
        history.onChanged?(); day.today = "2024-02-18"
        XCTAssertEqual(history.calls.count, before)
        store.setActive(true)
        XCTAssertGreaterThan(history.calls.count, before)
    }
    // 产品保证：读取失败保留已显示的月历和记录，重试成功后清除错误。
    func testReadFailureKeepsPreviousSnapshotAndRetry() {
        let day = configuredDay(), history = FocusHistoryBridgeFake()
        history.dailyTotals["2024-02-14"] = 1234
        let store = HistoryStore(history: history, logicalDay: day)
        store.setActive(true)
        let before = store.cells
        XCTAssertFalse(before.isEmpty)
        history.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据库不可读"])
        store.refresh()
        XCTAssertEqual(store.cells, before); XCTAssertEqual(store.errorMessage, "数据库不可读")
        history.error = nil; history.dailyTotals["2024-02-14"] = 5678
        store.refresh()
        XCTAssertEqual(store.errorMessage, "")
        XCTAssertEqual(store.cells.first { $0.date == "2024-02-14" }?.seconds, 5678)
    }
    // 产品保证：历史页经外壳带日期切到今日专注，日期只消费一次；恢复期间不改导航意图。
    func testOpenSelectedDateThroughShell() {
        let shellBridge = ShellBridgeFake(), shell = ShellStore(bridge: ShellBridgeFake())
        let store = HistoryStore(history: FocusHistoryBridgeFake(), logicalDay: configuredDay())
        store.setActive(true); store.select("2024-02-14"); store.openSelectedDay(shell: shell)
        XCTAssertEqual(shell.selection, .todayFocus)
        XCTAssertEqual(shell.consumeRequestedFocusDate(), "2024-02-14")
        XCTAssertNil(shell.consumeRequestedFocusDate())
        shellBridge.snapshot.operationBlocksUI = true
        let blockedShell = ShellStore(bridge: shellBridge)
        store.openSelectedDay(shell: blockedShell)
        XCTAssertNil(blockedShell.requestedFocusDate)
    }
}
