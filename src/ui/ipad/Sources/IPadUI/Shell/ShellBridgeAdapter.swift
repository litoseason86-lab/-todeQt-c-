import Foundation
import IPadCore
import PTBridge

@MainActor final class ShellBridgeAdapter: ShellBridgeProtocol {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let bridge = PTShellBridge()
    init() {
        // Foundation 桥接的回调由 Qt 主线程上下文派发，明确进入 MainActor，违反约束立即暴露。
        bridge.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        bridge.onFailure = { [weak self] message in
            MainActor.assumeIsolated { self?.onFailure?(message) }
        }
    }
    func read() throws -> ShellSnapshot {
        let value = bridge.read()
        if !value.valid {
            throw NSError(domain: "PTShellBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: value.error])
        }
        var result = ShellSnapshot()
        result.todayPendingCount = value.todayPendingCount
        result.weekPendingCount = value.weekPendingCount
        result.todayFocusedSeconds = value.todayFocusedSeconds
        result.dueGapCount = value.dueGapCount
        result.hasTimer = value.hasTimer
        result.running = value.running
        result.mode = value.mode
        result.phase = value.phase
        result.elapsedSeconds = value.elapsedSeconds
        result.remainingSeconds = value.remainingSeconds
        result.currentTaskId = value.currentTaskId
        result.taskTitle = value.taskTitle
        result.operationBlocksUI = value.operationBlocksUi
        result.operationText = value.operationText
        result.sidebarOrder = value.sidebarOrder
        result.backgroundTheme = value.backgroundTheme
        result.useWallpaper = value.useWallpaper
        result.selectedPage = value.selectedPage
        result.maxCaptureTitleLength = value.maxCaptureTitleLength
        return result
    }
    func pause() -> Bool { bridge.pause() }
    func resume() -> Bool { bridge.resume() }
    func capture(title: String, categoryID: Int, sourceTaskID: Int) -> Int {
        bridge.capture(title: title, categoryID: categoryID, sourceTaskID: sourceTaskID)
    }
    func select(page: String) { bridge.select(page: page) }
}
