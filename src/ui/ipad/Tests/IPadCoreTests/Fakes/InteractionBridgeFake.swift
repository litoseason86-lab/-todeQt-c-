import Foundation
import IPadCore

// 替身 owner 的释放模拟 QObject destroyed，避免依赖真实桥接且覆盖令牌生命周期。
private final class InteractionOwner {
    let ended: @Sendable () -> Void
    init(ended: @escaping @Sendable () -> Void) { self.ended = ended }
    deinit { ended() }
}
@MainActor final class InteractionBridgeFake: InteractionBridgeProtocol {
    var onChanged: (() -> Void)?
    var refreshBlocked = false
    var lastError = ""
    var error: Error?
    var latest = TaskValue()
    var calls: [(name: String, id: Int, source: String)] = []
    private func begin(_ name: String, id: Int, source: String) throws -> InteractionToken {
        calls.append((name, id, source)); if let error { throw error }
        refreshBlocked = true; onChanged?()
        let owner = InteractionOwner { [weak self] in
            MainActor.assumeIsolated { self?.refreshBlocked = false; self?.onChanged?() }
        }
        return InteractionToken(task: name == "edit" ? latest : nil, lifetime: owner, end: { [weak self] in
            self?.refreshBlocked = false; self?.onChanged?()
        })
    }
    func beginEdit(id: Int, source: String) throws -> InteractionToken { try begin("edit", id: id, source: source) }
    func beginDrag(id: Int, source: String) throws -> InteractionToken { try begin("drag", id: id, source: source) }
}
