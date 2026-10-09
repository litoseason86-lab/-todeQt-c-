// 日期由 C++ 按统一日界计算；Swift 页面只消费结果，不重复判断逻辑今日。
public enum DateRelation: Int, Sendable { case earlier = -1, same = 0, later = 1 }
public struct PeriodDates: Equatable, Sendable {
    public var start = ""
    public var end = ""
    public var year = 0
    public var month = 0
    public var comparisonDistance = 1
    public var current = false
    public var canAdvance = false
    public init() {}
}
@MainActor public protocol LogicalDayBridgeProtocol: AnyObject {
    func relation(_ date: String, to reference: String) throws -> DateRelation
    func period(anchor: String, range: String, shift: Int, logicalToday: String) throws -> PeriodDates
    var today: String { get }
    var dayStartHour: Int { get }
    var onChanged: (() -> Void)? { get set }
}
