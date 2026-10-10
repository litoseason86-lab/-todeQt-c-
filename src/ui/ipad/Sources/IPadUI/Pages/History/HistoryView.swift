import IPadCore
import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        @Bindable var binding = store
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Button { store.moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("上个月")
                        Spacer()
                        Text(store.year == 0 ? "专注历史" : "\(store.year)年\(store.month)月").font(.title2.bold())
                        Spacer()
                        Button { store.moveMonth(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("下个月")
                    }
                    if !store.errorMessage.isEmpty {
                        HStack(alignment: .top) {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Spacer(); Button("重试") { store.refresh() }
                        }
                    }
                    if geometry.size.width >= 760 && !typeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 20) {
                            MonthGrid(store: store, compact: false).frame(maxWidth: .infinity)
                            summary.frame(width: 280)
                        }
                    } else {
                        MonthGrid(store: store, compact: true)
                        summary
                    }
                }
                .padding(20)
            }
        }
        .foregroundStyle(ThemeColors.ink)
        .navigationTitle("专注历史")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("本月") { store.returnToCurrentMonth() }
                    Button("清理无效记录", role: .destructive) { store.requestCleanup() }
                        .disabled(store.invalidSessionCount == 0)
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
        .confirmationDialog("清理 \(store.invalidSessionCount) 条无效记录？", isPresented: $binding.cleanupConfirmationPresented,
                            titleVisibility: .visible) {
            Button("清理", role: .destructive) {
                store.confirmCleanup()
            }
            Button("取消", role: .cancel) { store.cancelCleanup() }
        } message: { Text("永久删除不足 3 分钟的已结束记录，无法撤销。") }
        .onAppear { store.setActive(true) }
        .onDisappear { store.setActive(false); store.cancelCleanup() }
    }
    private var summary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if store.selectedDate.isEmpty { Text("请选择日期").foregroundStyle(ThemeColors.inkSoft) }
                else {
                    Text(store.selectedDate).font(.headline)
                    Text(store.durationText(store.selectedSeconds)).font(.title2.bold()).monospacedDigit()
                    ForEach(store.selectedSessions, id: \.id) { session in
                        HStack(alignment: .top) {
                            Text(MonthGoalFormat.formatClock(session.startTime)).monospacedDigit()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.taskTitle.isEmpty ? "未关联任务" : session.taskTitle)
                                Text(store.durationText(session.durationSeconds)).foregroundStyle(ThemeColors.inkSoft)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button("查看今日专注", systemImage: "clock") { store.openSelectedDay(shell: shell) }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
