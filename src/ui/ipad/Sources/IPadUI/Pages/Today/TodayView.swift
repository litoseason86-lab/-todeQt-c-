import IPadCore
import SwiftUI

// 同一时间只显示一个表单：任务表单各自持有编辑令牌，叠两个会让冻结与释放顺序难以保证。
private enum TodaySheet: Identifiable {
    case detail(Int), note(Int), reschedule(Int), tools, goal
    var id: String {
        switch self {
        case .detail(let id): "detail-\(id)"
        case .note(let id): "note-\(id)"
        case .reschedule(let id): "reschedule-\(id)"
        case .tools: "tools"
        case .goal: "goal"
        }
    }
}

// 今日任务页：列表、状态与业务都在 TodayStore / TaskActions，这里只放展示和手势接线。
struct TodayView: View {
    @Environment(TodayStore.self) private var store
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    @State private var sheet: TodaySheet?
    @Environment(FocusStore.self) private var focus

    var body: some View {
        @Bindable var store = store
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            VStack(spacing: 12) {
                goalCard
                HStack {
                    Picker("任务状态", selection: $store.filter) {
                        Text("未完成 · \(store.unfinished.count)").tag(TodayStore.Filter.unfinished)
                        Text("已完成 · \(store.finished.count)").tag(TodayStore.Filter.finished)
                    }.pickerStyle(.menu)
                    Spacer()
                    Button("新建", systemImage: "plus") { store.requestNewTask() }
                }
                List {
                    TodayBanners(store: store)
                    ForEach(store.filteredTasks, id: \.id) { task in row(task, narrow: narrow) }
                        .onMove { source, destination in
                            guard store.filter == .unfinished, let from = source.first,
                                  from < store.unfinished.count else { return }
                            store.commitDrag(taskID: store.unfinished[from].id,
                                             toIndex: destination > from ? destination - 1 : destination)
                        }
                    if store.filteredTasks.isEmpty && store.loadError.isEmpty {
                        Text(store.filter == .unfinished ? "今天没有未完成任务" : "今天没有已完成任务")
                            .foregroundStyle(ThemeColors.inkSoft)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            .padding(.horizontal, narrow ? 16 : 32).padding(.top, 16)
            .frame(maxWidth: 964).frame(maxWidth: .infinity)
        }
        .navigationTitle("今日任务")
        .navigationSubtitle(TodayDisplayDate.title(store.today))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("搜索与批量改期", systemImage: "magnifyingglass") { sheet = .tools }
                    if store.rolloverBannerActive {
                        Button("全部结转到今天", systemImage: "arrow.uturn.forward") { store.moveOverdueToToday() }
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $sheet, onDismiss: { store.tools.close() }) { item in sheetContent(item) }
        .sheet(isPresented: $store.newTaskPresented) { TodayNewTaskSheet(store: store, categories: core.categories) }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        // 撤销状态改变由 Store 隐藏/恢复任务，不在视图维护第二份列表。
        .onChange(of: core.pendingDeletion.pendingTaskID) { _, _ in store.pendingDeletionChanged() }
        // 外壳 ⌘N 与本页新建都投影同一个 Store 表单状态。
        .onChange(of: store.newTaskFocusRequested, initial: true) { _, requested in
            if requested { store.newTaskPresented = true; store.acknowledgeNewTaskRequest() }
        }
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日目标").font(.headline)
                Spacer()
                Button { sheet = .goal } label: { Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("修改今日目标")
            }
            Text(DurationFormat.seconds(Double(store.focusedSeconds)) + " / " +
                 (store.goalMinutes > 0 ? DurationFormat.minutes(Double(store.goalMinutes)) : "未设目标"))
                .font(.title3).monospacedDigit()
            ProgressView(value: store.goalProgressPercent, total: 100)
                .tint(ThemeColors.accentFill)
                .accessibilityLabel("今日目标进度")
                .accessibilityValue(StatisticsFormat.percent(store.goalProgressPercent))
        }
        .padding(16).foregroundStyle(ThemeColors.ink)
        .background(ThemeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ task: TaskValue, narrow: Bool) -> some View {
        TaskRow(task: task, actions: core.taskActions, activeFocus: focus.snapshot, compactAppearance: narrow,
                onEdit: { sheet = .detail(task.id) },
                onCompleteWithNote: { sheet = .note(task.id) },
                onReschedule: { sheet = .reschedule(task.id) },
                onCopyToToday: { _ = store.copyToToday(id: task.id) })
    }

    @ViewBuilder private func sheetContent(_ item: TodaySheet) -> some View {
        switch item {
        case .detail(let id): TaskDetailSheet(taskID: id, core: core, shell: shell)
        case .note(let id): TaskCompletionNoteSheet(taskID: id, core: core, shell: shell)
        case .reschedule(let id): TodayRescheduleSheet(taskID: id, store: store)
        case .tools: TodayToolsSheet(store: store.tools, today: store.today, actions: core.taskActions)
        case .goal: TodayGoalSheet(store: store)
        }
    }
}

// 只做 ISO 日期与系统日期选择器 / 标题的表示转换，不推导今天、逾期或任务归属。
enum TodayDisplayDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: format == "yyyy-MM-dd" ? "en_US_POSIX" : "zh_CN"); value.dateFormat = format
        return value
    }
    static func date(_ iso: String) -> Date { formatter("yyyy-MM-dd").date(from: iso) ?? Date() }
    static func iso(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
    static func title(_ iso: String) -> String {
        guard let parsed = formatter("yyyy-MM-dd").date(from: iso) else { return "" }
        return formatter("M月d日 EEEE").string(from: parsed)
    }
}
