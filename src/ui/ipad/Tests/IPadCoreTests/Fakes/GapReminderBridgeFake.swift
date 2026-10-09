import Foundation
import IPadCore

@MainActor final class GapReminderBridgeFake: GapReminderBridgeProtocol {
    var onChanged: (() -> Void)?
    var onTasksAffected: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var error: Error?
    var calls: [(name: String, taskID: Int, title: String, seconds: Int)] = []
    private func record(_ name: String, taskID: Int = -1, title: String = "", seconds: Int = 0) throws {
        calls.append((name, taskID, title, seconds)); if let error { throw error }
    }
    var summary = GapReminderSummary()
    var conversion = GapConversionResult()
    func reminderSummary() throws -> GapReminderSummary { try record("reminderSummary"); return summary }
    func convertDueGapsToTasks() throws -> GapConversionResult { try record("convertDueGapsToTasks"); return conversion }
}
