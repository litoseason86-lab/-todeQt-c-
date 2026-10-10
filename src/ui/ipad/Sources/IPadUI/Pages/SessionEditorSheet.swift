import IPadCore
import SwiftUI

@MainActor struct SessionEditorSheet: View {
    let store: TimelineStore
    let session: SessionValue?
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var durationText: String
    @State private var taskID: Int
    @State private var isRest: Bool
    @State private var startEdited = false
    @State private var durationEdited = false
    @State private var options: [SessionTaskOption] = []
    @State private var optionsLoaded = false
    @State private var submitted = false
    @State private var error = ""

    init(store: TimelineStore, session: SessionValue?) {
        self.store = store; self.session = session
        let date = session.flatMap { LogicalDateNavigation.timestampDate($0.startTime) }
            ?? LogicalDateNavigation.initialSessionStart(date: store.selectedDate)
        _start = State(initialValue: date)
        _durationText = State(initialValue: session.map { String(SessionEditorDraft(original: $0).durationMinutes) } ?? "30")
        _taskID = State(initialValue: session?.taskID ?? -1)
        _isRest = State(initialValue: session?.isRest ?? false)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("记录") {
                    if session != nil {
                        Picker("类型", selection: $isRest) {
                            Text("专注").tag(false)
                            Text("休息").tag(true)
                        }
                    }
                    DatePicker("开始", selection: Binding(get: { start }, set: {
                        start = $0; startEdited = true
                    }), displayedComponents: [.date, .hourAndMinute])
                    TextField("时长（分钟）", text: $durationText).keyboardType(.numberPad)
                        .onChange(of: durationText) { durationEdited = true }
                    if !isRest {
                        Picker("任务", selection: $taskID) {
                            Text("不关联任务").tag(-1)
                            ForEach(options.filter { $0.taskID > 0 }, id: \.taskID) { option in
                                Text(option.title).tag(option.taskID)
                            }
                        }
                    }
                }
                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(ThemeColors.danger) }
                }
                if !optionsLoaded {
                    Section { Button("重试读取任务") { loadOptions() } }
                }
            }
            .navigationTitle(session == nil ? "补录专注" : "编辑记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!optionsLoaded || submitted)
                }
            }
        }
        .presentationDetents([.large])
        .task { loadOptions() }
    }
    private func loadOptions() {
        do { options = try store.taskOptions(original: session); optionsLoaded = true; error = "" }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard !submitted, let minutes = Int(durationText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "请输入整数分钟"; return
        }
        let saved: Bool
        if let session {
            // 未改时间时保留原秒数、毫秒和暂停跨度；DatePicker 显示精度不能成为隐式编辑。
            var draft = SessionEditorDraft(original: session)
            draft.taskID = taskID; draft.isRest = isRest
            draft.startEdited = startEdited; draft.durationEdited = durationEdited
            if startEdited { draft.startTime = LogicalDateNavigation.timestamp(start) }
            draft.durationMinutes = minutes
            saved = store.updateSession(draft, original: session)
        } else {
            saved = store.addManualSession(taskID: taskID, startTime: LogicalDateNavigation.timestamp(start), durationMinutes: minutes)
        }
        if saved { submitted = true; dismiss() }
        else { error = store.error.isEmpty ? "保存失败，请重试" : store.error }
    }
}
