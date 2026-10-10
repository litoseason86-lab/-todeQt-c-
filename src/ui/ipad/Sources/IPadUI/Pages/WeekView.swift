import IPadCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct WeekView: View {
    @Bindable var store: WeekStore
    let actions: TaskActions
    let core: CoreBridges
    let shell: ShellStore
    @State private var editingTask: TaskValue?
    @State private var completionTask: TaskValue?
    @State private var addingDate: String?
    @State private var movingTask: TaskValue?
    @FocusState private var listFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !store.error.isEmpty {
                    HStack {
                        Text(store.error).foregroundStyle(ThemeColors.danger)
                        Spacer()
                        Button("重试") { store.refresh() }
                    }
                }
                ForEach(store.groups) { group in
                    WeekDaySection(group: group, store: store, actions: actions,
                                   onEdit: { editingTask = $0 }, onComplete: { completionTask = $0 },
                                   onReschedule: reschedule, onAdd: { addingDate = group.date })
                }
            }
            .focusable().focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(keys: [.upArrow, .downArrow, .space, .return]) { press in
                guard press.modifiers.isEmpty, editingTask == nil, completionTask == nil,
                      movingTask == nil, addingDate == nil, store.draggingTaskID == -1 else { return .ignored }
                switch press.key {
                case .upArrow: store.moveCursor(-1)
                case .downArrow: store.moveCursor(1)
                case .space: return store.toggleCursorCompletion(using: actions) ? .handled : .ignored
                case .return: return store.startCursorFocus(using: actions) ? .handled : .ignored
                default: return .ignored
                }
                return .handled
            }
            .onChange(of: store.cursorTaskID) { _, id in
                // 按任务编号滚入可见区，空日子不产生游标，完成后的沉底排序不改变选中对象。
                if id > 0 { proxy.scrollTo(id) }
            }
        }
        .navigationTitle("本周计划")
        .sheet(item: $editingTask) { task in TaskDetailSheet(taskID: task.id, core: core, shell: shell) }
        .sheet(item: $completionTask) { task in TaskCompletionNoteSheet(taskID: task.id, core: core, shell: shell) }
        .sheet(item: Binding(get: { addingDate.map(IdentifiedDate.init) }, set: { addingDate = $0?.date })) { value in
            WeekAddTaskSheet(store: store, date: value.date)
        }
        .sheet(item: $movingTask, onDismiss: { store.endReschedule() }) { task in
            WeekMoveTaskSheet(store: store, task: task)
        }
        .onDisappear { store.cancelDrag(); store.endReschedule() }
    }
    private func reschedule(_ task: TaskValue) {
        movingTask = store.beginReschedule(id: task.id)
    }
}

@MainActor private struct WeekDaySection: View {
    let group: WeekDayGroup
    let store: WeekStore
    let actions: TaskActions
    let onEdit: (TaskValue) -> Void
    let onComplete: (TaskValue) -> Void
    let onReschedule: (TaskValue) -> Void
    let onAdd: () -> Void

    var body: some View {
        Section {
            ForEach(group.tasks) { task in
                WeekTaskRow(task: task, store: store, actions: actions,
                            onEdit: { onEdit(task) }, onCompleteWithNote: { onComplete(task) },
                            onReschedule: { onReschedule(task) })
                    .id(task.id)
            }
            if store.canAdd(on: group.date) { Button("添加", systemImage: "plus", action: onAdd) }
        } header: {
            HStack {
                Text(group.date)
                Spacer()
                if group.plannedMinutes > 0 {
                    Text("已排 \(group.plannedMinutes) 分钟").foregroundStyle(ThemeColors.inkSoft)
                }
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard ids.count == 1, let id = Int(ids[0]) else { return false }
            return store.drop(taskID: id, to: group.date)
        }
    }
}

// 数据提供者由系统拖动会话持有；取消或放到应用外时释放载荷，结束冻结，不发任务写入。
private final class WeekDragLifetime: Sendable {
    let ended: @Sendable () -> Void
    init(ended: @escaping @Sendable () -> Void) { self.ended = ended }
    deinit { ended() }
}

@MainActor private struct WeekTaskRow: View {
    let task: TaskValue
    let store: WeekStore
    let actions: TaskActions
    let onEdit: () -> Void
    let onCompleteWithNote: () -> Void
    let onReschedule: () -> Void

    var body: some View {
        TaskRow(task: task, actions: actions, allowsStart: store.canStart(on: task.date),
                onEdit: onEdit, onCompleteWithNote: onCompleteWithNote, onReschedule: onReschedule)
            .listRowBackground(store.cursorTaskID == task.id ? ThemeColors.accentSoft : ThemeColors.surface)
            .simultaneousGesture(TapGesture().onEnded { store.selectTask(id: task.id) })
            .onDrag { dragProvider() }
            .dropDestination(for: String.self) { ids, _ in
                guard ids.count == 1, let id = Int(ids[0]) else { return false }
                return store.drop(taskID: id, to: task.date, before: task.id)
            }
    }
    private func dragProvider() -> NSItemProvider {
        guard let session = store.beginDrag(id: task.id) else { return NSItemProvider() }
        let lifetime = WeekDragLifetime { [weak store] in
            Task { @MainActor in store?.endDrag(session: session) }
        }
        let payload = Data(String(task.id).utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .ownProcess) { [lifetime] completion in
            _ = lifetime
            completion(payload, nil)
            return nil
        }
        return provider
    }
}

private struct IdentifiedDate: Identifiable {
    let date: String
    var id: String { date }
    init(_ date: String) { self.date = date }
}

@MainActor private struct WeekAddTaskSheet: View {
    let store: WeekStore
    let date: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var submitted = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("任务名称", text: $title)
                LabeledContent("日期", value: date)
                if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("添加任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { save() }.disabled(submitted || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.presentationDetents([.medium, .large])
    }
    private func save() {
        guard !submitted else { return }
        if store.addTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), date: date) {
            submitted = true; dismiss()
        } else { error = store.error }
    }
}

@MainActor private struct WeekMoveTaskSheet: View {
    let store: WeekStore
    let task: TaskValue
    @Environment(\.dismiss) private var dismiss
    @State private var target: Date
    @State private var error = ""
    @State private var submitted = false
    init(store: WeekStore, task: TaskValue) {
        self.store = store; self.task = task
        _target = State(initialValue: LogicalDateNavigation.date(task.date) ?? .now)
    }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("改期到", selection: $target, displayedComponents: .date)
                if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("改期任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("改期") { move() }.disabled(submitted) }
            }
        }.presentationDetents([.medium, .large])
    }
    private func move() {
        guard !submitted else { return }
        if store.move(task: task, to: LogicalDateNavigation.isoDate(target)) {
            submitted = true; store.endReschedule(); dismiss()
        } else { error = store.error }
    }
}
