import Foundation

public struct FocusSnapshot: Equatable, Sendable {
    public var mode: Int = 0
    public var phase: Int = 0
    public var running: Bool = false
    public var hasActiveSession: Bool = false
    public var elapsedSeconds: Int = 0
    public var remainingSeconds: Int = 0
    public var targetSeconds: Int = 0
    public var currentTaskID: Int = -1
    public var currentTaskTitle: String = ""
    public var completedPomodoros: Int = 0
    public var freeTimingAllowed: Bool = true
    public var manualRestAllowed: Bool = false
    public var sessionLogicalDate: String = ""
    // 会话真实开始的本地墙钟串（服务给出，含暂停前的那一段）；没有会话时为空。
    public var sessionStartTime: String = ""
    public var minimumValidMinutes: Int = 3
    public init() {}
}
public struct FocusTaskEntry: Equatable, Sendable {
    public var kind: String = "invalid"
    public var usePomodoro: Bool = false
    public var autoStart: Bool = false
    public var title: String = ""
    public init() {}
}
public struct FocusSwitchConsequence: Equatable, Sendable {
    public var kind: String = ""
    public var minimumMinutes: Int = 3
    public init() {}
}
public struct FocusSwitchSource: Equatable, Sendable {
    public var taskID: Int = -1
    public var mode: Int = 0
    public var phase: Int = 0
    public init() {}
}
public struct FocusModeSwitch: Equatable, Sendable {
    public var kind: String = "pageOnly"
    public var taskID: Int = -1
    public var title: String = ""
    public init() {}
}
public struct FocusCandidate: Equatable, Sendable {
    public var taskID: Int = -1
    public var title: String = ""
    public var selectionStale: Bool = false
    public init() {}
}
public struct FocusEndResult: Equatable, Sendable {
    public var result: String = "none"
    public var kind: String = ""
    public var discarded: Bool = false
    public var error: String = ""
    public init() {}
}
public struct FocusFinishResult: Equatable, Sendable {
    public var ok: Bool = false
    public var error: String = ""
    public init() {}
}
public struct FocusTaskCompletion: Equatable, Sendable {
    public var focusResult: String = "none"
    public var kind: String = ""
    public var discarded: Bool = false
    public var error: String = ""
    public init() {}
}
// 业务分流只读控制器结果；这些值对象不在 Swift 重新推导计时规则。
@MainActor public protocol FocusBridgeProtocol: AnyObject {
    var onTick: (() -> Void)? { get set }
    var onRunningStateChanged: (() -> Void)? { get set }
    var onPhaseChanged: (() -> Void)? { get set }
    var onModeChanged: (() -> Void)? { get set }
    var onCurrentTaskChanged: (() -> Void)? { get set }
    var onCompletedPomodorosChanged: (() -> Void)? { get set }
    var onSessionLogicalDateChanged: (() -> Void)? { get set }
    var onFreeTimingAllowedChanged: (() -> Void)? { get set }
    var onManualRestAllowedChanged: (() -> Void)? { get set }
    var onFocusCompleted: ((Int) -> Void)? { get set }
    var onRestCompleted: (() -> Void)? { get set }
    var onPhaseCompleted: ((Int) -> Void)? { get set }
    var onSessionDiscarded: ((Int) -> Void)? { get set }
    var onPhaseSettledOffline: ((Int) -> Void)? { get set }
    var onTaskAutoCompleteFailed: ((Int) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    // 移动端提示：到点提醒没预约成功、系统通知没发出（参数是原因）。
    var onAlarmUnavailable: ((String) -> Void)? { get set }
    var onNotificationDeliveryFailed: ((String) -> Void)? { get set }
    var snapshot: FocusSnapshot { get }
    func startFree(taskID: Int, title: String) throws
    func startPomodoro(taskID: Int, title: String, seconds: Int) throws
    func pause() throws
    func resume() throws
    func startBreak(seconds: Int, taskID: Int, title: String) throws
    func planTaskEntry(taskID: Int, title: String) throws -> FocusTaskEntry
    func switchConsequence() throws -> FocusSwitchConsequence
    func captureSwitchSource() throws -> FocusSwitchSource
    func stopForSwitch(_ source: FocusSwitchSource) throws -> String
    func planModeSwitch(taskID: Int, title: String) throws -> FocusModeSwitch
    func autoStartCandidate(taskID: Int, title: String) throws -> FocusCandidate
    func createTodayTask(title: String) throws -> Int
    func handleTaskCompleted(taskID: Int) throws -> FocusTaskCompletion
    func freeTimerWarningHours() throws -> Int
    func needsLongFreeStopConfirmation() throws -> Bool
    // 长休息与自动衔接的判定在 C++（FocusSessionController），Swift 不读设置自己算。
    func nextBreakMinutes(selected: Int) throws -> Int
    func autoAdvanceAfter(phase: Int) throws -> Bool
    func endCurrent() throws -> FocusEndResult
    func endPomodoroCycle() throws -> FocusEndResult
    func finishLongFree(record: Bool, correctedSeconds: Int) throws -> FocusFinishResult
}
