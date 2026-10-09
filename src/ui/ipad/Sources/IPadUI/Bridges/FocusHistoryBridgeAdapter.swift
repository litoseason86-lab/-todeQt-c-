import Foundation
import IPadCore
import PTBridge
@MainActor final class FocusHistoryBridgeAdapter: FocusHistoryBridgeProtocol {
    private let native = PTFocusHistoryBridge()
    var onChanged: (() -> Void)?
    var lastError: String { native.lastError }
    init() {
        // 业务校验与历史变化留在 C++，Swift 只消费主线程回调。
        native.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
    }
    private func checked(_ result: PTFocusHistoryResult) throws -> PTFocusHistoryResult {
        guard result.valid else { throw NSError(domain: "PTFocusHistoryBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error]) }; return result
    }
    private func values(_ result: PTFocusHistoryResult) throws -> [SessionValue] {
        try checked(result).sessions.map { item in
            var value = SessionValue(); value.id = item.sessionId; value.taskID = item.taskId; value.taskTitle = item.taskTitle
            value.startTime = item.startTime; value.endTime = item.endTime; value.durationSeconds = item.durationSeconds
            value.date = item.date; value.isRest = item.isRest; return value
        }
    }
    private func changes(_ value: SessionChanges) -> PTSessionChanges {
        // 仅转非 nil 字段，避免编辑归属时覆写原始秒数、毫秒或暂停跨度。
        let result = PTSessionChanges()
        if let field = value.startTime { result.startTime = field }
        if let field = value.durationSeconds { result.durationSeconds = field }
        if let field = value.task { switch field { case .none: result.taskId = -1; case .selected(let id): result.taskId = id } }
        if let field = value.isRest { result.isRest = field }
        return result
    }
    func monthSessions(year: Int, month: Int) throws -> [SessionValue] { try values(native.monthSessions(year, month: month)) }
    func daySessions(date: String) throws -> [SessionValue] { try values(native.daySessions(date)) }
    func dayTimeline(date: String) throws -> [SessionValue] { try values(native.dayTimeline(date)) }
    func dayTotalDuration(date: String) throws -> Int { try checked(native.dayTotalDuration(date)).count }
    func invalidSessionCount() throws -> Int { try checked(native.invalidSessionCount()).count }
    func taskOptions(date: String) throws -> [SessionTaskOption] {
        try checked(native.taskOptions(date)).taskOptions.map { item in
            var value = SessionTaskOption(); value.taskID = item.taskId; value.title = item.title; return value
        }
    }
    func formatDuration(seconds: Int) -> String { native.formatDuration(seconds) }
    func cleanupInvalidSessions() throws -> Int { try native.cleanupInvalidSessions() }
    func addManualSession(taskID: Int, startTime: String, durationMinutes: Int) throws -> Int { try native.addManualSession(taskID, startTime: startTime, durationMinutes: durationMinutes) }
    func updateSession(id: Int, changes: SessionChanges) throws { try native.updateSession(id, changes: self.changes(changes)) }
    func updateRestSession(id: Int, changes: SessionChanges) throws { try native.updateRestSession(id, changes: self.changes(changes)) }
}
