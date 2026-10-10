import IPadCore
import SwiftUI

struct DashboardView: View {
    @Environment(DashboardStore.self) private var store
    @Environment(FocusStore.self) private var focus
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    @State private var sheet: DashboardSheet?

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statsGrid(narrow: narrow)
                    if !store.loadError.isEmpty {
                        HStack {
                            Text(store.loadError).foregroundStyle(ThemeColors.danger)
                            Spacer(); Button("重试") { store.refresh() }
                        }
                    }
                    taskPanel(narrow: narrow)
                }
                .padding(narrow ? 16 : 32).frame(maxWidth: 964).frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("仪表盘")
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .sheet(item: $sheet) { item in
            switch item {
            case .detail(let id): TaskDetailSheet(taskID: id, core: core, shell: shell)
            case .note(let id): TaskCompletionNoteSheet(taskID: id, core: core, shell: shell)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.nickname.isEmpty ? store.greeting : "\(store.greeting)，\(store.nickname)")
                .font(.largeTitle.bold()).foregroundStyle(ThemeColors.inkStrong)
            Text(store.dateText).font(.subheadline).foregroundStyle(ThemeColors.inkSoft)
        }
    }

    private func statsGrid(narrow: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: narrow ? 2 : 4), spacing: 12) {
            stat("今日专注", DurationFormat.seconds(Double(store.todayStats.totalDuration)), "")
            stat("任务完成", "\(store.todayStats.completedTasks) / \(store.todayStats.totalTasks)", "")
            stat("连续天数", "\(store.streakDays)", "天")
            stat("累计时长", DashboardFormat.totalHoursText(seconds: store.totalFocusSeconds), "")
        }
    }

    private func stat(_ title: String, _ value: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(ThemeColors.inkSoft)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(ThemeColors.inkStrong)
            Text(subtitle).font(.caption2).foregroundStyle(ThemeColors.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14).background(ThemeColors.glassCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ThemeColors.border))
    }

    private func taskPanel(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("今日任务").font(.title3.bold()); Spacer(); Button("全部任务") { shell.select(.today) } }
            if store.topTasks.isEmpty { Text("今天还没有任务").foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity, minHeight: 100) }
            else {
                ForEach(store.topTasks, id: \.id) { task in
                    TaskRow(task: task, actions: core.taskActions, allowsStart: !task.completed, activeFocus: focus.snapshot, compactAppearance: narrow,
                            onEdit: { sheet = .detail(task.id) }, onCompleteWithNote: { sheet = .note(task.id) },
                            onReschedule: nil, onCopyToToday: nil)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ThemeColors.border))
    }

}

private enum DashboardSheet: Identifiable { case detail(Int), note(Int); var id: String { switch self { case .detail(let id): "d\(id)"; case .note(let id): "n\(id)" } } }
