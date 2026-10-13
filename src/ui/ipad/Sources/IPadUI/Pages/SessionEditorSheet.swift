import IPadCore
import SwiftUI

// 草稿和失败原因归 Store；日期选择器只做墙钟格式转换，未改时保留秒数、毫秒及暂停跨度。
@MainActor struct SessionEditorSheet: View {
    @Bindable var store: TimelineStore
    let session: SessionValue?
    @Environment(\.dismiss) private var dismiss
    @State private var submitted = false
    @State private var hoursText = ""
    @State private var minutesText = ""

    var body: some View {
        NavigationStack {
            Form {
                if let draft = store.editorDraft {
                    Section {
                        if session != nil {
                            // 定稿：类型是一行两段的分段控件。
                            Picker("类型", selection: field(\.isRest, default: false)) {
                                Text("专注").tag(false); Text("休息").tag(true)
                            }.pickerStyle(.segmented)
                        }
                        DatePicker("开始", selection: Binding(
                            get: { LogicalDateNavigation.timestampDate(draft.startTime) ?? LogicalDateNavigation.initialSessionStart(date: store.selectedDate) },
                            set: { date in
                                store.editorDraft?.startTime = LogicalDateNavigation.timestamp(date)
                                store.editorDraft?.startEdited = true
                            }), displayedComponents: [.date, .hourAndMinute])
                        if !store.editorError.isEmpty {
                            Text(store.editorError).font(.callout).foregroundStyle(ThemeColors.danger)
                                .accessibilityLabel("开始时间或记录保存失败，" + store.editorError)
                        }
                        // 小时行一下 1 小时、分钟行一下 5 分钟（从默认 30 分到 25、45 分只要点一两下），都按总分钟加减。
                        durationRow("小时", text: $hoursText, step: 60)
                        durationRow("分钟", text: $minutesText, step: 5)
                        if !draft.isRest {
                            Picker("任务", selection: field(\.taskID, default: -1)) {
                                Text("不关联任务").tag(-1)
                                ForEach(store.editorTaskOptions.filter { $0.taskID > 0 }, id: \.taskID) { Text($0.title).tag($0.taskID) }
                            }
                        }
                        if !store.editorOptionsLoaded { Button("重试读取任务") { store.reloadEditorOptions() } }
                    }
                }
            }
            .navigationTitle(session == nil ? "补录专注" : "编辑记录").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.submitEditor() { submitted = true; dismiss() }
                    }.disabled(!store.editorOptionsLoaded || submitted || store.editorDraft?.durationValid != true)
                }
            }
        }
        // 编辑已有记录时从记录块以浮层弹出，按理想尺寸摆；补录与窄窗是整页表单，系统忽略这两个值。
        .frame(idealWidth: 420, idealHeight: 460)
        .presentationDetents([.large])
            .onAppear { store.openEditor(original: session); syncDurationFields() }
    }
    private func field<Value>(_ key: WritableKeyPath<SessionEditorDraft, Value>, default fallback: Value) -> Binding<Value> {
        Binding(get: { store.editorDraft?[keyPath: key] ?? fallback }, set: { store.editorDraft?[keyPath: key] = $0 })
    }
    // 写法同今日目标编辑器（TodaySheets）：输入框每敲一位就交给草稿，不在聚焦时改写文字；
    // 只有按步进器才把草稿规整回两个框（分钟填 90 在下次按步进器时变成 1 小时 30 分）。
    private func durationRow(_ unit: String, text: Binding<String>, step: Int) -> some View {
        HStack(spacing: 12) {
            Text("时长（\(unit)）").foregroundStyle(ThemeColors.inkStrong)
            Spacer(minLength: 8)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(ThemeColors.inkStrong)
                .frame(width: 64)
                .onChange(of: text.wrappedValue) { _, _ in
                    store.editorDraft?.setDurationFields(hours: hoursText, minutes: minutesText)
                }
                .accessibilityLabel("时长\(unit)数")
            AccentStepper(title: "时长\(unit)", value: Binding(get: { store.editorDraft?.durationMinutes ?? 0 }, set: { minutes in
                store.editorDraft?.setDuration(minutes)
                syncDurationFields()
            }), range: 1...SessionEditorDraft.maxDurationMinutes, step: step)
        }
        .frame(minHeight: 44)
    }
    // 不足 1 小时时小时框留空（占位 0），直接敲数字不用先删 0。
    private func syncDurationFields() {
        guard let draft = store.editorDraft else { return }
        hoursText = draft.durationHours == 0 ? "" : String(draft.durationHours)
        minutesText = String(draft.durationRemainderMinutes)
    }
}
