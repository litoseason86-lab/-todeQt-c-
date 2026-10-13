import Foundation
import IPadCore
import SwiftUI

// 任务详情：宽窗从任务行的 ⓘ 以浮层弹出，窄窗由系统改成整页表单（10-12 对齐提醒事项）。
// 浮层不走系统表单的背景缩放（10-12 真机测速：表单开约 250ms、关约 200ms，浮层约 30ms）。
// 「完成」保存；点浮层外面关掉也保存（提醒事项的做法）；只有「取消」放弃改动。
struct TaskDetailSheet: View {
    let taskID: Int
    private let shell: ShellStore
    private let actions: TaskActions
    @StateObject private var lifetime: TaskDetailLifetime
    private var store: TaskEditorStore { lifetime.store }
    @Environment(\.dismiss) private var dismiss
    init(taskID: Int, core: CoreBridges, shell: ShellStore) {
        self.taskID = taskID; self.shell = shell; self.actions = core.taskActions
        // StateObject 的构造闭包只在浮层身份首次挂载时执行；父行更新不再反复创建随后被丢弃的 Store 与桥接。
        // 编辑登记仍只在 onAppear 开始，不预读任务或提前冻结列表。
        _lifetime = StateObject(wrappedValue: TaskDetailLifetime(core: core, shell: shell))
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
                    Section {
                        LabeledContent("已专注", value: DurationFormat.seconds(Double(store.initialTask?.focusedSeconds ?? 0)))
                        Button("删除任务", role: .destructive) { deleteTask() }
                    }
                }
                if !store.errorMessage.isEmpty {
                    Section {
                        Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                        if !store.active { Button("重试") { _ = store.begin(id: taskID) } }
                    }
                }
            }
            .navigationTitle("详细信息").navigationBarTitleDisplayMode(.inline).sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { store.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { if store.save() { dismiss() } }.fontWeight(.semibold)
                        .disabled(!store.active || shell.operationBlocksUI)
                }
            }
        }
        .tint(ThemeColors.accentInk)
        // 浮层按理想尺寸摆；整页表单时系统忽略这两个值。
        .frame(idealWidth: 400, idealHeight: 600)
        .presentationDetents([.large])
        .disabled(shell.operationBlocksUI)
        .onAppear { if !store.active { _ = store.begin(id: taskID) } }
        // 点外面、下滑关掉都按保存处理；保存失败（例如别处已删掉这条）用提示条说原因，再释放编辑登记。
        .onDisappear {
            guard store.active else { return }
            if !store.save() {
                if !store.errorMessage.isEmpty { shell.showToast(store.errorMessage) }
                store.cancel()
            }
        }
    }
    // 先放弃编辑登记再删：删除走撤销槽，登记还在的话列表要等编辑结束才刷新，那一行不会马上消失。
    private func deleteTask() {
        let title = store.initialTask?.title ?? ""
        store.cancel()
        _ = actions.delete(id: taskID, title: title)
        dismiss()
    }
}

// 只持有浮层的资源生命周期；表单字段继续由 TaskEditorStore 的 Observation（按读取字段订阅变化）更新。
@MainActor private final class TaskDetailLifetime: ObservableObject {
    let store: TaskEditorStore
    init(core: CoreBridges, shell: ShellStore) {
        // 科目变化回调只有一个槽：表单用自己的适配器，不占用 CoreBridges 里共享的那份。
        store = TaskEditorStore(tasks: core.tasks, interactions: core.interactions,
                                categories: CategoryBridgeAdapter(), shell: shell)
    }
}

@MainActor private enum TaskDateInput {
    // 只转换系统日期选择器与服务 ISO 日期的表示，不推导今天、逾期或任务归属。
    static func date(_ iso: String) -> Date { TodayDisplayDate.date(iso) }
    static func iso(_ date: Date) -> String { TodayDisplayDate.iso(date) }
    // 边界是本地日期；与格式器按同一 Foundation 默认时区复用，默认时区改变后下一次读取必须重新解析。
    private static var cachedRange: (timeZone: TimeZone, value: ClosedRange<Date>)?
    static var range: ClosedRange<Date> {
        let timeZone = NSTimeZone.default
        if let cachedRange, cachedRange.timeZone == timeZone { return cachedRange.value }
        let value = date("2000-01-01")...date("2100-12-31")
        cachedRange = (timeZone, value)
        return value
    }
}
