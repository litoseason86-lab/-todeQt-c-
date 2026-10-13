import IPadCore
import Observation
import SwiftUI

// 同一时间只显示一个表单：任务表单各自持有编辑令牌，叠两个会让冻结与释放顺序难以保证。
// 任务详情不在这里：它从任务行以浮层弹出（宽窗），见 TaskRow。
private enum TodaySheet: Identifiable {
    case note(Int), reschedule(Int), tools, goal
    var id: String {
        switch self {
        case .note(let id): "note-\(id)"
        case .reschedule(let id): "reschedule-\(id)"
        case .tools: "tools"
        case .goal: "goal"
        }
    }
}

// 浮层选择是可观察的展示状态；只有锚点/表单宿主读取对应字段，开详情不让整页订阅该编号。
@MainActor @Observable private final class TodayPresentation {
    var sheet: TodaySheet?
    var detailTaskID: Int?
}

// 今日任务页：列表、状态与业务都在 TodayStore / TaskActions，这里只放展示和手势接线。
// 10-12 对齐提醒事项：去掉「未完成 / 已完成」切换，已完成放在列表下面可展开的一组；打勾后停留再收起；
// 卡片底部「＋ 新任务」就地新建；右上「•••」进多选，底部浮出批量操作条。
struct TodayView: View {
    @Environment(TodayStore.self) private var store
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    @State private var presentation = TodayPresentation()

    var body: some View {
        @Bindable var presentation = presentation
        TodayTaskList(store: store, presentation: presentation)
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .modifier(TodayToolbarModifier(store: store, presentation: presentation))
            .modifier(TodaySelectionInset(store: store, actions: core.taskActions))
            .sheet(item: $presentation.sheet, onDismiss: { store.tools.close() }) { item in sheetContent(item) }
            .onAppear {
                store.start()
                if UIPerfProbe.isRequested { UIPerfProbe.todayDetail = { presentation.detailTaskID = $0 } }
            }
            .onDisappear { store.stop() }
            // 撤销状态改变由 Store 隐藏/恢复任务，不在视图维护第二份列表。
            .onChange(of: core.pendingDeletion.pendingTaskID) { _, _ in store.pendingDeletionChanged() }
    }

    @ViewBuilder private func sheetContent(_ item: TodaySheet) -> some View {
        switch item {
        case .note(let id): TaskCompletionNoteSheet(taskID: id, core: core, shell: shell)
        case .reschedule(let id): TodayRescheduleSheet(taskID: id, store: store)
        case .tools: TodayToolsSheet(store: store.tools, today: store.today, actions: core.taskActions)
        case .goal: TodayGoalSheet(store: store)
        }
    }
}

