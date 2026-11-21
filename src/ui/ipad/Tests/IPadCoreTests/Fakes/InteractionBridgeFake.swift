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
    private var activeTokens: Set<UUID> = []
    private var manualBlock = false
    var refreshBlocked: Bool {
        get { manualBlock || !activeTokens.isEmpty }
        set { manualBlock = newValue }
    }
    var lastError = ""
    var error: Error?
    var latest = TaskValue()
    var calls: [(name: String, id: Int, source: String)] = []
    private func releaseToken(_ tokenID: UUID) {
        guard activeTokens.remove(tokenID) != nil else { return }
        onChanged?()
    }
    private func begin(_ name: String, id: Int, source: String) throws -> InteractionToken {
        calls.append((name, id, source)); if let error { throw error }
        let tokenID = UUID()
        activeTokens.insert(tokenID)
        onChanged?()
        let owner = InteractionOwner { [weak self] in
            MainActor.assumeIsolated { self?.releaseToken(tokenID) }
        }
        return InteractionToken(task: name == "edit" ? latest : nil, lifetime: owner, end: { [weak self] in
            self?.releaseToken(tokenID)
        })
    }
    func beginEdit(id: Int, source: String) throws -> InteractionToken { try begin("edit", id: id, source: source) }
    func beginDrag(id: Int, source: String) throws -> InteractionToken { try begin("drag", id: id, source: source) }
}
