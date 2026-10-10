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
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            VStack(spacing: 0) {
                if !store.error.isEmpty { errorBar }
                if narrow { compactBody } else { wideBody }
            }
        }
        .navigationTitle("本周计划")
        .sheet(item: $editingTask) { task in TaskDetailSheet(taskID: task.id, core: core, shell: shell) }
        .sheet(item: $completionTask) { task in TaskCompletionNoteSheet(taskID: task.id, core: core, shell: shell) }
        .sheet(item: Binding(get: { addingDate.map(IdentifiedDate.init) }, set: { addingDate = $0?.date })) { value in WeekAddTaskSheet(store: store, date: value.date) }
        .sheet(item: $movingTask, onDismiss: { store.endReschedule() }) { task in WeekMoveTaskSheet(store: store, task: task) }
        .onDisappear { store.cancelDrag(); store.endReschedule() }
    }
    private var errorBar: some View {
        HStack { Text(store.error).foregroundStyle(ThemeColors.danger); Spacer(); Button("重试") { store.refresh() } }
            .padding(.horizontal, 16).padding(.vertical, 8)
    }
    private var compactBody: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Array(store.groups.enumerated()), id: \.offset) { index, group in
                    Button { store.selectDay(group.date) } label: {
                        VStack(spacing: 4) {
                            Text(Self.weekdayLabel(index)).font(.callout)
                            Text(String(group.date.suffix(2))).font(.caption.monospacedDigit())
                            Circle().fill(store.isToday(group.date) ? ThemeColors.accentInk : ThemeColors.surface.opacity(0))
                                .frame(width: 4, height: 4).accessibilityHidden(true)
                        }.frame(maxWidth: .infinity, minHeight: 52)
                            .background(store.selectedGroup?.date == group.date ? ThemeColors.accentSoft : ThemeColors.surface,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel("周" + Self.weekdayLabel(index) + "，" + group.date + (store.isToday(group.date) ? "，今天" : ""))
                }
            }.padding(.horizontal, 16)
            ScrollViewReader { proxy in
                List {
                    if let group = store.selectedGroup {
                        Section {
                            ForEach(group.tasks) { task in taskRow(task, compact: true).id(task.id) }
                            if store.canAdd(on: group.date) {
                                Button(store.addTitle, systemImage: "plus") { addingDate = group.date }
                                    .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
                            }
                        } header: {
                            groupHeader(group)
                                .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .focusable().focused($listFocused)
                    .onAppear { listFocused = true }
                    .onKeyPress(keys: [.upArrow, .downArrow, .space, .return], action: keyAction)
                    .onChange(of: store.cursorTaskID) { _, id in
                        if let task = store.task(id: id) { store.selectDay(task.date); proxy.scrollTo(id) }
                    }
            }
        }
    }
    static func weekdayLabel(_ index: Int) -> String { ["一", "二", "三", "四", "五", "六", "日"][index] }
    private var wideBody: some View {
        GeometryReader { geometry in
            ScrollViewReader { columns in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(store.groups) { group in
                            VStack(spacing: 8) {
                                groupHeader(group).padding(10)
                                // 每列使用系统 List，才能保留任务行的左滑删除和上下文菜单；外层横向滚动只负责七列布局。
                                ScrollViewReader { rows in
                                    List {
                                        ForEach(group.tasks) { task in
                                            taskRow(task, compact: true).id(task.id)
                                                .padding(8)
                                                .background(ThemeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                                                .listRowBackground(ThemeColors.surface)
                                                .listRowInsets(EdgeInsets())
                                        }
                                    }
                                    .listStyle(.plain)
                                    .scrollContentBackground(.hidden)
                                    .onChange(of: store.cursorTaskID) { _, id in
                                        if group.tasks.contains(where: { $0.id == id }) { rows.scrollTo(id) }
                                    }
                                }
                                if store.canAdd(on: group.date) { Button("添加", systemImage: "plus") { addingDate = group.date }.frame(minHeight: 44) }
                            }
                            .padding(8).frame(width: max(170, (geometry.size.width - 124) / 7))
                            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.isToday(group.date) ? ThemeColors.accentInk : ThemeColors.borderSubtle, lineWidth: store.isToday(group.date) ? 2 : 1))
                            .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
                            .id(group.date)
                        }
                    }.padding(.horizontal, 32).padding(.vertical, 16)
                }
                .focusable().focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(keys: [.upArrow, .downArrow, .space, .return], action: keyAction)
                .onChange(of: store.cursorTaskID) { _, id in
                    // 键盘跨列和列内移动都滚到服务选中的任务，不改排序，也不另外维护光标。
                    if let task = store.task(id: id) { columns.scrollTo(task.date) }
                }
            }
        }
    }
    private func groupHeader(_ group: WeekDayGroup) -> some View {
        let index = store.groups.firstIndex(where: { $0.date == group.date }) ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("周" + Self.weekdayLabel(index) + " " + group.date).font(.headline)
            Text("已排 " + DurationFormat.minutes(Double(group.plannedMinutes))).font(.caption).foregroundStyle(ThemeColors.inkSoft)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func taskRow(_ task: TaskValue, compact: Bool) -> some View {
        WeekTaskRow(task: task, store: store, actions: actions, compact: compact,
                    onEdit: { editingTask = task }, onCompleteWithNote: { completionTask = task }, onReschedule: { reschedule(task) })
    }
    private func drop(_ ids: [String], to date: String) -> Bool {
        guard ids.count == 1, let id = Int(ids[0]) else { return false }
        return store.drop(taskID: id, to: date)
    }
    private func keyAction(_ press: KeyPress) -> KeyPress.Result {
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
    private func reschedule(_ task: TaskValue) {
        movingTask = store.beginReschedule(id: task.id)
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
    var compact = false
    let onEdit: () -> Void
    let onCompleteWithNote: () -> Void
    let onReschedule: () -> Void

    var body: some View {
        TaskRow(task: task, actions: actions, allowsStart: store.canStart(on: task.date), compactAppearance: compact,
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
