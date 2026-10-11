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

    @Environment(ShellStore.self) private var shellStore

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            Group {
                if narrow { compactBody(geometry) } else { wideBody(geometry) }
            }
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { store.shiftWeek(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一周")
                Button { store.shiftWeek(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一周")
            }
        }
        .sheet(item: $editingTask) { task in TaskDetailSheet(taskID: task.id, core: core, shell: shell) }
        .sheet(item: $completionTask) { task in TaskCompletionNoteSheet(taskID: task.id, core: core, shell: shell) }
        .sheet(item: Binding(get: { addingDate.map(IdentifiedDate.init) }, set: { addingDate = $0?.date })) { value in WeekAddTaskSheet(store: store, date: value.date) }
        .sheet(item: $movingTask, onDismiss: { store.endReschedule() }) { task in WeekMoveTaskSheet(store: store, task: task) }
        .onDisappear { store.cancelDrag(); store.endReschedule() }
    }

    // 副标题：「10月6日 – 12日 · 待办 12」。待办数取外壳摘要（服务），本周以外的周不写待办；
    // 「已排」合计服务没有给，界面不自己把七天加起来，所以不写。
    private var subtitle: String {
        guard let first = store.groups.first?.date, let last = store.groups.last?.date else { return "" }
        let range = Self.monthDay(first) + " – " + (first.prefix(7) == last.prefix(7) ? Self.day(last) + "日" : Self.monthDay(last))
        return store.showsCurrentWeek ? range + " · 待办 \(shellStore.snapshot.weekPendingCount)" : range
    }
    static func monthDay(_ iso: String) -> String {
        let parts = iso.split(separator: "-"); guard parts.count == 3 else { return iso }
        return "\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日"
    }
    static func day(_ iso: String) -> String { String(Int(iso.suffix(2)) ?? 0) }
    // 列头右侧的已排时长写短：3h、2h30（定稿）。
    static func shortMinutes(_ minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h\(String(format: "%02d", rest))"
    }

    private var errorBar: some View {
        HStack { Text(store.error).foregroundStyle(ThemeColors.danger); Spacer(); Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle()) }
    }

    // 窄：星期条（白卡片里七格，选中焦糖实底）、当天标题行、当天任务卡、「+ 添加到周X」。
    private func compactBody(_ geometry: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            List {
                PageHeader(title: "本周计划", subtitle: subtitle)
                    .plainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                if !store.error.isEmpty { errorBar.plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4)) }
                dayStrip.plainRow(insets: EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))
                if let group = store.selectedGroup {
                    let index = store.groups.firstIndex(where: { $0.date == group.date }) ?? 0
                    HStack {
                        Text("周" + Self.weekdayLabel(index) + " " + Self.monthDay(group.date) + (store.isToday(group.date) ? " · 今天" : ""))
                        Spacer()
                        if group.plannedMinutes > 0 { Text("已排 " + DurationFormat.minutes(Double(group.plannedMinutes))) }
                    }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(ThemeColors.ink)
                    .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                    .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
                    ForEach(Array(group.tasks.enumerated()), id: \.element.id) { taskIndex, task in
                        VStack(spacing: 0) {
                            if taskIndex > 0 { CardDivider() }
                            taskRow(task, compact: true).padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .id(task.id)
                        .cardRow(group.tasks.count == 1 ? .single : taskIndex == 0 ? .top : taskIndex == group.tasks.count - 1 ? .bottom : .middle,
                                 fill: store.cursorTaskID == task.id ? ThemeColors.accentFill : ThemeColors.surface)
                    }
                    if store.canAdd(on: group.date) {
                        Button { addingDate = group.date } label: {
                            Label(store.addTitle, systemImage: "plus").labelStyle(PillLabelStyle())
                        }
                        .buttonStyle(AccentTextButtonStyle(size: 16))
                        .plainRow(insets: EdgeInsets(top: 10, leading: 4, bottom: 0, trailing: 0))
                        .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
                    }
                }
            }
            .modifier(PageListModifier(geometry: geometry, compact: true))
            .focusable().focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(keys: [.upArrow, .downArrow, .space, .return], action: keyAction)
            .onChange(of: store.cursorTaskID) { _, id in
                if let task = store.task(id: id) { store.selectDay(task.date); proxy.scrollTo(id) }
            }
        }
    }

    private var dayStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(store.groups.enumerated()), id: \.offset) { index, group in
                let selected = store.selectedGroup?.date == group.date
                Button { store.selectDay(group.date) } label: {
                    VStack(spacing: 2) {
                        Text(Self.weekdayLabel(index)).font(.system(size: 12))
                        Text(Self.day(group.date)).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(selected ? ThemeColors.surface : (store.isToday(group.date) ? ThemeColors.accentInk : ThemeColors.ink))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(selected ? ThemeColors.accentInk : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("周" + Self.weekdayLabel(index) + "，" + Self.monthDay(group.date) + (store.isToday(group.date) ? "，今天" : ""))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
            }
        }
        .padding(6)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }

    static func weekdayLabel(_ index: Int) -> String { ["一", "二", "三", "四", "五", "六", "日"][index] }

    // 宽：七列白卡片，列头「周一 6」与右侧已排时长，下面任务小块；今天那列焦糖描边、列头焦糖字。
    // 2/3 分屏放不下七列时横向滚动（列宽不小于 112）。
    private func wideBody(_ geometry: GeometryProxy) -> some View {
        let margin = Design.pagePadding(compact: false)
        let available = geometry.size.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing - margin * 2
        let columnWidth = max(112, (available - 60) / 7)
        return VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "本周计划", subtitle: subtitle)
            if !store.error.isEmpty { errorBar }
            ScrollViewReader { columns in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(store.groups) { group in column(group).frame(width: columnWidth).id(group.date) }
                    }
                    .padding(.bottom, 24)
                }
                .scrollClipDisabled()
                .focusable().focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(keys: [.upArrow, .downArrow, .space, .return], action: keyAction)
                .onChange(of: store.cursorTaskID) { _, id in
                    // 键盘跨列和列内移动都滚到服务选中的任务，不改排序，也不另外维护光标。
                    if let task = store.task(id: id) { columns.scrollTo(task.date) }
                }
            }
        }
        .padding(.top, 4)
        .safeAreaPadding(.horizontal, margin)
    }

    private func column(_ group: WeekDayGroup) -> some View {
        let index = store.groups.firstIndex(where: { $0.date == group.date }) ?? 0
        let today = store.isToday(group.date)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("周" + Self.weekdayLabel(index) + " " + Self.day(group.date))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(today ? ThemeColors.accentInk : ThemeColors.inkStrong)
                Spacer(minLength: 4)
                Text(Self.shortMinutes(group.plannedMinutes)).font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
                    .accessibilityLabel(group.plannedMinutes > 0 ? "已排 " + DurationFormat.minutes(Double(group.plannedMinutes)) : "")
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            CardDivider().padding(.horizontal, 8)
            // 每列用系统 List，才能保留任务块的左滑删除和上下文菜单；外层横向滚动只负责七列布局。
            ScrollViewReader { rows in
                List {
                    ForEach(group.tasks) { task in
                        taskRow(task, compact: true, chip: true).id(task.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                    if store.canAdd(on: group.date) {
                        Button { addingDate = group.date } label: {
                            Label("添加", systemImage: "plus").labelStyle(PillLabelStyle())
                        }
                        .buttonStyle(AccentTextButtonStyle())
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 8))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .padding(.top, 6)
                .onChange(of: store.cursorTaskID) { _, id in
                    if group.tasks.contains(where: { $0.id == id }) { rows.scrollTo(id) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .overlay {
            if today {
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous).strokeBorder(ThemeColors.accentInk, lineWidth: 2)
            }
        }
        .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("周" + Self.weekdayLabel(index) + "，" + Self.monthDay(group.date) + (today ? "，今天" : ""))
    }

    private func taskRow(_ task: TaskValue, compact: Bool, chip: Bool = false) -> some View {
        WeekTaskRow(task: task, store: store, actions: actions, compact: compact, chip: chip,
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
    var chip = false
    let onEdit: () -> Void
    let onCompleteWithNote: () -> Void
    let onReschedule: () -> Void

    var body: some View {
        content
            .simultaneousGesture(TapGesture().onEnded { store.selectTask(id: task.id) })
            .onDrag { dragProvider() }
            .dropDestination(for: String.self) { ids, _ in
                guard ids.count == 1, let id = Int(ids[0]) else { return false }
                return store.drop(taskID: id, to: task.date, before: task.id)
            }
    }
    @ViewBuilder private var content: some View {
        if chip {
            // 定稿宽窗的任务小块：科目色点 + 标题（最多两行），完成的划线变淡；操作在左滑和长按菜单里。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(TaskCategoryColor.value(task.categoryColor).opacity(task.completed ? 0.45 : 1))
                    .frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(task.title).font(.system(size: 14)).lineLimit(2)
                    .foregroundStyle(task.completed ? ThemeColors.inkMuted : ThemeColors.inkStrong)
                    .strikethrough(task.completed)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(store.cursorTaskID == task.id ? ThemeColors.accentFill : ThemeColors.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(task.title + (task.completed ? "，已完成" : ""))
            .swipeActions(edge: .trailing) {
                Button("删除", role: .destructive) { _ = actions.delete(id: task.id, title: task.title) }.tint(ThemeColors.danger)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if !task.completed { Button("完成记录", systemImage: "checkmark") { onCompleteWithNote() }.tint(ThemeColors.success) }
            }
            .contextMenu {
                if task.completed { Button("取消完成", systemImage: "arrow.uturn.backward") { _ = actions.uncomplete(id: task.id) } }
                else { Button("完成", systemImage: "checkmark") { _ = actions.complete(id: task.id, title: task.title) } }
                if store.canStart(on: task.date) && !task.completed {
                    Button("开始专注", systemImage: "play.fill") { actions.openFocus(id: task.id, title: task.title) }
                }
                Button("编辑", systemImage: "pencil", action: onEdit)
                Button("改期", systemImage: "calendar", action: onReschedule)
                Button("删除", systemImage: "trash", role: .destructive) { _ = actions.delete(id: task.id, title: task.title) }
            }
        } else {
            TaskRow(task: task, actions: actions, allowsStart: store.canStart(on: task.date), compactAppearance: compact,
                    onEdit: onEdit, onCompleteWithNote: onCompleteWithNote, onReschedule: onReschedule)
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