// 标题、目标、选择状态、专注状态各在自己的子视图读取；局部变化不再触发整张列表的投影。
private struct TodayTaskList: View {
    let store: TodayStore
    let presentation: TodayPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            // 同一次列表投影只筛分一次；动画签名也复用本轮结果，不保存跨刷新的任务快照。
            let unfinished = store.unfinished
            let finished = store.finished
            List {
                TodayHeader(store: store)
                    .plainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0))
                TodayGoalCard(store: store, presentation: presentation, narrow: narrow)
                    .plainRow(insets: EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))
                TodayBanners(store: store)
                taskCard(rows: unfinished, narrow: narrow)
                completedGroup(rows: finished, narrow: narrow)
            }
            .modifier(PageListModifier(geometry: geometry, compact: narrow, indicatorAtWindowEdge: true))
            // 打勾后的收起、展开已完成、新建出来的行都用列表自带的插入删除动画；减少动态效果时不动画。
            .animation(reduceMotion ? nil : .default, value: listSignature(unfinished: unfinished, finished: finished))
        }
    }

    // 行的增删与分组变化才触发动画；只改了标题等内容不算。
    private func listSignature(unfinished: [TaskValue], finished: [TaskValue]) -> [Int] {
        unfinished.map(\.id) + [-1] + (store.completedExpanded ? finished.map(\.id) : [finished.count])
            + [store.composing ? 1 : 0, store.selecting ? 1 : 0]
    }

    // 未完成的任务卡：任务行 + 最后一行「＋ 新任务」（新建中换成输入行）；多选时不放新建行。
    @ViewBuilder private func taskCard(rows: [TaskValue], narrow: Bool) -> some View {
        let footer = !store.selecting
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, task in
            let last = index == rows.count - 1 && !footer
            TodayTaskCardRow(task: task, store: store, presentation: presentation, narrow: narrow,
                             divider: index > 0,
                             position: index == 0 ? (last ? .single : .top) : (last ? .bottom : .middle),
                             fill: ThemeColors.surface)
        }
        // 停留中、多选中不能拖：停留的那几条已完成，服务不让已完成任务参与排序。
        .onMove(perform: moveAction)
        if footer {
            VStack(spacing: 0) {
                if !rows.isEmpty { CardDivider() }
                if store.composing { TodayComposeRow(store: store) } else { newTaskButton }
            }
            .padding(.horizontal, narrow ? 8 : 6)
            .cardRow(rows.isEmpty ? .single : .bottom)
        }
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard !store.selecting, store.lingering.isEmpty else { return nil }
        return { source, destination in
            let rows = store.unfinished
            guard let from = source.first, from < rows.count else { return }
            store.commitDrag(taskID: rows[from].id,
                             toIndex: destination > from ? destination - 1 : destination)
        }
    }

    private var newTaskButton: some View {
        Button { store.requestNewTask() } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus.circle.fill").font(.system(size: 26)).frame(width: 44, height: 44)
                Text("新任务").font(.system(size: 17))
                Spacer(minLength: 0)
            }
            .foregroundStyle(ThemeColors.accentInk)
            .frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    // 「已完成 · N」一组：标题行点一下展开 / 收起，展开后是已完成的任务（点圆圈取消完成）。
    @ViewBuilder private func completedGroup(rows: [TaskValue], narrow: Bool) -> some View {
        if !rows.isEmpty {
            Color.clear.frame(height: 14).plainRow()
            let fill = ThemeColors.surface.opacity(0.72)
            Button { store.completedExpanded.toggle() } label: {
                HStack {
                    Text("已完成 · \(rows.count)").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(store.completedExpanded ? 90 : 0))
                }
                .foregroundStyle(ThemeColors.inkSoft)
                .frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("已完成，\(rows.count) 项")
            .accessibilityValue(store.completedExpanded ? "已展开" : "已收起")
            .cardRow(store.completedExpanded ? .top : .single, fill: fill,
                     insets: EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            if store.completedExpanded {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, task in
                    TodayTaskCardRow(task: task, store: store, presentation: presentation, narrow: narrow,
                                     divider: true, position: index == rows.count - 1 ? .bottom : .middle,
                                     fill: fill)
                }
            }
        }
    }
}

private struct TodayHeader: View {
    let store: TodayStore
    var body: some View {
        let date = TodayDisplayDate.title(store.today)
        PageHeader(title: store.selecting ? "已选 \(store.selection.count) 项" : "今日任务",
                   subtitle: store.selecting ? "今日任务 · " + date : date)
    }
}

private struct TodayGoalCard: View {
    let store: TodayStore
    let presentation: TodayPresentation
    let narrow: Bool
    // 定稿：一张卡片里，左边「已专注 1 小时 05 分 / 目标 4 小时」与进度条，右边改目标的笔。
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !narrow { Text("已专注").font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft) }
                    Text(DurationFormat.seconds(Double(store.focusedSeconds)))
                        .font(.system(size: 24, weight: .bold)).monospacedDigit().foregroundStyle(ThemeColors.inkStrong)
                    Text(store.goalMinutes > 0 ? "/ 目标 " + DurationFormat.minutes(Double(store.goalMinutes)) : "/ 未设目标")
                        .font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                ProgressBar(percent: store.goalProgressPercent)
                    .accessibilityLabel("今日目标进度")
                    .accessibilityValue(StatisticsFormat.percent(store.goalProgressPercent))
            }
            Button { presentation.sheet = .goal } label: {
                Image(systemName: "pencil").font(.system(size: 17)).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless).foregroundStyle(ThemeColors.accentInk)
            .accessibilityLabel("修改今日目标")
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 12))
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }
}

