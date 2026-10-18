import IPadCore
@MainActor final class CategoryBridgeFake: CategoryBridgeProtocol {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var result: [CategoryValue] = []
    var createdID = 1
    var deletable = true
    var exists = false
    var error: Error?
    // 删除失败与列表读取分开注入，才能查出刷新成功是否误清了删除原因。
    var deleteError: Error?
    var calls: [(String, Int, String, String)] = []
    private func record(_ name: String, id: Int = -1, text: String = "", color: String = "") throws {
        calls.append((name, id, text, color)); if let error { throw error }
    }
    func allCategories() throws -> [CategoryValue] { try record("allCategories"); return result }
    func category(id: Int) throws -> CategoryValue { try record("category", id: id); return result.first ?? CategoryValue() }
    func add(name: String, color: String) throws -> Int { try record("add", text: name, color: color); return createdID }
    func update(id: Int, name: String, color: String) throws { try record("update", id: id, text: name, color: color) }
    func delete(id: Int) throws {
        try record("delete", id: id)
        if let deleteError { throw deleteError }
    }
    func canDelete(id: Int) -> Bool { calls.append(("canDelete", id, "", "")); return deletable }
    func nameExists(_ name: String, excluding id: Int) -> Bool { calls.append(("nameExists", id, name, "")); return exists }
}
