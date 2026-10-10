import IPadCore
import SwiftUI

@MainActor struct SessionEditorSheet: View {
    let store: TimelineStore
    let session: SessionValue?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SessionEditorDraft?
    @State private var startText = ""
    @State private var error = ""
    init(store: TimelineStore, session: SessionValue?) { self.store = store; self.session = session; _draft = State(initialValue: session.map(SessionEditorDraft.init)); _startText = State(initialValue: session?.startTime ?? "") }
    var body: some View {
        NavigationStack {
            Form {
                if var draft {
                    Section("记录") {
                        Toggle("休息", isOn: Binding(get: { draft.isRest }, set: { draft.isRest = $0; self.draft = draft }))
                        if !draft.isRest { TextField("任务编号（-1 表示不关联）", value: Binding(get: { draft.taskID }, set: { draft.taskID = $0; self.draft = draft }), format: .number).keyboardType(.numberPad) }
                        TextField("开始时间", text: $startText).onChange(of: startText) { _, value in draft.startTime = value; draft.startEdited = true; self.draft = draft }
                        Stepper("时长：\(draft.durationMinutes) 分钟", value: Binding(get: { draft.durationMinutes }, set: { draft.durationMinutes = $0; draft.durationEdited = true; self.draft = draft }), in: 1...1440)
                    }
                } else {
                    Section("补录") { Text("日期：\(store.selectedDate)"); Text("开始时间由服务校验"); TextField("任务编号（-1 表示不关联）", value: .constant(-1), format: .number) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) }
            }.navigationTitle(session == nil ? "补录专注" : "编辑记录").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } } }
        }.presentationDetents([.medium, .large])
    }
    private func save() {
        if let session, let draft, store.updateSession(draft, original: session) { dismiss(); return }
        if session == nil { error = "补录时间和时长需要由完整表单提供" } else { error = store.error }
    }
}
