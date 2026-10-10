import IPadCore
@MainActor final class LogicalDayBridgeFake: LogicalDayBridgeProtocol {
    var relations: [String: DateRelation] = [:]
    var periodResult = PeriodDates()
    var periodHandler: ((String, String, Int, String) -> PeriodDates)?
    var relationCalls: [(String, String)] = []
    var periodCalls: [(String, String, Int, String)] = []
    var error: Error?
    func relation(_ date: String, to reference: String) throws -> DateRelation {
        relationCalls.append((date, reference)); if let error { throw error }
        return relations[date + "/" + reference] ?? .earlier
    }
    func period(anchor: String, range: String, shift: Int, logicalToday: String) throws -> PeriodDates {
        periodCalls.append((anchor, range, shift, logicalToday)); if let error { throw error }
        return periodHandler?(anchor, range, shift, logicalToday) ?? periodResult
    }
    var today = "2024-02-29" { didSet { calls.append("today"); onChanged?() } }
    var dayStartHour = 4 { didSet { calls.append("dayStartHour"); onChanged?() } }
    var onChanged: (() -> Void)?
    var calls: [String] = []
}
