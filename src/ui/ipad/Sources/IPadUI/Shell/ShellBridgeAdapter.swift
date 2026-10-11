import Foundation
import IPadCore
import PTBridge

@MainActor final class ShellBridgeAdapter: ShellBridgeProtocol {
    var onChanged: (() -> Void)?
    var onTimerChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let bridge = PTShellBridge()
    init() {
        // Foundation 桥接的回调由 Qt 主线程上下文派发，明确进入 MainActor，违反约束立即暴露。
        // assumeIsolated 对 MainActor 只核对「当前是否主线程」，不要求处在 Swift Task 里：10-11 用 Swift 6 实测，
        // 主线程 CFRunLoop 回调（Qt 在 Apple 平台的事件循环就在这里派发）里连调 20 次不崩，同样调用放到后台线程立即 SIGTRAP。
        // 不能改成 Task { @MainActor in }：退出与进后台的同步保存会变成异步，C++ 可能先关库再保存。
        bridge.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        bridge.onTimerChanged = { [weak self] in MainActor.assumeIsolated { self?.onTimerChanged?() } }
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
        result.appearance = value.appearance
        result.hasPrimaryGoal = value.hasPrimaryGoal
        result.primaryGoalName = value.primaryGoalName
        result.primaryGoalDaysRemaining = value.primaryGoalDaysRemaining
        result.useWallpaper = value.useWallpaper
        result.selectedPage = value.selectedPage
        result.maxCaptureTitleLength = value.maxCaptureTitleLength
        return result
    }
    func readTimer() throws -> ShellTimerSnapshot {
        let value = bridge.readTimer()
        if !value.valid {
            throw NSError(domain: "PTShellBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: value.error])
        }
        var result = ShellTimerSnapshot()
        result.hasTimer = value.hasTimer
        result.running = value.running
        result.mode = value.mode
        result.phase = value.phase
        result.elapsedSeconds = value.elapsedSeconds
        result.remainingSeconds = value.remainingSeconds
        result.currentTaskId = value.currentTaskId
        result.taskTitle = value.taskTitle
        return result
    }
    func selectTheme(_ value: String) throws { try bridge.selectTheme(value) }
    func setAppearance(_ value: String) throws { try bridge.setAppearance(value) }
    func setNativeUI(_ value: Bool) throws { try bridge.setNativeUI(value) }
    func setUseWallpaper(_ value: Bool) throws { try bridge.setUseWallpaper(value) }
    func pause() -> Bool { bridge.pause() }
    func resume() -> Bool { bridge.resume() }
    func capture(title: String, categoryID: Int, sourceTaskID: Int) -> Int {
        bridge.capture(title: title, categoryID: categoryID, sourceTaskID: sourceTaskID)
    }
    func select(page: String) { bridge.select(page: page) }
}
