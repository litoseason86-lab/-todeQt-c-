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
    // 本机界面状态：已完成组是否展开，只给 Swift 自己用，键名按 ipadui.<页面>.<项>。
    @AppStorage("ipadui.today.finishedExpanded") private var finishedExpanded = true
    @FocusState private var newTaskFocused: Bool

    var body: some View {
        @Bindable var store = store
        List {
            TodayBanners(store: store)
            Section("未完成") {
                ForEach(store.unfinished, id: \.id) { task in row(task) }
                    .onMove { source, destination in
                        // SwiftUI 给的是「插入到 destination 之前」的偏移，换成移动后的最终下标交给 Store。
                        guard let from = source.first, from < store.unfinished.count else { return }
                        let id = store.unfinished[from].id
                        store.commitDrag(taskID: id, toIndex: destination > from ? destination - 1 : destination)
                    }
                if store.unfinished.isEmpty && store.finished.isEmpty && store.loadError.isEmpty {
                    Text("今天还没有任务").foregroundStyle(ThemeColors.inkSoft)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(ThemeColors.accentInk).accessibilityHidden(true)
                    TextField("新任务", text: $store.newTitle)
                        .focused($newTaskFocused)
                        .submitLabel(.next)
                        .accessibilityLabel("新任务标题")
                        .onSubmit { _ = store.submitNewTask(); newTaskFocused = true }
                }
                .frame(minHeight: 44)
                .listRowBackground(ThemeColors.surface)
            }
            if !store.finished.isEmpty {
                Section {
                    DisclosureGroup("已完成 \(store.finished.count)", isExpanded: $finishedExpanded) {
                        ForEach(store.finished, id: \.id) { task in row(task) }
                    }
                    .listRowBackground(ThemeColors.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("今日任务")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sheet = .tools } label: { Label("搜索与批量改期", systemImage: "magnifyingglass") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("设置今日目标", systemImage: "target") { sheet = .goal }
                    Button("搜索与批量改期", systemImage: "calendar.badge.clock") { sheet = .tools }
                    if store.rolloverBannerActive {
                        Button("全部结转到今天", systemImage: "arrow.uturn.forward") { store.moveOverdueToToday() }
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $sheet, onDismiss: { store.tools.close() }) { item in sheetContent(item) }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        // 撤销条出现或收起：隐藏 / 恢复那一行，并换掉「已排」的排除对象。
        .onChange(of: core.pendingDeletion.pendingTaskID) { _, _ in store.pendingDeletionChanged() }
        // ⌘N 或其它入口请求新建：聚焦输入框后确认，请求才算消费。
        .onChange(of: store.newTaskFocusRequested, initial: true) { _, requested in
            if requested { newTaskFocused = true; store.acknowledgeNewTaskRequest() }
        }
    }

    private var subtitle: String {
        ([TodayDisplayDate.title(store.today)].filter { !$0.isEmpty } + store.subtitleParts).joined(separator: " · ")
    }

    private func row(_ task: TaskValue) -> some View {
        TaskRow(task: task, actions: core.taskActions,
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
