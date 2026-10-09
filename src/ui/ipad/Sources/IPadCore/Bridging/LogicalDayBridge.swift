// 日期由 C++ 按统一日界计算；Swift 页面只消费结果，不重复判断逻辑今日。
@MainActor public protocol LogicalDayBridgeProtocol: AnyObject {
    var today: String { get }
    var dayStartHour: Int { get }
    var onChanged: (() -> Void)? { get set }
}
