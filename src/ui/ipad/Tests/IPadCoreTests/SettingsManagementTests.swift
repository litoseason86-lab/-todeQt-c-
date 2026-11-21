import IPadCore
import XCTest

@MainActor final class SettingsManagementTests: XCTestCase {
    // 产品保证：重名由服务判断，保存失败不关闭科目表单、不丢输入。
    func testCategoryConflictAndFailurePreserveDraft() {
        let bridge = CategoryBridgeFake()
        let store = SettingsCategoryStore(bridge: bridge); store.setActive(true)
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

    // 产品保证：服务拒绝删除时显示服务给出的原因并刷新列表，重试成功后清空原因。
    func testCategoryDeletionShowsServiceReasonAndReloads() {
        let bridge = CategoryBridgeFake(); bridge.deletable = false
        var value = CategoryValue(); value.id = 9
        var remaining = CategoryValue(); remaining.id = 10
        bridge.result = [value, remaining]
        let store = SettingsCategoryStore(bridge: bridge); store.setActive(true)
        store.reload()
        XCTAssertEqual(store.values, [value, remaining])
        bridge.result = [remaining]
        bridge.deleteError = NSError(domain: "test", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "删除科目失败：科目不存在"])
        bridge.calls.removeAll()
        XCTAssertFalse(store.delete(value))
        XCTAssertEqual(bridge.calls.map { $0.0 }, ["delete", "allCategories"])
        XCTAssertEqual(bridge.calls.first?.1, value.id)
        XCTAssertEqual(store.errorMessage, "删除科目失败：科目不存在")
        XCTAssertEqual(store.values, [remaining])

        bridge.deleteError = nil
        bridge.result = []
        bridge.calls.removeAll()
        XCTAssertTrue(store.delete(remaining))
        XCTAssertEqual(bridge.calls.map { $0.0 }, ["delete", "allCategories"])
        XCTAssertEqual(bridge.calls.first?.1, remaining.id)
        XCTAssertEqual(store.errorMessage, "")
        XCTAssertEqual(store.values, [])
    }

    // 产品保证：例行编辑只提交改过的字段，未改的科目保留同步更新，星期另存。
    func testRoutineEditOnlyWritesChangedFields() {
        let bridge = SettingsRoutineFake()
        let value = RoutineValue(id: 8, title: "阅读", categoryID: 3, weekdays: 31)
        bridge.values = [value]
        let store = SettingsRoutineStore(bridge: bridge, categories: CategoryBridgeFake()); store.setActive(true)
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
        let store = SettingsRoutineStore(bridge: bridge, categories: CategoryBridgeFake()); store.setActive(true)
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

    // 产品保证：科目与每日例行设置子页未激活时不响应后台变更查库，也不把后台失败写进隐藏子页错误状态。
    func testInactiveCategoryAndRoutineStoresIgnoreBackgroundSignals() {
        let categoryBridge = CategoryBridgeFake()
        let categoryStore = SettingsCategoryStore(bridge: categoryBridge)
        XCTAssertTrue(categoryBridge.calls.isEmpty)
        categoryBridge.onFailure?("后台科目失败")
        categoryBridge.onChanged?()
        XCTAssertTrue(categoryBridge.calls.isEmpty)
        XCTAssertEqual(categoryStore.errorMessage, "")
        categoryStore.setActive(true)
        XCTAssertEqual(categoryBridge.calls.map(\.0), ["allCategories"])
        categoryStore.setActive(false)
        categoryBridge.onFailure?("离开后失败")
        XCTAssertEqual(categoryStore.errorMessage, "")

        let routineBridge = SettingsRoutineFake()
        let routineCategories = CategoryBridgeFake()
        let routineStore = SettingsRoutineStore(bridge: routineBridge, categories: routineCategories)
        routineBridge.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "后台例行读失败"])
        routineBridge.onChanged?()
        routineBridge.onFailure?("后台例行写失败")
        routineCategories.onChanged?()
        XCTAssertEqual(routineStore.errorMessage, "")
        routineBridge.error = nil
        routineBridge.values = [RoutineValue(id: 3, title: "晨读", categoryID: -1, weekdays: 127)]
        routineStore.setActive(true)
        XCTAssertEqual(routineStore.values.map(\.id), [3])
        routineStore.setActive(false)
        routineBridge.onFailure?("离开后例行失败")
        XCTAssertEqual(routineStore.errorMessage, "")
    }

    // 产品保证：科目编辑仅提交实际修改的字段（仅改色不提交旧名且跳过重名查询、仅改名不提交旧色、无改动不写库），取消编辑清空残留错误，canDelete 按编号缓存并在 reload 后刷新。
    func testCategoryFieldLevelChangesAndCancelClearsErrorAndCachesCanDelete() {
        let bridge = CategoryBridgeFake()
        var cat = CategoryValue(); cat.id = 5; cat.name = "数学"; cat.color = "#C97A63"
        bridge.result = [cat]
        let store = SettingsCategoryStore(bridge: bridge); store.setActive(true)
        bridge.calls.removeAll()

        // 1. 仅改颜色：不查 nameExists，只提交 color 字段，不覆盖远端可能已改的新名称。
        store.beginEdit(cat)
        store.color = "#7D9B76"
        XCTAssertTrue(store.save())
        XCTAssertFalse(bridge.calls.contains { $0.0 == "nameExists" })
        XCTAssertEqual(bridge.lastChanges, CategoryChanges(name: nil, color: "#7D9B76"))

        // 2. 仅改名称：查一次 nameExists，只提交 name 字段。
        bridge.calls.removeAll(); bridge.lastChanges = nil
        store.beginEdit(cat)
        store.name = "高等数学"
        XCTAssertTrue(store.save())
        XCTAssertTrue(bridge.calls.contains { $0.0 == "nameExists" })
        XCTAssertEqual(bridge.lastChanges, CategoryChanges(name: "高等数学", color: nil))

        // 3. 无改动保存：直接收起表单，不调 updateChanges。
        bridge.calls.removeAll(); bridge.lastChanges = nil
        store.beginEdit(cat)
        XCTAssertTrue(store.save())
        XCTAssertNil(bridge.lastChanges)
        XCTAssertFalse(bridge.calls.contains { $0.0 == "updateChanges" || $0.0 == "update" })

        // 4. 取消表单清空错误；canDelete 同轮重复求值命中缓存，reload 后重新查询。
        store.beginNew(); store.name = ""
        XCTAssertFalse(store.save())
        XCTAssertFalse(store.errorMessage.isEmpty)
        store.cancel()
        XCTAssertEqual(store.errorMessage, "")

        bridge.calls.removeAll()
        XCTAssertTrue(store.canDelete(cat))
        XCTAssertTrue(store.canDelete(cat))
        XCTAssertEqual(bridge.calls.filter { $0.0 == "canDelete" }.count, 1)
        store.reload()
        XCTAssertTrue(store.canDelete(cat))
        XCTAssertEqual(bridge.calls.filter { $0.0 == "canDelete" }.count, 2)
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
