import IPadCore
import PTBridge
@MainActor final class LogicalDayBridgeAdapter: LogicalDayBridgeProtocol {
    private let native = PTLogicalDayBridge()
    var today: String { native.today }
    var dayStartHour: Int { native.dayStartHour }
    var onChanged: (() -> Void)?
    init() {
        // 统一逻辑日服务在主线程发布失效，页面据此重读。
        native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
    }
}
