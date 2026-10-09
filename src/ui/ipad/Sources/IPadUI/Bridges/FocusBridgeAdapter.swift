import Foundation
import IPadCore
import PTBridge

@MainActor final class FocusBridgeAdapter: FocusBridgeProtocol {
    var onTick: (() -> Void)?
    var onRunningStateChanged: (() -> Void)?
    var onPhaseChanged: (() -> Void)?
    var onModeChanged: (() -> Void)?
    var onCurrentTaskChanged: (() -> Void)?
    var onCompletedPomodorosChanged: (() -> Void)?
    var onSessionLogicalDateChanged: (() -> Void)?
    var onFreeTimingAllowedChanged: (() -> Void)?
    var onManualRestAllowedChanged: (() -> Void)?
    var onFocusCompleted: ((Int) -> Void)?
    var onRestCompleted: (() -> Void)?
    var onPhaseCompleted: ((Int) -> Void)?
    var onSessionDiscarded: ((Int) -> Void)?
    var onPhaseSettledOffline: ((Int) -> Void)?
    var onTaskAutoCompleteFailed: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?
    private let bridge = PTFocusBridge()
    init() {
        // Objective-C++ 接收上下文保证主线程，适配器只作类型投影和事件转发。
        bridge.onTick = { [weak self] in MainActor.assumeIsolated { self?.onTick?() } }
        bridge.onRunningStateChanged = { [weak self] in MainActor.assumeIsolated { self?.onRunningStateChanged?() } }
        bridge.onPhaseChanged = { [weak self] in MainActor.assumeIsolated { self?.onPhaseChanged?() } }
        bridge.onModeChanged = { [weak self] in MainActor.assumeIsolated { self?.onModeChanged?() } }
        bridge.onCurrentTaskChanged = { [weak self] in MainActor.assumeIsolated { self?.onCurrentTaskChanged?() } }
        bridge.onCompletedPomodorosChanged = { [weak self] in MainActor.assumeIsolated { self?.onCompletedPomodorosChanged?() } }
        bridge.onSessionLogicalDateChanged = { [weak self] in MainActor.assumeIsolated { self?.onSessionLogicalDateChanged?() } }
        bridge.onFreeTimingAllowedChanged = { [weak self] in MainActor.assumeIsolated { self?.onFreeTimingAllowedChanged?() } }
        bridge.onManualRestAllowedChanged = { [weak self] in MainActor.assumeIsolated { self?.onManualRestAllowedChanged?() } }
        bridge.onFocusCompleted = { [weak self] value in MainActor.assumeIsolated { self?.onFocusCompleted?(value) } }
        bridge.onRestCompleted = { [weak self] in MainActor.assumeIsolated { self?.onRestCompleted?() } }
        bridge.onPhaseCompleted = { [weak self] value in MainActor.assumeIsolated { self?.onPhaseCompleted?(value) } }
        bridge.onSessionDiscarded = { [weak self] value in MainActor.assumeIsolated { self?.onSessionDiscarded?(value) } }
        bridge.onPhaseSettledOffline = { [weak self] value in MainActor.assumeIsolated { self?.onPhaseSettledOffline?(value) } }
        bridge.onTaskAutoCompleteFailed = { [weak self] value in MainActor.assumeIsolated { self?.onTaskAutoCompleteFailed?(value) } }
        bridge.onFailure = { [weak self] value in MainActor.assumeIsolated { self?.onFailure?(value) } }
    }
    private func requireValid(_ valid: Bool, _ error: String) throws {
        guard valid else { throw NSError(domain: "PTFocusBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }
    private func value(_ source: PTFocusSnapshot) -> FocusSnapshot {
        var value = FocusSnapshot()
        value.mode = source.mode
        value.phase = source.phase
        value.running = source.running
        value.hasActiveSession = source.hasActiveSession
        value.elapsedSeconds = source.elapsedSeconds
        value.remainingSeconds = source.remainingSeconds
        value.targetSeconds = source.targetSeconds
        value.currentTaskID = source.currentTaskId
        value.currentTaskTitle = source.currentTaskTitle
        value.completedPomodoros = source.completedPomodoros
        value.freeTimingAllowed = source.freeTimingAllowed
        value.manualRestAllowed = source.manualRestAllowed
        value.sessionLogicalDate = source.sessionLogicalDate
        value.minimumValidMinutes = source.minimumValidMinutes
        return value
    }
    private func value(_ source: PTFocusTaskEntry) throws -> FocusTaskEntry {
        try requireValid(source.valid, source.error)
        var value = FocusTaskEntry()
        value.kind = source.kind
        value.usePomodoro = source.usePomodoro
        value.autoStart = source.autoStart
        value.title = source.title
        return value
    }
    private func value(_ source: PTFocusSwitchConsequence) throws -> FocusSwitchConsequence {
        try requireValid(source.valid, source.error)
        var value = FocusSwitchConsequence()
        value.kind = source.kind
        value.minimumMinutes = source.minimumMinutes
        return value
    }
    private func value(_ source: PTFocusSwitchSource) throws -> FocusSwitchSource {
        try requireValid(source.valid, source.error)
        var value = FocusSwitchSource()
        value.taskID = source.taskId
        value.mode = source.mode
        value.phase = source.phase
        return value
    }
    private func value(_ source: PTFocusModeSwitch) throws -> FocusModeSwitch {
        try requireValid(source.valid, source.error)
        var value = FocusModeSwitch()
        value.kind = source.kind
        value.taskID = source.taskId
        value.title = source.title
        return value
    }
    private func value(_ source: PTFocusCandidate) throws -> FocusCandidate {
        try requireValid(source.valid, source.error)
        var value = FocusCandidate()
        value.taskID = source.taskId
        value.title = source.title
        value.selectionStale = source.selectionStale
        return value
    }
    private func value(_ source: PTFocusEndResult) throws -> FocusEndResult {
        try requireValid(source.valid, source.error)
        var value = FocusEndResult()
        value.result = source.result
        value.kind = source.kind
        value.discarded = source.discarded
        value.error = source.error
        return value
    }
    private func value(_ source: PTFocusFinishResult) throws -> FocusFinishResult {
        try requireValid(source.valid, source.error)
        var value = FocusFinishResult()
        value.ok = source.ok
        value.error = source.error
        return value
    }
    private func value(_ source: PTFocusTaskCompletion) throws -> FocusTaskCompletion {
        try requireValid(source.valid, source.error)
        var value = FocusTaskCompletion()
        value.focusResult = source.focusResult
        value.kind = source.kind
        value.discarded = source.discarded
        value.error = source.error
        return value
    }
    var snapshot: FocusSnapshot { value(bridge.snapshot) }
    func startFree(taskID: Int, title: String) throws { try bridge.startFree(taskID, title: title) }
    func startPomodoro(taskID: Int, title: String, seconds: Int) throws { try bridge.startPomodoro(taskID, title: title, seconds: seconds) }
    func pause() throws { try bridge.pause() }
    func resume() throws { try bridge.resume() }
    func startBreak(seconds: Int, taskID: Int, title: String) throws { try bridge.startBreak(seconds, taskId: taskID, title: title) }
    func planTaskEntry(taskID: Int, title: String) throws -> FocusTaskEntry { try value(bridge.planTaskEntry(taskID, title: title)) }
    func switchConsequence() throws -> FocusSwitchConsequence { try value(bridge.switchConsequence()) }
    func captureSwitchSource() throws -> FocusSwitchSource { try value(bridge.captureSwitchSource()) }
    func stopForSwitch(_ source: FocusSwitchSource) throws -> String {
        try bridge.stop(forSwitch: PTFocusSwitchSource(taskId: source.taskID, mode: source.mode, phase: source.phase))
    }
    func planModeSwitch(taskID: Int, title: String) throws -> FocusModeSwitch { try value(bridge.planModeSwitch(taskID, title: title)) }
    func autoStartCandidate(taskID: Int, title: String) throws -> FocusCandidate { try value(bridge.autoStartCandidate(taskID, title: title)) }
    func createTodayTask(title: String) throws -> Int { try bridge.createTodayTask(title) }
    func handleTaskCompleted(taskID: Int) throws -> FocusTaskCompletion { try value(bridge.handleTaskCompleted(taskID)) }
    func freeTimerWarningHours() throws -> Int { try bridge.freeTimerWarningHours() }
    func needsLongFreeStopConfirmation() throws -> Bool { try bridge.needsLongFreeStopConfirmation() }
    func endCurrent() throws -> FocusEndResult { try value(bridge.endCurrent()) }
    func endPomodoroCycle() throws -> FocusEndResult { try value(bridge.endPomodoroCycle()) }
    func finishLongFree(record: Bool, correctedSeconds: Int) throws -> FocusFinishResult { try value(bridge.finishLongFree(record, correctedSeconds: correctedSeconds)) }
}
