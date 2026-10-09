import XCTest
@testable import IPadCore

@MainActor final class CountdownStoreTests: XCTestCase {
    private func goal(_ id: Int, days: Int) -> CountdownValue { var v = CountdownValue(); v.id = id; v.name = "目标\(id)"; v.targetDate = "2026-11-01"; v.daysRemaining = days; return v }
    private func setup() -> (CountdownStore, CountdownFake) {
        let b = CountdownFake(); b.rows = [goal(3, days: 11), goal(1, days: 7), goal(8, days: -2)]; b.primary = b.rows[0]
        let s = CountdownStore(bridge: b, logicalDay: LogicalDayBridgeFake()); s.setActive(true); return (s, b)
    }
    // 产品保证：主目标和其他目标直接来自服务，不按日期二次排序或重算天数。
    func testPrimaryAndListFollowService() {
        let (s, _) = setup(); XCTAssertEqual(s.primary?.id, 3); XCTAssertEqual(s.secondary.map(\.id), [1, 8]); XCTAssertEqual(s.secondary.last?.daysRemaining, -2)
        XCTAssertEqual(CountdownFormat.days(-2), "已过期 2 天")
    }
    // 产品保证：上移、下移和设主目标发服务模型的真实索引，第一项次目标可成为主目标。
    func testMoveAndMakePrimaryIndices() {
        let (s, b) = setup(); XCTAssertTrue(s.move(id: 1, delta: -1)); XCTAssertEqual(b.orders.last?.0, 1); XCTAssertEqual(b.orders.last?.1, 0)
        XCTAssertTrue(s.move(id: 1, delta: 1)); XCTAssertEqual(b.orders.last?.1, 2)
        XCTAssertTrue(s.makePrimary(id: 8)); XCTAssertEqual(b.orders.last?.0, 2); XCTAssertEqual(b.orders.last?.1, 0)
        XCTAssertFalse(s.move(id: 3, delta: -1)); XCTAssertEqual(b.orders.count, 3)
    }
    // 产品保证：新增与部分编辑只调用对应接口，不改字段不写，失败保留原数据和原因。
    func testPartialEditsAndServiceError() {
        let (s, b) = setup(); let old = b.rows[0]; var edited = old; edited.name = "改名"
        XCTAssertTrue(s.save(opened: old, edited: edited)); XCTAssertEqual(b.updates.last?.1, CountdownChanges(name: "改名"))
        XCTAssertTrue(s.save(opened: old, edited: old)); XCTAssertEqual(b.updates.count, 1)
        XCTAssertTrue(s.add(name: "新", date: "2026-10-20")); XCTAssertTrue(b.calls.contains("add"))
        b.error = NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "目标保存失败"])
        XCTAssertFalse(s.save(opened: old, edited: edited)); XCTAssertEqual(s.errorMessage, "目标保存失败"); XCTAssertEqual(s.items.count, 3)
    }
    // 产品保证：倒计时沿用 Mac 直接删除，成功提示已删除，失败不发成功提示。
    func testDeleteAndToast() {
        let (s, b) = setup(); XCTAssertTrue(s.delete(b.rows[1])); XCTAssertTrue(b.calls.contains("delete"))
        XCTAssertEqual(s.lastNotice, "已删除「目标1」")
        b.error = NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "删除失败"])
        XCTAssertFalse(s.delete(b.rows[2])); XCTAssertEqual(s.lastNotice, "已删除「目标1」"); XCTAssertEqual(s.errorMessage, "删除失败")
    }
    // 产品保证：读取失败保留上一份模型并显示重试，成功后清错；日界和模型信号都重查。
    func testReadFailureRetryAndDayChanges() {
        let (s, b) = setup(); b.error = NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])
        s.refresh(); XCTAssertEqual(s.items.count, 3); XCTAssertEqual(s.errorMessage, "读取失败")
        b.error = nil; b.rows = []; b.primary = nil; s.refresh(); XCTAssertTrue(s.items.isEmpty); XCTAssertTrue(s.errorMessage.isEmpty)
        let n = b.calls.count; s.logicalDayChanged(); b.onChanged?(); b.onPrimaryGoalChanged?(); XCTAssertGreaterThan(b.calls.count, n)
        s.setActive(false); b.onFailure?("外部失败"); XCTAssertNotEqual(s.errorMessage, "外部失败")
    }
    // 产品保证：新增默认日期沿用 Mac 的逻辑今日加 30 天，凌晨不改用物理日期。
    func testDefaultDateUsesLogicalToday() {
        XCTAssertEqual(CountdownFormat.defaultDate(logicalToday: "2026-10-09"), "2026-11-08")
    }

}
