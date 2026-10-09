import IPadCore
import PTBridge

@MainActor final class InteractionBridgeAdapter: InteractionBridgeProtocol {
    var onChanged: (() -> Void)?
    private let bridge = PTInteractionBridge()
    init() {
        // 信号已在 Qt 主线程，进入 MainActor 通知持有交互令牌的页面。
        bridge.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
    }
    var refreshBlocked: Bool { bridge.refreshBlocked }
    var lastError: String { bridge.lastError }
    private func token(_ value: PTInteractionToken) -> InteractionToken {
        InteractionToken(task: value.task.map(TaskBridgeAdapter.value), lifetime: value, end: { value.end() })
    }
    func beginEdit(id: Int, source: String) throws -> InteractionToken { token(try bridge.beginEdit(id, source: source)) }
    func beginDrag(id: Int, source: String) throws -> InteractionToken { token(try bridge.beginDrag(id, source: source)) }
}
