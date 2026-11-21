import IPadCore
import SwiftUI

struct TaskCompletionNoteSheet: View {
    let taskID: Int
    private let shell: ShellStore
    @State private var store: TaskCompletionNoteStore
    @Environment(\.dismiss) private var dismiss
    init(taskID: Int, core: CoreBridges, shell: ShellStore) {
        self.taskID = taskID; self.shell = shell
        _store = State(initialValue: TaskCompletionNoteStore(interactions: core.interactions, actions: core.taskActions, shell: shell))
    }
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                if let task = store.task, store.active {
                    Section { Text(task.title).foregroundStyle(ThemeColors.inkStrong) }
                    Section("完成记录") {
                        TextField("这次完成了什么（可不写）", text: $store.note, axis: .vertical)
                            .lineLimit(4...12).accessibilityLabel("完成记录")
                    }
                }
                if !store.errorMessage.isEmpty {
                    Section {
                        Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                        if !store.active { Button("重试") { _ = store.begin(id: taskID) } }
                    }
                }
            }
            .navigationTitle("完成任务").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { store.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { if store.save() { dismiss() } }.disabled(!store.active || shell.operationBlocksUI)
                }
            }
        }
        .tint(ThemeColors.accentInk)
        // 带文本输入的表单统一用全高，规避窄窗半高表单弹键盘时的系统自动布局崩溃（见 TodaySheets.swift）。
        .presentationDetents([.large])
        .interactiveDismissDisabled(store.active && store.note != store.task?.completionNote)
        .disabled(shell.operationBlocksUI)
        .onAppear { if !store.active { _ = store.begin(id: taskID) } }
        .onChange(of: shell.databaseGeneration) { _, _ in store.cancel(); dismiss() }
        .onDisappear { store.cancel() }
    }
}
