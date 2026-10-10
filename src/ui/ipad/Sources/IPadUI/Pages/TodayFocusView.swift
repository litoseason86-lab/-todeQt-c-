import IPadCore
import SwiftUI

@MainActor struct TodayFocusView: View {
    @Bindable var store: TimelineStore
    let shell: ShellStore
    @State private var editing: SessionValue?
    @State private var adding = false
    @State private var datePickerPresented = false

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            HStack(alignment: .top, spacing: 16) {
                List {
                    if !store.error.isEmpty { errorRow }
                    if store.isFutureDate { Text("未来日期不能补录").foregroundStyle(ThemeColors.inkSoft) }
                    if narrow { Section("当日汇总") { summary } }
                    Section("时间轴") {
                        // 专注和休息两张表的编号独立，列表身份必须携带类型。
                        ForEach(store.visibleSessions, id: \.timelineID) { row in
                            Button { editing = row } label: { sessionRow(row) }
                                .buttonStyle(.plain)
                                .listRowBackground(row.isRest ? ThemeColors.surfaceSunken : ThemeColors.accentSoft)
                                .swipeActions(edge: .trailing) {
                                    Button("删除", role: .destructive) { _ = store.deleteSession(row) }.tint(ThemeColors.danger)
                                }
                                .contextMenu {
                                    Button("编辑") { editing = row }
                                    Button("删除", role: .destructive) { _ = store.deleteSession(row) }
                                }
                        }
                    }
                }
                if !narrow {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("当日汇总").font(.headline)
                        summary
                    }.padding().frame(width: 260)
                }
            }
        }
        .navigationTitle("今日专注")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { shiftDate(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("前一天")
                Button { datePickerPresented = true } label: { Text(store.selectedDate).monospacedDigit() }.accessibilityLabel("选择日期，" + store.selectedDate)
                Button { shiftDate(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("后一天")
                Button("补录", systemImage: "plus") { adding = true }.disabled(!store.canAddManualSession)
            }
        }
        .sheet(isPresented: $datePickerPresented) {
            NavigationStack {
                DatePicker("日期", selection: Binding(
                    get: { LogicalDateNavigation.date(store.selectedDate) ?? .now },
                    set: { store.selectDate(LogicalDateNavigation.isoDate($0)) }), displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .navigationTitle("选择日期")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { datePickerPresented = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(item: $editing) { SessionEditorSheet(store: store, session: $0) }
        .sheet(isPresented: $adding) { SessionEditorSheet(store: store, session: nil) }
        .onAppear { store.selectRequestedDate(from: shell) }
        .onChange(of: shell.requestedFocusDate) { store.selectRequestedDate(from: shell) }
    }
    private var errorRow: some View {
        HStack {
            Text(store.error).foregroundStyle(ThemeColors.danger)
            Spacer()
            Button("重试") { store.selectDate(store.selectedDate) }
        }
    }
    private func sessionRow(_ row: SessionValue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                timeLabel(row.startTime)
                timeLabel(row.endTime)
            }.font(.caption.monospacedDigit())
            VStack(alignment: .leading, spacing: 4) {
                Text(row.isRest ? "休息" : (row.taskTitle.isEmpty ? "自由专注" : row.taskTitle)).font(.headline)
                Text(store.formatDuration(row.durationSeconds)).font(.caption).foregroundStyle(ThemeColors.inkSoft)
            }
            Spacer()
        }
        .padding(.vertical, 6).foregroundStyle(ThemeColors.ink)
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func timeLabel(_ value: String) -> some View {
        if let date = LogicalDateNavigation.timestampDate(value) { Text(date, format: .dateTime.hour().minute()) }
        else { Text(value) }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.formatDuration(store.statistics.totalDuration))
            Text("记录 \(store.statistics.sessionCount) 条")
            Text("番茄 \(store.statistics.pomodoroCount) 个")
        }
    }
    private func shiftDate(_ delta: Int) {
        if let date = store.adjacentDate(days: delta) { store.selectDate(date) }
    }
}
