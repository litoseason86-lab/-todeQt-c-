import IPadCore
@MainActor final class LogicalDayBridgeFake: LogicalDayBridgeProtocol {
    var relations: [String: DateRelation] = [:]
    var relationCalls: [(String, String)] = []
    var error: Error?
    var observers: [() -> Void] = []
    func relation(_ date: String, to reference: String) throws -> DateRelation {
        relationCalls.append((date, reference)); if let error { throw error }
        return relations[date + "/" + reference] ?? .earlier
    }
    var today = "2024-02-29" { didSet { calls.append("today"); notifyChanged() } }
    var dayStartHour = 4 { didSet { calls.append("dayStartHour"); notifyChanged() } }
    var onChanged: (() -> Void)?
    func observeChanges(_ handler: @escaping () -> Void) { observers.append(handler) }
    func notifyChanged() { onChanged?(); observers.forEach { $0() } }
    var calls: [String] = []
}
