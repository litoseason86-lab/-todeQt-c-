import Foundation
import XCTest
@testable import IPadCore

final class ScheduleStoreTests: XCTestCase {
    // 产品保证：默认单日取调用方提供的自然星期，周次由服务计算；手动翻周不被刷新拉回本周。
    @MainActor func testNaturalDayAndWeekNavigation() {
        let bridge = ScheduleBridgeFake(); bridge.weekValue = 7
        bridge.settingsValue = ScheduleSettings(semesterStartDate: "2026-08-31", semesterWeeks: 20)
        let store = ScheduleStore(bridge: bridge, settingsBridge: SettingsBridgeFake(), naturalDate: "2026-10-09", naturalWeekday: 5)
        XCTAssertEqual(store.selectedWeekday, 5); XCTAssertEqual(store.weekIndex, 7)
        XCTAssertEqual(bridge.weekInputs.last?.1, "2026-10-09")
        store.goToWeek(9); XCTAssertEqual(bridge.requestedWeeks.last, 9)
        bridge.weekValue = 8; store.updateNaturalDay(date: "2026-10-12", weekday: 1)
        XCTAssertEqual(store.weekIndex, 9)
        store.goToCurrentWeek(); XCTAssertEqual(store.weekIndex, 8)
        bridge.weekValue = 9; store.updateNaturalDay(date: "2026-10-19", weekday: 1)
        XCTAssertEqual(store.weekIndex, 9)
        for day in 1...7 { store.selectWeekday(day); XCTAssertEqual(store.selectedWeekday, day) }
        store.goToWeek(100); XCTAssertEqual(store.weekIndex, 20)
    }
    // 产品保证：节次外课程和隐藏的周末课程分开认领，每门课只出现在一条隐藏原因里。
    @MainActor func testHiddenEntriesAndPeriodFit() {
        let bridge = ScheduleBridgeFake()
        var weekend = ScheduleEntry(); weekend.id = 1; weekend.weekday = 7
        var outside = ScheduleEntry(); outside.id = 2; outside.weekday = 3
        var placed = ScheduleEntry(); placed.id = 3; placed.weekday = 2; placed.startMinutes = 480; placed.endMinutes = 525
        outside.startMinutes = 750; outside.endMinutes = 800
        bridge.entryValues = [weekend, outside, placed]
        bridge.periodValues = [SchedulePeriod(index: 1, startMinutes: 480, endMinutes: 525)]
        bridge.settingsValue.showWeekend = false
        // 替身只把这一组明确的节次命中交给布局，不实现第二套相交业务规则。
        bridge.overlapResult = { start, _, _, _ in start == 480 }
        let store = ScheduleStore(bridge: bridge, settingsBridge: SettingsBridgeFake(), naturalDate: "2026-10-09", naturalWeekday: 5)
        store.setDisplayMode(.period)
        XCTAssertEqual(store.hiddenWeekendEntries.map(\.id), [1])
        XCTAssertEqual(store.unplacedEntries.map(\.id), [2])
        XCTAssertEqual(store.layout(weekday: 2).map { $0.entry.id }, [3])
        store.setDisplayMode(.time); XCTAssertTrue(store.unplacedEntries.isEmpty)
    }
    // 产品保证：任一步读取失败保留整份上一版快照，服务原因可以重试，不把失败画成空课表。
    @MainActor func testReadFailureRetainsSnapshotAndRetries() {
        let bridge = ScheduleBridgeFake(); var row = ScheduleEntry(); row.id = 17; bridge.entryValues = [row]
        let store = ScheduleStore(bridge: bridge, settingsBridge: SettingsBridgeFake(), naturalDate: "2026-10-09", naturalWeekday: 5)
        XCTAssertEqual(store.entries.map(\.id), [17])
        bridge.entryValues = []; bridge.readError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "课表 SQL 原文"])
        bridge.onScheduleChanged?(); XCTAssertEqual(store.entries.map(\.id), [17]); XCTAssertEqual(store.error, "课表 SQL 原文")
        bridge.readError = nil; store.refresh(); XCTAssertTrue(store.entries.isEmpty); XCTAssertEqual(store.error, "")
    }
    // 产品保证：编辑只提交修改字段，明确清空地点和科目不等于未改，失败保留草稿。
    @MainActor func testEntryChangesAndWriteFailure() {
        let bridge = ScheduleBridgeFake(); var original = ScheduleEntry(); original.id = 19; original.title = "旧名"; original.location = "教室"; original.categoryID = 4
        let store = ScheduleStore(bridge: bridge, settingsBridge: SettingsBridgeFake(), naturalDate: "2026-10-09", naturalWeekday: 5)
        var draft = original; draft.title = "新名"; draft.location = ""; draft.categoryID = -1
        bridge.writeError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "课程已被删除"])
        XCTAssertFalse(store.saveEntry(draft, original: original))
        let change = bridge.updates.last!.1
        XCTAssertEqual(change.title, "新名"); XCTAssertEqual(change.location, ""); XCTAssertEqual(change.categoryID, -1)
        XCTAssertNil(change.startMinutes); XCTAssertNil(change.weekday); XCTAssertNil(change.weekParity)
        XCTAssertEqual(draft.title, "新名"); XCTAssertEqual(store.error, "课程已被删除")
        bridge.writeError = nil; XCTAssertTrue(store.saveEntry(draft, original: original))
    }
    // 产品保证：三项设置用一次原子写入，设置失败后已保存的新节次恢复旧表，界面保持原值。
    @MainActor func testSettingsFailureCompensatesPeriods() {
        let bridge = ScheduleBridgeFake()
        bridge.periodValues = [SchedulePeriod(index: 1, startMinutes: 480, endMinutes: 525)]
        let store = ScheduleStore(bridge: bridge, settingsBridge: SettingsBridgeFake(), naturalDate: "2026-10-09", naturalWeekday: 5)
        let old = store.settings, oldPeriods = store.periods
        bridge.settingsError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "设置写盘失败"])
        let changed = ScheduleSettings(semesterStartDate: "2026-09-07", semesterWeeks: 18, showWeekend: false)
        XCTAssertFalse(store.saveSettings(changed, periods: [SchedulePeriod(startMinutes: 600, endMinutes: 645)]))
        XCTAssertEqual(bridge.savedSettings, [changed]); XCTAssertEqual(bridge.savedPeriods.count, 2)
        XCTAssertEqual(bridge.savedPeriods.last, oldPeriods); XCTAssertEqual(store.settings, old)
        XCTAssertEqual(store.error, "设置写盘失败")
        bridge.settingsError = nil; XCTAssertTrue(store.saveSettings(changed, periods: oldPeriods))
        XCTAssertEqual(store.settings, changed)
    }
    // 产品保证：版式写入共用设置服务；失败保留原版式，外部设置变化能更新页面。
    @MainActor func testDisplayModePersistenceAndFailure() {
        let settings = SettingsBridgeFake(); settings.result.scheduleDisplayMode = "period"
        let store = ScheduleStore(bridge: ScheduleBridgeFake(), settingsBridge: settings, naturalDate: "2026-10-09", naturalWeekday: 5)
        XCTAssertEqual(store.displayMode, .period)
        settings.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "版式写盘失败"])
        XCTAssertFalse(store.setDisplayMode(.time)); XCTAssertEqual(store.displayMode, .period)
        XCTAssertEqual(store.error, "版式写盘失败")
        settings.error = nil; XCTAssertTrue(store.setDisplayMode(.time))
        XCTAssertEqual(settings.result.scheduleDisplayMode, "time")
        settings.result.scheduleDisplayMode = "period"; settings.onScheduleDisplayModeChanged?()
        XCTAssertEqual(store.displayMode, .period)
    }
    // 产品保证：空白点击仅预填时间，节次版式使用服务返回的节次起点，课程冲突只作提示。
    @MainActor func testGridPrefillAndConflictForwarding() throws {
        let bridge = ScheduleBridgeFake()
        bridge.periodValues = [SchedulePeriod(index: 1, startMinutes: 600, endMinutes: 645), SchedulePeriod(index: 2, startMinutes: 660, endMinutes: 705)]
        let store = ScheduleStore(bridge: bridge, settingsBridge: SettingsBridgeFake(), naturalDate: "2026-10-09", naturalWeekday: 5)
        XCTAssertEqual(store.minutesAtOffset(11, pixelsPerMinute: 1.1), 490)
        store.setDisplayMode(.period); XCTAssertEqual(store.minutesAtOffset(77), 660)
        var conflict = ScheduleEntry(); conflict.id = 22; bridge.conflictValues = [conflict]
        var draft = ScheduleEntry(); draft.id = 19
        XCTAssertEqual(try store.conflicts(for: draft).map(\.id), [22])
        XCTAssertEqual(bridge.conflictInputs.last?.last, 19)
        XCTAssertTrue(store.saveEntry(draft, original: nil))
    }
    // 产品保证：设置失败且节次补偿也失败时同时显示两个原因，不把部分写入说成全部成功。
    @MainActor func testCompensationFailureKeepsBothReasons() {
        let bridge = ScheduleBridgeFake()
        let store = ScheduleStore(bridge: bridge, settingsBridge: SettingsBridgeFake(), naturalDate: "2026-10-09", naturalWeekday: 5)
        bridge.settingsError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "写盘失败"])
        bridge.periodWriteErrorAfterFirst = NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "节次恢复失败"])
        XCTAssertFalse(store.saveSettings(ScheduleSettings(), periods: [SchedulePeriod(startMinutes: 600, endMinutes: 650)]))
        XCTAssertTrue(store.error.contains("写盘失败")); XCTAssertTrue(store.error.contains("节次恢复失败"))
    }
}
