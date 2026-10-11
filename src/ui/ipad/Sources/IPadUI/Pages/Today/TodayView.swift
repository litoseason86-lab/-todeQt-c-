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
            List {
                PageHeader(title: "今日任务", subtitle: TodayDisplayDate.title(store.today))
                    .plainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0))
                goalCard(narrow: narrow)
                    .plainRow(insets: EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))
                TodayBanners(store: store)
                listHeader
                    .cardRow(store.filteredTasks.isEmpty && !emptyVisible ? .single : .top,
                             insets: EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
                ForEach(Array(store.filteredTasks.enumerated()), id: \.element.id) { index, task in
                    VStack(spacing: 0) {
                        CardDivider()
                        row(task, narrow: narrow).padding(.horizontal, narrow ? 8 : 6).padding(.vertical, 6)
                    }
                    .cardRow(index == store.filteredTasks.count - 1 ? .bottom : .middle)
                }
                .onMove { source, destination in
                    guard store.filter == .unfinished, let from = source.first,
                          from < store.unfinished.count else { return }
                    store.commitDrag(taskID: store.unfinished[from].id,
                                     toIndex: destination > from ? destination - 1 : destination)
                }
                if emptyVisible {
                    Text(store.filter == .unfinished ? "今天没有未完成任务" : "今天没有已完成任务")
                        .font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .cardRow(.bottom)
                }
            }
            .modifier(PageListModifier(geometry: geometry, compact: narrow))
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("搜索与批量改期", systemImage: "magnifyingglass") { sheet = .tools }
                    if store.rolloverBannerActive {
                        Button("全部结转到今天", systemImage: "arrow.uturn.forward") { store.moveOverdueToToday() }
                    }
                } label: { Label("更多", systemImage: "ellipsis") }
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

    private var emptyVisible: Bool { store.filteredTasks.isEmpty && store.loadError.isEmpty }

    // 定稿：一张卡片里，左边「已专注 1 小时 05 分 / 目标 4 小时」与进度条，右边改目标的笔。
    private func goalCard(narrow: Bool) -> some View {
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
            Button { sheet = .goal } label: {
                Image(systemName: "pencil").font(.system(size: 17)).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless).foregroundStyle(ThemeColors.accentInk)
            .accessibilityLabel("修改今日目标")
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 12))
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }

    // 卡片顶上一行：左边「未完成 · 5 ⌄」胶囊下拉，右边「+ 新建」。
    private var listHeader: some View {
        HStack {
            Menu {
                Picker("显示", selection: Binding(get: { store.filter }, set: { store.filter = $0 })) {
                    Text("未完成 · \(store.unfinished.count)").tag(TodayStore.Filter.unfinished)
                    Text("已完成 · \(store.finished.count)").tag(TodayStore.Filter.finished)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(store.filter == .unfinished ? "未完成 · \(store.unfinished.count)" : "已完成 · \(store.finished.count)")
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ThemeColors.accentFillInk)
                .padding(.horizontal, 14).frame(height: 36)
                .background(ThemeColors.accentFill, in: Capsule())
            }
            .accessibilityLabel(store.filter == .unfinished ? "显示：未完成，\(store.unfinished.count) 项" : "显示：已完成，\(store.finished.count) 项")
            Spacer()
            Button { store.requestNewTask() } label: {
                Label("新建", systemImage: "plus").labelStyle(PillLabelStyle())
            }
            .buttonStyle(AccentTextButtonStyle())
        }
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
        // 定稿副标题写「10月10日 周五」。
        return formatter("M月d日 EEE").string(from: parsed)
    }
}
