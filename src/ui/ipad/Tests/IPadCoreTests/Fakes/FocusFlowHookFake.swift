import IPadCore

@MainActor final class FocusFlowHookFake: FocusFlowHook {
    var outcome: TaskCompletionFocusOutcome = .none
    var outcomes: [Int: TaskCompletionFocusOutcome] = [:]
    var completed: [Int] = []
    var opened: [(Int, String)] = []
    func taskCompleted(taskId: Int) -> TaskCompletionFocusOutcome { completed.append(taskId); return outcomes[taskId] ?? outcome }
    func openTask(taskId: Int, title: String) { opened.append((taskId, title)) }
}
