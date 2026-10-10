import IPadCore
import SwiftUI

// 草稿和失败原因归 Store；日期选择器只做墙钟格式转换，未改时保留秒数、毫秒及暂停跨度。
@MainActor struct SessionEditorSheet: View {
    @Bindable var store: TimelineStore
    let session: SessionValue?
    @Environment(\.dismiss) private var dismiss
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            Form {
                if let draft = store.editorDraft {
                    Section {
                        if session != nil {
                            Picker("类型", selection: field(\.isRest, default: false)) {
                                Text("专注").tag(false); Text("休息").tag(true)
                            }
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
                        Stepper("时长：\(draft.durationMinutes) 分钟", value: Binding(
                            get: { draft.durationMinutes },
                            set: { store.editorDraft?.durationMinutes = $0; store.editorDraft?.durationEdited = true }), in: 1...1440)
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
            .navigationTitle(session == nil ? "补录专注" : "编辑记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.submitEditor() { submitted = true; dismiss() }
                    }.disabled(!store.editorOptionsLoaded || submitted)
                }
            }
        }.presentationDetents([.large])
            .onAppear { store.openEditor(original: session) }
    }
    private func field<Value>(_ key: WritableKeyPath<SessionEditorDraft, Value>, default fallback: Value) -> Binding<Value> {
        Binding(get: { store.editorDraft?[keyPath: key] ?? fallback }, set: { store.editorDraft?[keyPath: key] = $0 })
    }
}
