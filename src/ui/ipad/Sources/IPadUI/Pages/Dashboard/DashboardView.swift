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
            List {
                PageHeader(title: store.nickname.isEmpty ? store.greeting : "\(store.greeting)，\(store.nickname)",
                           subtitle: TodayDisplayDate.title(TodayDisplayDate.iso(store.now)))
                    .plainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0))
                statsGrid(narrow: narrow)
                    .plainRow(insets: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 0))
                if !store.loadError.isEmpty {
                    HStack {
                        Text(store.loadError).foregroundStyle(ThemeColors.danger)
                        Spacer(); Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle())
                    }
                    .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
                }
                // 定稿：「今日任务」卡片，标题行右边「全部任务 ›」，下面前六条，行尾只有 ▶。
                HStack {
                    Text("今日任务").font(.system(size: 17, weight: .semibold)).foregroundStyle(ThemeColors.inkStrong)
                    Spacer()
                    Button { shell.select(.today) } label: {
                        HStack(spacing: 4) { Text(narrow ? "全部" : "全部任务"); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                    }
                    .buttonStyle(AccentTextButtonStyle(size: 15))
                }
                .cardRow(store.topTasks.isEmpty ? .top : .top, insets: EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 4))
                if store.topTasks.isEmpty {
                    Text("今天还没有任务").font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 80).cardRow(.bottom)
                } else {
                    ForEach(Array(store.topTasks.enumerated()), id: \.element.id) { index, task in
                        VStack(spacing: 0) {
                            if index > 0 { CardDivider() }
                            TaskRow(task: task, actions: core.taskActions, allowsStart: !task.completed, activeFocus: focus.snapshot,
                                    minimal: true, onEdit: { sheet = .detail(task.id) }, onCompleteWithNote: { sheet = .note(task.id) },
                                    onReschedule: nil, onCopyToToday: nil)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                        }
                        .cardRow(index == store.topTasks.count - 1 ? .bottom : .middle)
                    }
                }
            }
            .modifier(PageListModifier(geometry: geometry, compact: narrow, indicatorAtWindowEdge: true))
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .sheet(item: $sheet) { item in
            switch item {
            case .detail(let id): TaskDetailSheet(taskID: id, core: core, shell: shell)
            case .note(let id): TaskCompletionNoteSheet(taskID: id, core: core, shell: shell)
            }
        }
    }

    // 四张数字卡：宽窗一行四张，窄窗两行两张；数字大、单位小（定稿 1小时05分、2 / 7、12天、286小时）。
    private func statsGrid(narrow: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: narrow ? 10 : 14), count: narrow ? 2 : 4),
                  spacing: narrow ? 10 : 14) {
            stat("今日专注", MixedNumberText.split(DurationFormat.seconds(Double(store.todayStats.totalDuration))))
            stat("任务完成", [("\(store.todayStats.completedTasks)", true), (" / \(store.todayStats.totalTasks)", false)])
            stat("连续天数", [("\(store.streakDays)", true), ("天", false)])
            stat("累计时长", [(DashboardFormat.totalHoursText(seconds: store.totalFocusSeconds), true), ("小时", false)])
        }
    }

    private func stat(_ title: String, _ parts: [(text: String, isNumber: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
            MixedNumberText(parts: parts, numberSize: 30, unitSize: 15).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private enum DashboardSheet: Identifiable { case detail(Int), note(Int); var id: String { switch self { case .detail(let id): "d\(id)"; case .note(let id): "n\(id)" } } }
