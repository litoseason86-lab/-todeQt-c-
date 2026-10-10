import Foundation
import IPadCore
import PTBridge
@MainActor final class RoutineBridgeAdapter: RoutineBridgeProtocol {
    private let native = PTRoutineBridge(); var onChanged: (() -> Void)?; var onFailure: ((String) -> Void)?
    init() { native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }; native.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.onFailure?(message) } } }
    func routines() -> [[String: Any]] { native.routines().map { $0 as! [String: Any] } }; func add(title: String, categoryID: Int, weekdays: Int) throws { try native.addTitle(title, categoryId: categoryID, weekdays: weekdays) }; func update(id: Int, changes: [String: Any]) throws { try native.update(id, changes: changes) }; func delete(id: Int) throws { try native.deleteRoutine(id) }; func setActive(id: Int, active: Bool) throws { try native.setActive(id, active: active) }; func setWeekdays(id: Int, weekdays: Int) throws { try native.setWeekdays(id, weekdays: weekdays) }; func materializeToday() -> Int { native.materializeToday() }
}
