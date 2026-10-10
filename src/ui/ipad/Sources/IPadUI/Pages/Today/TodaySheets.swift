import IPadCore
import SwiftUI

// 改期：只选新日期，写入与失败提示交给 TodayStore。
struct TodayRescheduleSheet: View {
    let taskID: Int
    let store: TodayStore
    @State private var date = Date()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("新日期", selection: $date, displayedComponents: .date)
                if !store.loadError.isEmpty { Text(store.loadError).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("改期").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("改期") { if store.reschedule(id: taskID, date: TodayDisplayDate.iso(date)) { dismiss() } }
                }
            }
        }
        .tint(ThemeColors.accentInk)
        .presentationDetents([.medium])
        .onAppear { date = TodayDisplayDate.date(store.today) }
    }
}

// 每日目标：目标写在逻辑今日名下，日期由 Store 决定。
struct TodayGoalSheet: View {
    let store: TodayStore
    @State private var minutes = 60
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Stepper("目标：\(DurationFormat.minutes(Double(minutes)))", value: $minutes, in: 0...1440, step: 5)
                if !store.loadError.isEmpty { Text(store.loadError).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("今日专注目标").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if store.saveGoal(minutes: minutes) { dismiss() } }
                }
            }
        }
        .tint(ThemeColors.accentInk)
        .presentationDetents([.medium])
        .onAppear { if store.goalMinutes > 0 { minutes = store.goalMinutes } }
    }
}

// 草稿保存在 Store，服务拒绝时不关闭表单，也不覆盖用户输入。
struct TodayNewTaskSheet: View {
    @Bindable var store: TodayStore
    let categories: any CategoryBridgeProtocol
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("标题（必填）", text: $store.newTitle)
                Picker("科目", selection: $store.newCategoryID) {
                    Text("无科目").tag(-1)
                    ForEach(store.newCategories, id: \.id) { Text($0.name).tag($0.id) }
                }
                Stepper("预计用时：\(store.newEstimatedMinutes) 分钟", value: $store.newEstimatedMinutes, in: 0...1440, step: 5)
                TextField("备注", text: $store.newNotes, axis: .vertical)
                if !store.newFormError.isEmpty { Text(store.newFormError).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("新建任务").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { _ = store.submitNewTask() }
                        .disabled(store.newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.task { store.loadNewCategories(from: categories) }
    }
}
