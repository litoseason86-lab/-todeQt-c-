import Foundation
import IPadCore
import PTBridge

@MainActor final class CountdownAdapter: CountdownBridging {
    private let native = PTCountdownBridge()
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPrimaryGoalChanged: (() -> Void)?
    init() {
        // Qt 已排回主线程，适配器只转发并投影字段，不拆业务字典。
        native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        native.onPrimaryGoalChanged = { [weak self] in MainActor.assumeIsolated { self?.onPrimaryGoalChanged?() } }
        native.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } }
    }
    private func values(_ result: PTCountdownResult) throws -> [CountdownValue] {
        guard result.valid else { throw NSError(domain: "PTBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }
        return result.items.map { item in
            var value = CountdownValue()
            value.id = item.goalId
            value.name = item.name
            value.targetDate = item.targetDate
            value.displayOrder = item.displayOrder
            value.daysRemaining = item.daysRemaining
            value.createdAt = item.createdAt
            value.updatedAt = item.updatedAt
            return value
        }
    }
    private func changes(_ value: CountdownChanges) -> PTCountdownChanges {
        let result = PTCountdownChanges()
        if let field = value.name { result.name = field }
        if let field = value.targetDate { result.targetDate = field }
        return result
    }
    func goals() throws -> [CountdownValue] { try values(native.goals()) }
    func primaryGoal() throws -> CountdownValue? { try values(native.primaryGoal()).first }
    func add(name: String, date: String) throws { try native.addName(name, date: date) }
    func update(id: Int, changes value: CountdownChanges) throws { try native.updateGoal(id, changes: changes(value)) }
    func delete(id: Int) throws { try native.deleteGoal(id) }
    func reorder(from: Int, to: Int) throws { try native.reorder(from: from, to: to) }
    func daysRemaining(date: String) -> Int { native.daysRemaining(date) }
}
