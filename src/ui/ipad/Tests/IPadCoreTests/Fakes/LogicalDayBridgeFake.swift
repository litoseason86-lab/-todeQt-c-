import IPadCore
@MainActor final class LogicalDayBridgeFake: LogicalDayBridgeProtocol {
    var relations: [String: DateRelation] = [:]
    var relationCalls: [(String, String)] = []
    var error: Error?
    func relation(_ date: String, to reference: String) throws -> DateRelation {
        relationCalls.append((date, reference)); if let error { throw error }
        return relations[date + "/" + reference] ?? .earlier
    }
    var today = "2024-02-29" { didSet { calls.append("today"); onChanged?() } }
    var dayStartHour = 4 { didSet { calls.append("dayStartHour"); onChanged?() } }
    var onChanged: (() -> Void)?
    var calls: [String] = []
}
