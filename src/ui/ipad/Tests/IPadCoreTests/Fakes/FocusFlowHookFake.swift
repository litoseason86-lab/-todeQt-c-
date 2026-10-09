import IPadCore

@MainActor final class FocusFlowHookFake: FocusFlowHook {
    var outcome: TaskCompletionFocusOutcome = .none
    var completed: [Int] = []
    var opened: [(Int, String)] = []
    func taskCompleted(taskId: Int) -> TaskCompletionFocusOutcome { completed.append(taskId); return outcome }
    func openTask(taskId: Int, title: String) { opened.append((taskId, title)) }
}
