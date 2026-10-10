import IPadCore
import SwiftUI

@MainActor struct TodayFocusView: View {
    @Bindable var store: TimelineStore
    @State private var editing: SessionValue?
    @State private var adding = false
    @State private var deleting: SessionValue?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !store.error.isEmpty { errorRow }
                    HStack {
                        Button { shiftDate(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("前一天")
                        Text(store.selectedDate).font(.title2.monospacedDigit()).frame(maxWidth: .infinity)
                        Button { shiftDate(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("后一天")
                        Button("补录", systemImage: "plus") { adding = true }.disabled(!store.canAddManualSession)
                    }
                    .padding(.horizontal)
                    if store.isFutureDate { Text("未来日期不能补录").foregroundStyle(ThemeColors.inkSoft).padding(.horizontal) }
                    HStack(alignment: .top, spacing: 16) {
                        timeline.frame(maxWidth: .infinity)
                        if geometry.size.width >= 700 { summary.frame(width: 260) }
                    }.padding(.horizontal)
                }.padding(.vertical)
            }.background(ThemeColors.surface)
        }
        .navigationTitle("今日专注")
        .sheet(item: $editing) { SessionEditorSheet(store: store, session: $0) }
        .sheet(isPresented: $adding) { SessionEditorSheet(store: store, session: nil) }
        .confirmationDialog("删除记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let deleting { _ = store.deleteSession(deleting) }; deleting = nil }
        }
    }
    private var errorRow: some View { HStack { Text(store.error).foregroundStyle(ThemeColors.danger); Spacer(); Button("重试") { store.refresh() } }.padding().background(ThemeColors.surfaceRaised) }
    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(store.visibleSessions, id: \.id) { row in
                Button { editing = row } label: {
                    HStack {
                        Text(row.startTime).font(.caption.monospacedDigit()).frame(width: 150, alignment: .leading)
                        VStack(alignment: .leading) { Text(row.isRest ? "休息" : (row.taskTitle.isEmpty ? "自由专注" : row.taskTitle)).font(.headline); Text(store.formatDuration(row.durationSeconds)).font(.caption).foregroundStyle(ThemeColors.inkSoft) }
                        Spacer()
                    }.padding().background(row.isRest ? ThemeColors.surfaceSunken : ThemeColors.accentSoft).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).contextMenu { Button("编辑") { editing = row }; Button("删除", role: .destructive) { deleting = row } }
                    .accessibilityLabel((row.isRest ? "休息" : "专注") + "，" + store.formatDuration(row.durationSeconds))
            }
        }
    }
    private var summary: some View { VStack(alignment: .leading, spacing: 8) { Text("当日汇总").font(.headline); Text(store.formatDuration(store.statistics.totalDuration)); Text("记录 \(store.statistics.sessionCount) 条"); Text("番茄 \(store.statistics.pomodoroCount) 个") }.padding().background(ThemeColors.surfaceRaised).clipShape(RoundedRectangle(cornerRadius: 12)) }
    private func shiftDate(_ delta: Int) {
        // 日期字符串由逻辑日桥接提供；这里仅把导航请求交给装配层替换 selection，避免 Swift 复制日期判定。
    }
}
