import IPadCore
import SwiftUI

struct DashboardView: View {
    @Environment(DashboardStore.self) private var store
    @Environment(FocusStore.self) private var focus
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sheet: DashboardSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statsGrid
                if !store.loadError.isEmpty { Text(store.loadError).foregroundStyle(ThemeColors.danger).frame(maxWidth: .infinity, alignment: .leading) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { taskPanel; focusPanel }
                    VStack(spacing: 16) { focusPanel; taskPanel }
                }
            }
            .padding(24)
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
        .alert("结束当前计时并切换？", isPresented: .constant(focus.switchPrompt != nil), presenting: focus.switchPrompt) { prompt in
            Button(prompt.confirmTitle) { focus.confirmSwitch() }
            Button("继续当前计时", role: .cancel) { focus.cancelSwitch() }
        } message: { prompt in Text(prompt.message) }
        .sheet(isPresented: Binding(get: { focus.longFree != nil }, set: { if !$0 { focus.continueLongFree() } })) {
            FocusLongFreeSheet(store: focus)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.nickname.isEmpty ? store.greeting : "\(store.greeting)，\(store.nickname)")
                .font(.largeTitle.bold()).foregroundStyle(ThemeColors.inkStrong)
            Text(store.dateText).font(.subheadline).foregroundStyle(ThemeColors.inkSoft)
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            stat("今日专注", DurationFormat.seconds(Double(store.todayStats.totalDuration)), "共 \(store.todayStats.sessionCount) 次")
            stat("任务完成", "\(store.todayStats.completedTasks) / \(store.todayStats.totalTasks)", "完成率 \(Int((store.todayStats.completionRate * 100).rounded()))%")
            stat("连续天数", "\(store.streakDays)", "天")
            stat("累计专注", DashboardFormat.totalHoursText(seconds: store.totalFocusSeconds), "相当于 \(DashboardFormat.equivalentDaysText(seconds: store.totalFocusSeconds)) 天")
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

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("今日任务").font(.title3.bold()); Spacer(); Button("全部任务") { shell.select(.today) } }
            if store.topTasks.isEmpty { Text("今天还没有任务").foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity, minHeight: 100) }
            else {
                ForEach(store.topTasks, id: \.id) { task in
                    TaskRow(task: task, actions: core.taskActions, allowsStart: !task.completed,
                            onEdit: { sheet = .detail(task.id) }, onCompleteWithNote: { sheet = .note(task.id) },
                            onReschedule: nil, onCopyToToday: nil)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ThemeColors.border))
    }

    private var focusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("专注").font(.title3.bold())
            Text(focus.taskTitleText).font(.headline).lineLimit(2)
            FocusClockText(text: focus.primaryTimeText, size: 42, slim: focus.slimClockFont,
                           color: ThemeColors.accentInk)
            if focus.snapshot.hasActiveSession || focus.snapshot.phase != 0 {
                HStack {
                    Button(focus.snapshot.running ? "暂停" : "继续") { focus.togglePause() }.buttonStyle(.borderedProminent).tint(ThemeColors.accentFill)
                    Button("结束") { _ = focus.endFromDashboard() }.buttonStyle(.bordered)
                }
            } else {
                Button("开始专注") { focus.startFromDashboard() }.buttonStyle(.borderedProminent).tint(ThemeColors.accentFill)
            }
        }
        .padding(16).frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.glassSolidCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ThemeColors.glassBorder))
    }
}

private enum DashboardSheet: Identifiable { case detail(Int), note(Int); var id: String { switch self { case .detail(let id): "d\(id)"; case .note(let id): "n\(id)" } } }
