import Foundation
import IPadCore
import SwiftUI

struct TaskDetailSheet: View {
    let taskID: Int
    private let shell: ShellStore
    @State private var store: TaskEditorStore
    @Environment(\.dismiss) private var dismiss
    init(taskID: Int, core: CoreBridges, shell: ShellStore) {
        self.taskID = taskID; self.shell = shell
        // 科目变化回调只有一个槽：表单用自己的适配器实例，不占用 CoreBridges 里共享的那份。
        _store = State(initialValue: TaskEditorStore(tasks: core.tasks, interactions: core.interactions, categories: CategoryBridgeAdapter(), shell: shell))
    }
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                if store.active {
                    Section {
                        TextField("标题", text: $store.title).accessibilityLabel("任务标题")
                        TextField("备注", text: $store.notes, axis: .vertical).lineLimit(3...8).accessibilityLabel("任务备注")
                    }
                    Section {
                        DatePicker("日期", selection: Binding(
                            get: { TaskDateInput.date(store.date) }, set: { store.date = TaskDateInput.iso($0) }),
                                   in: TaskDateInput.range, displayedComponents: .date)
                        TaskCategoryPicker(store: store.categories)
                        // 控件沿用 Mac 的 24 小时输入上限；只夹展示值，不改原始基线，未碰该字段就不写回。
                        let estimate = "预计用时：\(DurationFormat.minutes(Double(min(1440, store.estimatedMinutes))))"
                        HStack {
                            Text(estimate)
                            Spacer()
                            AccentStepper(title: estimate, value: Binding(get: { min(1440, store.estimatedMinutes) },
                                                                          set: { store.estimatedMinutes = $0 }), range: 0...1440)
                        }
                    }
                    if store.initialTask?.completed == true {
                        Section("完成记录") {
                            TextField("完成记录", text: $store.completionNote, axis: .vertical).lineLimit(3...10)
                                .accessibilityLabel("完成记录")
                        }
                    }
                }
                if !store.errorMessage.isEmpty {
                    Section {
                        Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                        if !store.active { Button("重试") { _ = store.begin(id: taskID) } }
                    }
                }
            }
            .navigationTitle("任务详情").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { store.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if store.save() { dismiss() } }.disabled(!store.active || shell.snapshot.operationBlocksUI)
                }
            }
        }
        .tint(ThemeColors.accentInk)
        .presentationDetents([.large])
        .interactiveDismissDisabled(store.changes != TaskChanges())
        .disabled(shell.snapshot.operationBlocksUI)
        .onAppear { if !store.active { _ = store.begin(id: taskID) } }
        .onDisappear { store.cancel() }
    }
}

@MainActor private enum TaskDateInput {
    // 只转换系统日期选择器与服务 ISO 日期的表示，不推导今天、逾期或任务归属。
    private static var formatter: DateFormatter {
        let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"; return value
    }
    static func date(_ iso: String) -> Date { formatter.date(from: iso) ?? Date() }
    static func iso(_ date: Date) -> String { formatter.string(from: date) }
    static var range: ClosedRange<Date> { date("2000-01-01")...date("2100-12-31") }
}
