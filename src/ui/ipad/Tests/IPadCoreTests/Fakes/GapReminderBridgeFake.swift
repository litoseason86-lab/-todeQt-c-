import Foundation
import IPadCore

@MainActor final class GapReminderBridgeFake: GapReminderBridgeProtocol {
    var onChanged: (() -> Void)?
    var onTasksAffected: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var error: Error?
    // 055-P4-1：只让指定方法失败（摘要读取失败与转换失败是两条不同的路径）。
    var failing: Set<String> = []
    var calls: [(name: String, taskID: Int, title: String, seconds: Int)] = []
    private func record(_ name: String, taskID: Int = -1, title: String = "", seconds: Int = 0) throws {
        calls.append((name, taskID, title, seconds)); if let error { throw error }
        if failing.contains(name) { throw NSError(domain: "测试", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(name) 失败"]) }
    }
    var summary = GapReminderSummary()
    var conversion = GapConversionResult()
    func reminderSummary() throws -> GapReminderSummary { try record("reminderSummary"); return summary }
    func convertDueGapsToTasks() throws -> GapConversionResult { try record("convertDueGapsToTasks"); return conversion }
}