private struct TodayTaskCardRow: View {
    let task: TaskValue
    let store: TodayStore
    let presentation: TodayPresentation
    let narrow: Bool
    let divider: Bool
    let position: CardRowPosition
    let fill: Color
    @Environment(CoreBridges.self) private var core
    @Environment(FocusStore.self) private var focus

    var body: some View {
        VStack(spacing: 0) {
            if divider { CardDivider() }
            row.padding(.horizontal, narrow ? 8 : 6).padding(.vertical, 6)
        }
        .cardRow(position, fill: store.selecting && store.selection.contains(task.id) ? ThemeColors.accentFill : fill)
    }

    private var row: some View {
        @Bindable var presentation = presentation
        return TaskRow(task: task, actions: core.taskActions, activeFocusTaskID: focus.activeSession?.taskID ?? -1, compactAppearance: narrow,
                onToggleCompletion: { store.toggleCompletion(task, using: core.taskActions) },
                selectionMode: store.selecting, selected: store.selection.contains(task.id),
                onToggleSelection: { store.toggleSelection(task.id) },
                detailTaskID: $presentation.detailTaskID,
                onCompleteWithNote: { presentation.sheet = .note(task.id) },
                onReschedule: { presentation.sheet = .reschedule(task.id) },
                onCopyToToday: { _ = store.copyToToday(id: task.id) })
    }
}

private struct TodayToolbarModifier: ViewModifier {
    let store: TodayStore
    let presentation: TodayPresentation
    func body(content: Content) -> some View {
        content.toolbar { toolbarContent }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if store.selecting {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(store.allSelected ? "全不选" : "全选") { store.toggleSelectAll() }
                    .disabled(store.selectable.isEmpty)
                Button("完成") { store.endSelection() }.fontWeight(.semibold)
                    .keyboardShortcut(.escape, modifiers: [])
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("选择任务", systemImage: "checkmark.circle") { store.beginSelection() }
                        .disabled(store.unfinished.isEmpty && store.finished.isEmpty)
                    Button(store.completedExpanded ? "隐藏已完成" : "显示已完成", systemImage: store.completedExpanded ? "eye.slash" : "eye") {
                        store.completedExpanded.toggle()
                    }
                    Button("搜索与批量改期", systemImage: "magnifyingglass") { presentation.sheet = .tools }
                    if store.rolloverBannerActive {
                        Button("全部结转到今天", systemImage: "arrow.uturn.forward") { store.moveOverdueToToday() }
                    }
                } label: { Label("更多", systemImage: "ellipsis") }
            }
        }
    }
}

// 条件仍放在安全区插入内容的直接层级，保持未选择时的空内容与系统默认间距语义；只把状态读取移到修饰器。
private struct TodaySelectionInset: ViewModifier {
    let store: TodayStore
    let actions: TaskActions
    @State private var batchReschedulePresented = false
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if store.selecting {
                TodaySelectionBar(store: store, actions: actions, batchReschedulePresented: $batchReschedulePresented)
            }
        }
    }
}

