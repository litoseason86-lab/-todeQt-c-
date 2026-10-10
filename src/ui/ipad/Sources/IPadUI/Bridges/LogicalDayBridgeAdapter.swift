import IPadCore
import PTBridge
@MainActor final class LogicalDayBridgeAdapter: LogicalDayBridgeProtocol {
    private let native = PTLogicalDayBridge()
    private var observers: [() -> Void] = []
    func relation(_ date: String, to reference: String) throws -> DateRelation {
        DateRelation(rawValue: try native.relation(ofDate: date, toDate: reference))!
    }
    func period(anchor: String, range: String, shift: Int, logicalToday: String) throws -> PeriodDates {
        let result = try native.period(forAnchor: anchor, range: range, shift: shift, logicalToday: logicalToday)
        var value = PeriodDates()
        value.start = result.start; value.end = result.end; value.year = result.year; value.month = result.month
        value.comparisonDistance = result.comparisonDistance
        value.current = result.current; value.canAdvance = result.canAdvance
        return value
    }
    var today: String { native.today }
    var dayStartHour: Int { native.dayStartHour }
    var onChanged: (() -> Void)?
    func observeChanges(_ handler: @escaping () -> Void) { observers.append(handler) }
    init() {
        // 统一逻辑日服务在主线程发布失效，页面据此重读。
        native.onChanged = { [weak self] in
            MainActor.assumeIsolated { self?.onChanged?(); self?.observers.forEach { $0() } }
        }
    }
}
