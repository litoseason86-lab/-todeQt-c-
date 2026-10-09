import Foundation
import IPadCore
import PTBridge

@MainActor final class GapReminderBridgeAdapter: GapReminderBridgeProtocol {
    var onChanged: (() -> Void)?
    var onTasksAffected: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let bridge = PTGapReminderBridge()
    init() {
        // Objective-C++ 接收上下文保证主线程，适配器只作类型投影和事件转发。
        bridge.onChanged = { [weak self] in MainActor.assumeIsolated { self?.onChanged?() } }
        bridge.onTasksAffected = { [weak self] in MainActor.assumeIsolated { self?.onTasksAffected?() } }
        bridge.onFailure = { [weak self] value in MainActor.assumeIsolated { self?.onFailure?(value) } }
    }
    private func requireValid(_ valid: Bool, _ error: String) throws {
        guard valid else { throw NSError(domain: "PTGapReminderBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }
    private func value(_ source: PTGapReminderSummary) throws -> GapReminderSummary {
        try requireValid(source.valid, source.error)
        var value = GapReminderSummary()
        value.dueToday = source.dueToday
        value.overdue = source.overdue
        value.unscheduled = source.unscheduled
        value.openTotal = source.openTotal
        value.oldestOverdueDays = source.oldestOverdueDays
        return value
    }
    private func value(_ source: PTGapConversionResult) throws -> GapConversionResult {
        try requireValid(source.valid, source.error)
        var value = GapConversionResult()
        value.converted = source.converted
        value.failed = source.failed
        value.reason = source.reason
        return value
    }
    func reminderSummary() throws -> GapReminderSummary { try value(bridge.reminderSummary()) }
    func convertDueGapsToTasks() throws -> GapConversionResult { try value(bridge.convertDueGapsToTasks()) }
}