private struct TodaySelectionBar: View {
    let store: TodayStore
    let actions: TaskActions
    @Binding var batchReschedulePresented: Bool
    // 多选的底部操作条：完成、改期、删除（选中的都是今天的任务，所以没有「结转到今天」）。
    var body: some View {
        let empty = store.selection.isEmpty
        return SelectionActionBar {
            SelectionBarButton(title: "完成", systemImage: "checkmark") { store.completeSelection(using: actions) }
                .disabled(empty)
            SelectionBarButton(title: "改期", systemImage: "calendar") { batchReschedulePresented = true }
                .disabled(empty)
                .popover(isPresented: $batchReschedulePresented) {
                    BatchDatePicker(title: "改期 \(store.selection.count) 项", initial: store.today) { date in
                        store.rescheduleSelection(to: date)
                    }
                }
            SelectionBarButton(title: "删除", systemImage: "trash", role: .destructive) { store.deleteSelection(using: actions) }
                .disabled(empty)
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}

// 行内新建的那一行：回车建好并接着起下一行，空行回车、点别处或 Esc 结束（有字的先建上）。
private struct TodayComposeRow: View {
    @Bindable var store: TodayStore
    @FocusState private var focused: Bool
    // 回车建好后系统会让输入框失焦，这一下不能当成「点了别处」去结束新建。
    @State private var continuing = false
    var body: some View {
        HStack(spacing: 14) {
            Circle().strokeBorder(ThemeColors.accentStrong.opacity(0.5), lineWidth: 2)
                .frame(width: 26, height: 26).frame(width: 44, height: 44)
            TextField("新任务", text: $store.newTitle)
                .font(.system(size: 17)).foregroundStyle(ThemeColors.inkStrong)
                .focused($focused)
                .submitLabel(.next)
                .onSubmit(submit)
                .onKeyPress(.escape) { focused = false; store.endComposing(); return .handled }
                .accessibilityLabel("新任务标题")
        }
        .frame(minHeight: 56)
        .task(id: store.newTaskFocusRequested) {
            guard store.newTaskFocusRequested else { return }
            focused = true; store.acknowledgeNewTaskRequest()
        }
        .onChange(of: focused) { _, value in
            guard !value else { continuing = false; return }
            Task { @MainActor in
                if !focused && !continuing { store.endComposing() }
            }
        }
    }
    private func submit() {
        if store.newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { focused = false; store.endComposing(); return }
        continuing = true
        if store.submitNewTask() { focused = true } else { continuing = false }
    }
}

// 批量改期的日期浮层：宽窗是浮层，窄窗系统改成表单。日期只做表示转换，写入交给调用方。
struct BatchDatePicker: View {
    let title: String
    let initial: String
    let onPick: (String) -> Bool
    @State private var date = Date()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ThemeColors.inkStrong)
            DatePicker("改期到", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Button("取消") { dismiss() }.buttonStyle(AccentTextButtonStyle(size: 16))
                Spacer()
                Button("改期") { if onPick(TodayDisplayDate.iso(date)) { dismiss() } }.buttonStyle(ProminentPillStyle())
            }
        }
        .padding(16)
        .frame(idealWidth: 340)
        .tint(ThemeColors.accentInk)
        .onAppear { date = TodayDisplayDate.date(initial) }
    }
}

// 只做 ISO 日期与系统日期选择器 / 标题的表示转换，不推导今天、逾期或任务归属。
@MainActor enum TodayDisplayDate {
    // 格式器按格式与 Foundation 默认时区复用，和新建 DateFormatter 的默认语义一致；默认时区改变后重建，避免沿用旧墙钟日期。
    private static var cachedTimeZone = NSTimeZone.default
    private static var formatters: [String: DateFormatter] = [:]
    private static func formatter(_ format: String) -> DateFormatter {
        let timeZone = NSTimeZone.default
        if cachedTimeZone != timeZone {
            cachedTimeZone = timeZone
            formatters.removeAll()
        }
        if let value = formatters[format] { return value }
        let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: format == "yyyy-MM-dd" ? "en_US_POSIX" : "zh_CN")
        value.timeZone = timeZone; value.dateFormat = format
        formatters[format] = value
        return value
    }
    static func date(_ iso: String) -> Date { formatter("yyyy-MM-dd").date(from: iso) ?? Date() }
    static func iso(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
    static func title(_ iso: String) -> String {
        guard let parsed = formatter("yyyy-MM-dd").date(from: iso) else { return "" }
        // 定稿副标题写「10月10日 周五」。
        return formatter("M月d日 EEE").string(from: parsed)
    }
}
