import IPadCore
import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        @Bindable var binding = store
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("专注历史").font(.largeTitle.bold())
                        if store.year != 0 {
                            Text("\(store.year)年\(store.month)月").font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                        }
                    }
                    if !store.errorMessage.isEmpty {
                        HStack(alignment: .top) {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Spacer(); Button("重试") { store.refresh() }
                        }
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            calendar(compact: false).frame(maxWidth: .infinity)
                            summary(compact: false).frame(width: 300)
                        }
                    } else {
                        calendar(compact: true)
                        summary(compact: true)
                    }
                }
                .padding(.horizontal, wide ? 32 : 16).padding(.vertical, 16)
            }
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("上个月", systemImage: "chevron.left") { store.moveMonth(-1) }.labelStyle(.iconOnly)
                Button("本月") { store.returnToCurrentMonth() }
                Button("下个月", systemImage: "chevron.right") { store.moveMonth(1) }.labelStyle(.iconOnly)
                Menu {
                    Button("清理无效记录", role: .destructive) { store.requestCleanup() }
                        .disabled(store.invalidSessionCount == 0)
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
        .confirmationDialog("清理 \(store.invalidSessionCount) 条无效记录？", isPresented: $binding.cleanupConfirmationPresented,
                            titleVisibility: .visible) {
            Button("清理", role: .destructive) { store.confirmCleanup() }
            Button("取消", role: .cancel) { store.cancelCleanup() }
        } message: { Text("永久删除不足 3 分钟的已结束记录，无法撤销。") }
        .onAppear { store.setActive(true) }
        .onDisappear { store.setActive(false); store.cancelCleanup() }
    }
    private func calendar(compact: Bool) -> some View {
        MonthGrid(store: store, compact: compact).padding(compact ? 12 : 20)
            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private func summary(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.selectedDate.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(CountdownFormat.targetDate(store.selectedDate)).font(.headline)
                        Text("\(store.selectedSessions.count) 段专注").font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                    }
                    if compact { Spacer() }
                }
                Text(store.durationText(store.selectedSeconds)).font(.title.bold()).monospacedDigit()
                ForEach(store.detailSessions(compact: compact)) { session in
                    HStack(alignment: .top, spacing: 12) {
                        Text(MonthGoalFormat.formatClock(session.startTime)).font(.subheadline).monospacedDigit()
                            .foregroundStyle(ThemeColors.inkSoft)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.taskTitle.isEmpty ? "未关联任务" : session.taskTitle).font(.headline)
                            Text(store.durationText(session.durationSeconds)).font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Button(compact ? "全部 \(store.selectedSessions.count) 段 · 查看今日专注" : "查看这天的今日专注",
                       systemImage: "arrow.right") { store.openSelectedDay(shell: shell) }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}
