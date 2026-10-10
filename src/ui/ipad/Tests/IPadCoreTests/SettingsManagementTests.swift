import IPadCore
import XCTest

@MainActor final class SettingsManagementTests: XCTestCase {
    // 产品保证：重名由服务判断，保存失败不关闭科目表单、不丢输入。
    func testCategoryConflictAndFailurePreserveDraft() {
        let bridge = CategoryBridgeFake()
        let store = SettingsCategoryStore(bridge: bridge)
        store.beginNew(); store.name = " 数学 "
        bridge.exists = true
        XCTAssertFalse(store.save())
        XCTAssertTrue(store.editing)
        XCTAssertEqual(store.name, " 数学 ")
        XCTAssertFalse(bridge.calls.contains { $0.0 == "add" })
        bridge.exists = false
        bridge.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据库不可写"])
        XCTAssertFalse(store.save())
        XCTAssertEqual(store.errorMessage, "数据库不可写")
        XCTAssertTrue(store.editing)
    }

    // 产品保证：不能删除的科目连删除调用都不发起，固定能力由服务判断。
    func testCategoryDeletionUsesServiceCapability() {
        let bridge = CategoryBridgeFake(); bridge.deletable = false
        let store = SettingsCategoryStore(bridge: bridge)
        var value = CategoryValue(); value.id = 9
        XCTAssertFalse(store.delete(value))
        XCTAssertTrue(bridge.calls.contains { $0.0 == "canDelete" && $0.1 == 9 })
        XCTAssertFalse(bridge.calls.contains { $0.0 == "delete" })
    }

    // 产品保证：例行编辑只提交改过的字段，未改的科目保留同步更新，星期另存。
    func testRoutineEditOnlyWritesChangedFields() {
        let bridge = SettingsRoutineFake()
        let value = RoutineValue(id: 8, title: "阅读", categoryID: 3, weekdays: 31)
        bridge.values = [value]
        let store = SettingsRoutineStore(bridge: bridge, categories: CategoryBridgeFake())
        store.beginEdit(value); store.title = "阅读两章"
        XCTAssertTrue(store.save())
        XCTAssertEqual(bridge.changes, RoutineChanges(title: "阅读两章"))
        XCTAssertTrue(bridge.weekdayWrites.isEmpty)
        store.beginEdit(value)
        bridge.changes = nil
        XCTAssertTrue(store.save())
        XCTAssertNil(bridge.changes)
        store.beginWeekdays(value); store.weekdays = 96
        XCTAssertTrue(store.saveWeekdays())
        XCTAssertEqual(bridge.weekdayWrites, [96])
        XCTAssertNil(bridge.changes)
    }

    // 产品保证：例行读失败保留旧列表，字段和星期写失败均保留表单。
    func testRoutineFailuresKeepListAndDraft() {
        let bridge = SettingsRoutineFake()
        let value = RoutineValue(id: 8, title: "阅读", categoryID: -1, weekdays: 127)
        bridge.values = [value]
        let store = SettingsRoutineStore(bridge: bridge, categories: CategoryBridgeFake())
        store.reload(); XCTAssertEqual(store.values, [value])
        bridge.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])
        store.reload(); XCTAssertEqual(store.values, [value])
        XCTAssertEqual(store.errorMessage, "读取失败")
        store.beginEdit(value); store.title = "草稿"
        XCTAssertFalse(store.save()); XCTAssertTrue(store.editing); XCTAssertEqual(store.title, "草稿")
        store.beginWeekdays(value); store.weekdays = 0
        XCTAssertFalse(store.saveWeekdays()); XCTAssertTrue(store.editingWeekdays)
        XCTAssertEqual(store.weekdays, 0)
    }
}

@MainActor final class SettingsRoutineFake: RoutineBridgeProtocol {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var values: [RoutineValue] = []
    var error: Error?
    var changes: RoutineChanges?
    var weekdayWrites: [Int] = []
    func routines() throws -> [RoutineValue] { if let error { throw error }; return values }
    func add(title: String, categoryID: Int, weekdays: Int) throws { if let error { throw error } }
    func update(id: Int, changes: RoutineChanges) throws { self.changes = changes; if let error { throw error } }
    func delete(id: Int) throws { if let error { throw error } }
    func setActive(id: Int, active: Bool) throws { if let error { throw error } }
    func setWeekdays(id: Int, weekdays: Int) throws { weekdayWrites.append(weekdays); if let error { throw error } }
    func materializeToday() -> Int { 0 }
}
