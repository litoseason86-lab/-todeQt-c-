import Foundation

// Store 持有令牌表示交互持续；令牌释放由桥接 owner 的 destroyed 信号结束登记。
@MainActor public final class InteractionToken {
    public let task: TaskValue?
    private var endAction: (() -> Void)?
    private let lifetime: AnyObject?
    public init(task: TaskValue?, lifetime: AnyObject? = nil, end: @escaping () -> Void) {
        self.task = task; self.lifetime = lifetime; self.endAction = end
    }
    public func end() { let action = endAction; endAction = nil; action?() }
}
@MainActor public protocol InteractionBridgeProtocol: AnyObject {
    var onChanged: (() -> Void)? { get set }
    var refreshBlocked: Bool { get }
    var lastError: String { get }
    func beginEdit(id: Int, source: String) throws -> InteractionToken
    func beginDrag(id: Int, source: String) throws -> InteractionToken
}
