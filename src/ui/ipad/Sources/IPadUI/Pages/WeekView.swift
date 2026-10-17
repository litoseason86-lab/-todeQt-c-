import IPadCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// 详情编号只由行里的浮层读取，打开详情不让七个 List 的宿主重新生成。
@MainActor @Observable private final class WeekPresentation {
    var detailTaskID: Int?
}

@MainActor struct WeekView: View {
    @Bindable var store: WeekStore
    let actions: TaskActions
    let core: CoreBridges
    let shell: ShellStore
    // 任务详情从任务行 / 小块以浮层弹出（窄窗系统改成整页表单），这里只记哪一条开着。
    @State private var presentation = WeekPresentation()
    @State private var completionTask: TaskValue?
    // 行内新建（10-12 对齐提醒事项）：哪一天正在新建；同一时间只有一处输入行。
    @State private var composingDate: String?
    @State private var movingTask: TaskValue?
    @State private var batchReschedulePresented = false
    @FocusState private var listFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            // 辅助字号下七列放不下（10-18 真机最大字号：列头竖排、任务只剩一个字），与统计、专注历史一样改用单日版式。
            let narrow = geometry.size.width < 700 || typeSize.isAccessibilitySize
            Group {
                if narrow { compactBody(geometry) } else { wideBody(geometry) }
            }
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            // 10-12 对齐提醒事项：「选择」进多选（跨七天），底部浮出批量完成、改期、结转到今天、删除。
            if store.selecting {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(store.allSelected ? "全不选" : "全选") { store.toggleSelectAll() }
                    Button("完成") { store.endSelection() }.fontWeight(.semibold).keyboardShortcut(.escape, modifiers: [])
                }
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("选择") { composingDate = nil; store.beginSelection() }
                        .disabled(store.groups.allSatisfy { $0.tasks.isEmpty })
                    Button { store.shiftWeek(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一周")
                    Button { store.shiftWeek(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一周")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { if store.selecting { selectionBar } }
        .sheet(item: $completionTask) { task in TaskCompletionNoteSheet(taskID: task.id, core: core, shell: shell) }
        .sheet(item: $movingTask, onDismiss: { store.endReschedule() }) { task in WeekMoveTaskSheet(store: store, task: task) }
        .onDisappear { store.cancelDrag(); store.endReschedule() }
    }

    private var selectionBar: some View {
        let empty = store.selection.isEmpty
        return SelectionActionBar {
            SelectionBarButton(title: "完成", systemImage: "checkmark") { store.completeSelection(using: actions) }.disabled(empty)
            SelectionBarButton(title: "改期", systemImage: "calendar") { batchReschedulePresented = true }
                .disabled(empty)
                .popover(isPresented: $batchReschedulePresented) {
                    BatchDatePicker(title: "改期 \(store.selection.count) 项", initial: store.logicalToday) { date in
                        store.rescheduleSelection(to: date)
                    }
                }
            SelectionBarButton(title: "结转到今天", systemImage: "arrow.uturn.forward") { store.moveSelectionToToday() }.disabled(empty)
            SelectionBarButton(title: "删除", systemImage: "trash", role: .destructive) { store.deleteSelection(using: actions) }
                .disabled(empty).keyboardShortcut(.delete, modifiers: .command)
        }
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
                WeekPageHeader(store: store)
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
                    .scaledSystemFont(size: 14, weight: .semibold).foregroundStyle(ThemeColors.ink)
                    .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                    .dropDestination(for: String.self) { ids, _ in return drop(ids, to: group.date) }
                    ForEach(Array(group.tasks.enumerated()), id: \.element.id) { taskIndex, task in
                        VStack(spacing: 0) {
                            if taskIndex > 0 { CardDivider() }
                            taskRow(task, compact: true).padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .id(task.id)
                        .cardRow(cardPosition(taskIndex, count: group.tasks.count, footer: store.canAdd(on: group.date) && !store.selecting),
                                 fill: store.cursorTaskID == task.id || store.selection.contains(task.id) ? ThemeColors.accentFill : ThemeColors.surface)
                    }
                    if store.canAdd(on: group.date) && !store.selecting {
                        VStack(spacing: 0) {
                            if !group.tasks.isEmpty { CardDivider() }
                            WeekComposeRow(store: store, date: group.date, composingDate: $composingDate, compact: false)
                        }
                        .padding(.horizontal, 8)
                        .cardRow(group.tasks.isEmpty ? .single : .bottom)
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
                        Text(Self.weekdayLabel(index)).scaledSystemFont(size: 12)
                        // 七格等分宽度，大字号时两位数会被折成两行；单行缩小。
                        Text(Self.day(group.date)).scaledSystemFont(size: 18, weight: .semibold).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5)
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
            WeekPageHeader(store: store)
            if !store.error.isEmpty { errorBar }
            ScrollViewReader { columns in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(store.groups.enumerated()), id: \.element.date) { index, group in
                            column(group, index: index).frame(width: columnWidth).id(group.date)
                        }
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

    private func column(_ group: WeekDayGroup, index: Int) -> some View {
        let today = store.isToday(group.date)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("周" + Self.weekdayLabel(index) + " " + Self.day(group.date))
                    .scaledSystemFont(size: 16, weight: .semibold)
                    .foregroundStyle(today ? ThemeColors.accentInk : ThemeColors.inkStrong)
                Spacer(minLength: 4)
                Text(Self.shortMinutes(group.plannedMinutes)).scaledSystemFont(size: 13).foregroundStyle(ThemeColors.inkSoft)
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
                    if store.canAdd(on: group.date) && !store.selecting {
                        WeekComposeRow(store: store, date: group.date, composingDate: $composingDate, compact: true)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
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
                    detailTaskID: Binding(get: { presentation.detailTaskID }, set: { presentation.detailTaskID = $0 }), onCompleteWithNote: { completionTask = task }, onReschedule: { reschedule(task) })
    }
    // 窄窗当天那张卡：有新建行时它在最后，任务行就不再是底边。
    private func cardPosition(_ index: Int, count: Int, footer: Bool) -> CardRowPosition {
        let last = index == count - 1 && !footer
        if index == 0 { return last ? .single : .top }
        return last ? .bottom : .middle
    }
    private func drop(_ ids: [String], to date: String) -> Bool {
        guard ids.count == 1, let id = Int(ids[0]) else { return false }
        return store.drop(taskID: id, to: date)
    }
    private func keyAction(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !store.selecting, presentation.detailTaskID == nil, completionTask == nil,
              movingTask == nil, composingDate == nil, store.draggingTaskID == -1 else { return .ignored }
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

// 页头独立读取待办摘要，计时每秒变化不重建七列任务列表。
// 只在当前周显示服务给的待办数；其它周仍只显示日期范围，不在界面合计七天。
private struct WeekPageHeader: View {
    let store: WeekStore
    @Environment(ShellStore.self) private var shell
    var body: some View {
        let groups = store.groups
        let subtitle: String = {
            guard let first = groups.first?.date, let last = groups.last?.date else { return "" }
            let range = WeekView.monthDay(first) + " – " + (first.prefix(7) == last.prefix(7)
                ? WeekView.day(last) + "日" : WeekView.monthDay(last))
            return store.showsCurrentWeek ? range + " · 待办 \(shell.details.weekPendingCount)" : range
        }()
        PageHeader(title: store.selecting ? "已选 \(store.selection.count) 项" : "本周计划", subtitle: subtitle)
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
    let detailTaskID: Binding<Int?>
    let onCompleteWithNote: () -> Void
    let onReschedule: () -> Void
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    private var detailPresented: Binding<Bool> {
        Binding(get: { detailTaskID.wrappedValue == task.id },
                set: { if !$0 && detailTaskID.wrappedValue == task.id { detailTaskID.wrappedValue = nil } })
    }

    private var selected: Bool { store.selection.contains(task.id) }
    var body: some View {
        content
            .simultaneousGesture(TapGesture().onEnded {
                if store.selecting { store.toggleSelection(task.id) } else { store.selectTask(id: task.id) }
            })
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
                if store.selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .scaledSystemFont(size: 15).foregroundStyle(selected ? ThemeColors.accentInk : ThemeColors.inkMuted)
                } else {
                    Circle().fill(TaskCategoryColor.value(task.categoryColor).opacity(task.completed ? 0.45 : 1))
                        .frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(task.title).scaledSystemFont(size: 14).lineLimit(2)
                    .foregroundStyle(task.completed ? ThemeColors.inkMuted : ThemeColors.inkStrong)
                    .strikethrough(task.completed)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(store.cursorTaskID == task.id || selected ? ThemeColors.accentFill : ThemeColors.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(task.title + (task.completed ? "，已完成" : ""))
            .accessibilityAddTraits(store.selecting && selected ? .isSelected : [])
            .popover(isPresented: detailPresented) { TaskDetailSheet(taskID: task.id, core: core, shell: shell) }
            // 与任务行同一套（TaskRow）：左滑删除 / 详情，右滑完成记录，长按菜单。
            .swipeActions(edge: .trailing) {
                if !store.selecting {
                    Button(role: .destructive) { _ = actions.delete(id: task.id, title: task.title) } label: { Label("删除", systemImage: "trash") }
                        .tint(ThemeColors.danger)
                    Button { detailTaskID.wrappedValue = task.id } label: { Label("详情", systemImage: "info.circle") }.tint(ThemeColors.inkSoft)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if !store.selecting && !task.completed { Button("完成记录", systemImage: "checkmark") { onCompleteWithNote() }.tint(ThemeColors.success) }
            }
            .contextMenu { if !store.selecting { chipMenu } }
        } else {
            TaskRow(task: task, actions: actions, allowsStart: store.canStart(on: task.date), compactAppearance: compact,
                    // 点行切换选中由外层的同时手势做（它在非多选时移动键盘光标），这里不再传，免得一次点击切两次。
                    selectionMode: store.selecting, selected: selected,
                    detailTaskID: detailTaskID, onCompleteWithNote: onCompleteWithNote, onReschedule: onReschedule)
        }
    }
    @ViewBuilder private var chipMenu: some View {
                Button("编辑详情", systemImage: "info.circle") { detailTaskID.wrappedValue = task.id }
                if task.completed { Button("取消完成", systemImage: "arrow.uturn.backward") { _ = actions.uncomplete(id: task.id) } }
                else { Button("完成", systemImage: "checkmark") { _ = actions.complete(id: task.id, title: task.title) } }
                if store.canStart(on: task.date) && !task.completed {
                    Button("开始专注", systemImage: "play.fill") { actions.openFocus(id: task.id, title: task.title) }
                }
                if !task.completed { Button("完成并写记录", systemImage: "checkmark.circle", action: onCompleteWithNote) }
                Button("改期…", systemImage: "calendar", action: onReschedule)
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) { _ = actions.delete(id: task.id, title: task.title) }
    }
    private func dragProvider() -> NSItemProvider {
        // 多选中不拖：拖动的冻结登记会与批量写入交叉。
        guard !store.selecting, let session = store.beginDrag(id: task.id) else { return NSItemProvider() }
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

// 行内新建的一行（10-12 对齐提醒事项）：平时是「＋ 新任务」，点开变输入框；回车建好接着起下一条，
// 空行回车、点别处或 Esc 结束（有字的先建上）。建在哪天由 WeekStore.addTask 校验（过去的日期不让建）。
@MainActor private struct WeekComposeRow: View {
    let store: WeekStore
    let date: String
    @Binding var composingDate: String?
    // 宽窗七列里的小号样式；窄窗与今日任务页的新建行同一大小。
    let compact: Bool
    @State private var title = ""
    @State private var continuing = false
    @FocusState private var focused: Bool
    private var composing: Bool { composingDate == date }
    var body: some View {
        Group {
            if composing {
                HStack(spacing: compact ? 8 : 14) {
                    Circle().strokeBorder(ThemeColors.accentStrong.opacity(0.5), lineWidth: 2)
                        .frame(width: compact ? 14 : 26, height: compact ? 14 : 26)
                        .frame(width: compact ? 18 : 44, height: compact ? 30 : 44)
                    TextField("新任务", text: $title)
                        .scaledSystemFont(size: compact ? 14 : 17).foregroundStyle(ThemeColors.inkStrong)
                        .focused($focused).submitLabel(.next).onSubmit(submit)
                        .onKeyPress(.escape) { focused = false; end(); return .handled }
                        .accessibilityLabel("新任务标题")
                }
                .frame(minHeight: compact ? 36 : 56)
                .onAppear { focused = true }
                .onChange(of: focused) { _, value in
                    guard !value else { continuing = false; return }
                    Task { @MainActor in if !focused && !continuing && composing { end() } }
                }
            } else {
                Button { composingDate = date } label: {
                    HStack(spacing: compact ? 6 : 14) {
                        Image(systemName: "plus.circle.fill").scaledSystemFont(size: compact ? 16 : 26)
                            .frame(width: compact ? 18 : 44, height: compact ? 30 : 44)
                        Text("新任务").scaledSystemFont(size: compact ? 14 : 17)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ThemeColors.accentInk)
                    .frame(minHeight: compact ? 36 : 56).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("在 \(date) 新建任务")
            }
        }
    }
    private func submit() {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { focused = false; end(); return }
        continuing = true
        if store.addTask(title: text, date: date) { title = ""; focused = true } else { continuing = false }
    }
    private func end() {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !store.addTask(title: text, date: date) { return }
        title = ""
        if composingDate == date { composingDate = nil }
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
        // 任务日期缺失或非法时退回 C++ 的逻辑今天，凌晨日界前不把初值移到第二天（062 A040）。
        _target = State(initialValue: LogicalDateNavigation.dateOrLogicalToday(task.date))
    }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("改期到", selection: $target, displayedComponents: .date)
                if !error.isEmpty { Text(error).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("改期任务").sheetChrome()
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
