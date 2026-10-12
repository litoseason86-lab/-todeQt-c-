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
            .navigationTitle("改期").sheetChrome()
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
// 10-12 用户要求：小时、分钟两行都能直接输入，行尾是定稿步进器——小时行一下 1 小时、分钟行一下 15 分钟，
// 都按总分钟加减（6:00 减 15 分是 5:45）。没设过目标时起始值是逻辑昨天实际专注的整小时（服务给）。
// 规则在 DailyGoalDraft。用全高表单、不用焦点状态改写输入框：10-12 真机在窄窗口半高表单里点输入框弹键盘时
// 两次闪退（系统键盘挂视图时自动布局引擎抛异常，调用栈里没有本应用代码），当时表单在聚焦瞬间改写输入框文字，
// 且半高表单要随键盘上移；项目里其它数字输入都是全高表单、不在聚焦时改文字，设备上没有它们的这类崩溃日志。
struct TodayGoalSheet: View {
    let store: TodayStore
    @State private var draft = DailyGoalDraft(minutes: 0)
    @State private var hoursText = ""
    @State private var minutesText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("小时", text: $hoursText, step: 60)
                    row("分钟", text: $minutesText, step: 15)
                }
                if !store.loadError.isEmpty { Text(store.loadError).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("今日专注目标").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if store.saveGoal(minutes: draft.totalMinutes) { dismiss() } }
                        .disabled(!draft.canSave)
                }
            }
        }
        .tint(ThemeColors.accentInk)
        .presentationDetents([.large])
        .onAppear { draft = DailyGoalDraft(minutes: store.goalEditorStartMinutes()); syncFields() }
    }

    private func row(_ label: String, text: Binding<String>, step: Int) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(ThemeColors.inkStrong)
            Spacer(minLength: 8)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(ThemeColors.inkStrong)
                .frame(width: 64)
                // 每敲一位就更新草稿，保存按钮与步进器都读它；分钟填 90 这类写法在下次按步进器时规整成几小时几分。
                .onChange(of: text.wrappedValue) { _, _ in draft.setFields(hours: hoursText, minutes: minutesText) }
                .accessibilityLabel("目标\(label)数")
            AccentStepper(title: "目标\(label)", value: Binding(get: { draft.totalMinutes }, set: { minutes in
                draft = DailyGoalDraft(minutes: minutes)
                syncFields()
            }), range: 0...DailyGoalDraft.maxMinutes, step: step)
        }
        .frame(minHeight: 44)
    }
    // 两格按草稿重写；0 分钟显示成空框（占位的 0），表示还没设。
    private func syncFields() {
        hoursText = draft.totalMinutes == 0 ? "" : String(draft.hours)
        minutesText = draft.totalMinutes == 0 ? "" : String(draft.minutes)
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
                let estimate = "预计用时：\(store.newEstimatedMinutes) 分钟"
                HStack { Text(estimate); Spacer(); AccentStepper(title: estimate, value: $store.newEstimatedMinutes, range: 0...1440, step: 5) }
                TextField("备注", text: $store.newNotes, axis: .vertical)
                if !store.newFormError.isEmpty { Text(store.newFormError).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("新建任务").sheetChrome()
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
