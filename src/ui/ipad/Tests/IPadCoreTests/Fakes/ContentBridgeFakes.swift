import Foundation
import IPadCore

@MainActor final class KnowledgeGapFake: KnowledgeGapBridging {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onTasksAffected: (() -> Void)?
    var rows: [GapValue] = []
    var error: Error?
    var calls: [String] = []
    var filters: [(Int, Int, String)] = []
    var updates: [(Int, GapChanges)] = []
    var dates: [(Int, String)] = []
    func check(_ name: String) throws { calls.append(name); if let error { throw error } }
    func gaps(status: Int, categoryID: Int, search: String) throws -> [GapValue] { try check("read"); filters.append((status, categoryID, search)); return rows }
    func gap(id: Int) throws -> GapValue { try check("gap"); return rows.first { $0.id == id }! }
    func add(title: String, categoryID: Int, detail: String, priority: Int, dueDate: String, sourceTaskID: Int) throws -> Int { try check("add"); return 123 }
    func update(id: Int, changes: GapChanges) throws { try check("update"); updates.append((id, changes)) }
    func schedule(id: Int, date: String) throws { try check("schedule"); dates.append((id, date)) }
    func schedule(ids: [Int], date: String) throws { try check("batch"); dates += ids.map { ($0, date) } }
    func resolve(id: Int, resolution: String) throws { try check("resolve") }
    func reopen(id: Int) throws { try check("reopen") }
    func delete(id: Int) throws { try check("delete") }
    func convert(id: Int, date: String) throws -> Int { try check("convert"); dates.append((id, date)); return 456 }
}
@MainActor final class MemoFake: MemoBridging {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var rows: [MemoValue] = []
    var readError: Error?
    var writeError: Error?
    var failReadAfterCreate = false
    var calls: [String] = []
    var updates: [(Int, MemoChanges)] = []
    var orders: [(Int, [Int])] = []
    var creates: [(String, String, Int)] = []
    var deletes: [Int] = []
    var nextID = 100
    func check(_ name: String) throws { calls.append(name); if let writeError { throw writeError } }
    func memos() throws -> [MemoValue] { calls.append("read"); if let readError { throw readError }; return rows }
    func memo(id: Int) throws -> MemoValue { if let readError { throw readError }; return rows.first { $0.id == id }! }
    func create(title: String, body: String, categoryID: Int) throws -> Int {
        try check("create"); creates.append((title, body, categoryID)); nextID += 1
        var value = MemoValue(); value.id = nextID; value.title = title; value.body = body; value.categoryID = categoryID
        rows.append(value); onChanged?()
        if failReadAfterCreate { readError = NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"]) }
        return nextID
    }
    func update(id: Int, changes: MemoChanges) throws {
        try check("update"); updates.append((id, changes))
        if let i = rows.firstIndex(where: { $0.id == id }) {
            if let title = changes.title { rows[i].title = title }
            if let body = changes.body { rows[i].body = body }
            if let category = changes.categoryID { rows[i].categoryID = category }
        }
        onChanged?()
    }
    func delete(id: Int) throws { try check("delete"); deletes.append(id); rows.removeAll { $0.id == id }; onChanged?() }
    func reorder(categoryID: Int, ids: [Int]) throws { try check("reorder"); orders.append((categoryID, ids)) }
}
@MainActor final class CountdownFake: CountdownBridging {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPrimaryGoalChanged: (() -> Void)?
    var rows: [CountdownValue] = []
    var primary: CountdownValue?
    var error: Error?
    var calls: [String] = []
    var orders: [(Int, Int)] = []
    var updates: [(Int, CountdownChanges)] = []
    func check(_ name: String) throws { calls.append(name); if let error { throw error } }
    func goals() throws -> [CountdownValue] { try check("read"); return rows }
    func primaryGoal() throws -> CountdownValue? { try check("primary"); return primary }
    func add(name: String, date: String) throws { try check("add") }
    func update(id: Int, changes: CountdownChanges) throws { try check("update"); updates.append((id, changes)) }
    func delete(id: Int) throws { try check("delete") }
    func reorder(from: Int, to: Int) throws { try check("reorder"); orders.append((from, to)) }
    func daysRemaining(date: String) -> Int { 37 }
}
