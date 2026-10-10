import IPadCore
@MainActor final class FocusHistoryBridgeFake: FocusHistoryBridgeProtocol {
    var onChanged: (() -> Void)?
    var lastError = ""
    var sessions: [SessionValue] = []
    var options: [SessionTaskOption] = []
    var dailyTotals: [String: Int] = [:]
    var count = 0
    var createdID = 1
    var formattedDuration = ""
    var error: Error?
    var calls: [(String, [Int], [String])] = []
    var submittedChanges: [(Int, Bool, SessionChanges)] = []
    private func record(_ name: String, numbers: [Int] = [], text: [String] = []) throws { calls.append((name, numbers, text)); if let error { throw error } }
    func monthSessions(year: Int, month: Int) throws -> [SessionValue] { try record("monthSessions", numbers: [year, month]); return sessions }
    func daySessions(date: String) throws -> [SessionValue] { try record("daySessions", text: [date]); return sessions }
    func dayTimeline(date: String) throws -> [SessionValue] { try record("dayTimeline", text: [date]); return sessions }
    func dayTotalDuration(date: String) throws -> Int { try record("dayTotalDuration", text: [date]); return dailyTotals[date] ?? count }
    func invalidSessionCount() throws -> Int { try record("invalidSessionCount"); return count }
    func taskOptions(date: String) throws -> [SessionTaskOption] { try record("taskOptions", text: [date]); return options }
    // 替身只返回配置结果，不复制 C++ 取档阈值；测试据此识别 Store 是否绕过桥接。
    var suppliedBand = -1
    var bandInputs: [Double] = []
    func bandForMinutes(_ minutes: Double) -> Int { bandInputs.append(minutes); return suppliedBand }
    func formatDuration(seconds: Int) -> String { calls.append(("formatDuration", [seconds], [])); return formattedDuration }
    func cleanupInvalidSessions() throws -> Int { try record("cleanupInvalidSessions"); return count }
    func addManualSession(taskID: Int, startTime: String, durationMinutes: Int) throws -> Int { try record("addManualSession", numbers: [taskID, durationMinutes], text: [startTime]); return createdID }
    func updateSession(id: Int, changes: SessionChanges) throws { submittedChanges.append((id, false, changes)); try record("updateSession", numbers: [id]) }
    func updateRestSession(id: Int, changes: SessionChanges) throws { submittedChanges.append((id, true, changes)); try record("updateRestSession", numbers: [id]) }
}
