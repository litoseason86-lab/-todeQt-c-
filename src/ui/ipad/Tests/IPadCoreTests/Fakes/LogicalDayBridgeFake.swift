import IPadCore
@MainActor final class LogicalDayBridgeFake: LogicalDayBridgeProtocol {
    var today = "2024-02-29" { didSet { calls.append("today"); onChanged?() } }
    var dayStartHour = 4 { didSet { calls.append("dayStartHour"); onChanged?() } }
    var onChanged: (() -> Void)?
    var calls: [String] = []
}
