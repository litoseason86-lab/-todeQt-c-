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
                    // 年份用 String 拼接：Text 插值会按区域格式把 2026 写成「2,026」（10-11 真机截图）。
                    PageHeader(title: "专注历史", subtitle: store.year != 0 ? String(store.year) + "年" + String(store.month) + "月" : "")
                    if !store.errorMessage.isEmpty {
                        HStack(alignment: .top) {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Spacer(); Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle())
                        }
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            calendar(compact: false).frame(maxWidth: .infinity)
                            HistorySelectionSummary(store: store, shell: shell, compact: false).frame(width: 300)
                        }
                    } else {
                        calendar(compact: true)
                        HistorySelectionSummary(store: store, shell: shell, compact: true)
                    }
                }
                .padding(.top, 4).padding(.bottom, 24)
            }
            .safeAreaPadding(.horizontal, wide ? Design.pageMargin(geometry: geometry, compact: false, maxWidth: 1150) : 16)
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
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
        MonthGrid(store: store, compact: compact).padding(compact ? 10 : 16)
            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }
}

// 选日期只更新明细这一支，不让明细里的选中值成为整页 GeometryReader 的观察依赖。
private struct HistorySelectionSummary: View {
    let store: HistoryStore
    let shell: ShellStore
    let compact: Bool
    // 定稿当天明细：日期、混排总时长、段数；分隔线下每段一行（时间、色条、任务、时长），底部「查看这天的今日专注 ›」。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.selectedDate.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TodayDisplayDate.title(store.selectedDate)).scaledSystemFont(size: 14).foregroundStyle(ThemeColors.inkSoft)
                    MixedNumberText(parts: MixedNumberText.split(store.durationText(store.selectedSeconds)), numberSize: 30, unitSize: 15)
                    Text("\(store.selectedSessions.count) 段专注").scaledSystemFont(size: 13).foregroundStyle(ThemeColors.inkSoft)
                }
                .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
                ForEach(store.detailSessions(compact: compact)) { session in
                    CardDivider()
                    HStack(spacing: 12) {
                        Text(MonthGoalFormat.formatClock(session.startTime)).scaledSystemFont(size: 13).monospacedDigit()
                            .foregroundStyle(ThemeColors.inkSoft).frame(width: 44, alignment: .leading)
                        Capsule().fill(session.taskTitle.isEmpty ? ThemeColors.border : ThemeColors.accentInk).frame(width: 4, height: 36)
                        Text(session.taskTitle.isEmpty ? "未关联任务" : session.taskTitle).scaledSystemFont(size: 16)
                            .foregroundStyle(session.taskTitle.isEmpty ? ThemeColors.inkSoft : ThemeColors.inkStrong).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(store.durationText(session.durationSeconds)).scaledSystemFont(size: 13).foregroundStyle(ThemeColors.inkSoft)
                    }
                    .padding(.horizontal, 18).frame(minHeight: 66)
                    .accessibilityElement(children: .combine)
                }
                CardDivider()
                Button { store.openSelectedDay(shell: shell) } label: {
                    HStack {
                        Text(compact ? "全部 \(store.selectedSessions.count) 段 · 查看今日专注" : "查看这天的今日专注")
                        Spacer()
                        Image(systemName: "chevron.right").scaledSystemFont(size: 12, weight: .semibold)
                    }
                    .scaledSystemFont(size: 15, weight: .semibold).foregroundStyle(ThemeColors.accentInk)
                    .padding(.horizontal, 18).frame(minHeight: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }
}
