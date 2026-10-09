import Foundation
import IPadCore

@MainActor final class FocusBridgeFake: FocusBridgeProtocol {
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
    var error: Error?
    var calls: [(name: String, taskID: Int, title: String, seconds: Int)] = []
    private func record(_ name: String, taskID: Int = -1, title: String = "", seconds: Int = 0) throws {
        calls.append((name, taskID, title, seconds)); if let error { throw error }
    }
    var focusSnapshot = FocusSnapshot()
    var focusTaskEntry = FocusTaskEntry()
    var focusSwitchConsequence = FocusSwitchConsequence()
    var focusSwitchSource = FocusSwitchSource()
    var focusModeSwitch = FocusModeSwitch()
    var focusCandidate = FocusCandidate()
    var focusEndResult = FocusEndResult()
    var focusFinishResult = FocusFinishResult()
    var focusTaskCompletion = FocusTaskCompletion()
    var snapshot: FocusSnapshot { focusSnapshot }
    var createdID = -1
    var switchResult = "stopped"
    var switchSources: [FocusSwitchSource] = []
    var warningHours = 8
    var needsConfirmation = false
    var recordedLongFree: [Bool] = []
    func startFree(taskID: Int, title: String) throws { try record("startFree", taskID: taskID, title: title) }
    func startPomodoro(taskID: Int, title: String, seconds: Int) throws { try record("startPomodoro", taskID: taskID, title: title, seconds: seconds) }
    func pause() throws { try record("pause") }
    func resume() throws { try record("resume") }
    func startBreak(seconds: Int, taskID: Int, title: String) throws { try record("startBreak", taskID: taskID, title: title, seconds: seconds) }
    func planTaskEntry(taskID: Int, title: String) throws -> FocusTaskEntry { try record("planTaskEntry", taskID: taskID, title: title); return focusTaskEntry }
    func switchConsequence() throws -> FocusSwitchConsequence { try record("switchConsequence"); return focusSwitchConsequence }
    func captureSwitchSource() throws -> FocusSwitchSource { try record("captureSwitchSource"); return focusSwitchSource }
    func stopForSwitch(_ source: FocusSwitchSource) throws -> String { switchSources.append(source); try record("stopForSwitch"); return switchResult }
    func planModeSwitch(taskID: Int, title: String) throws -> FocusModeSwitch { try record("planModeSwitch", taskID: taskID, title: title); return focusModeSwitch }
    func autoStartCandidate(taskID: Int, title: String) throws -> FocusCandidate { try record("autoStartCandidate", taskID: taskID, title: title); return focusCandidate }
    func createTodayTask(title: String) throws -> Int { try record("createTodayTask", title: title); return createdID }
    func handleTaskCompleted(taskID: Int) throws -> FocusTaskCompletion { try record("handleTaskCompleted", taskID: taskID); return focusTaskCompletion }
    func freeTimerWarningHours() throws -> Int { try record("freeTimerWarningHours"); return warningHours }
    func needsLongFreeStopConfirmation() throws -> Bool { try record("needsLongFreeStopConfirmation"); return needsConfirmation }
    func endCurrent() throws -> FocusEndResult { try record("endCurrent"); return focusEndResult }
    func endPomodoroCycle() throws -> FocusEndResult { try record("endPomodoroCycle"); return focusEndResult }
    func finishLongFree(record keep: Bool, correctedSeconds: Int) throws -> FocusFinishResult { recordedLongFree.append(keep); try record("finishLongFree", seconds: correctedSeconds); return focusFinishResult }
}
