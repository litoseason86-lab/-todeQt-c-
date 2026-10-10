import IPadCore
import SwiftUI

@MainActor struct TodayFocusView: View {
    @Bindable var store: TimelineStore
    let shell: ShellStore
    @Environment(FocusStore.self) private var focus
    @State private var editing: SessionValue?
    @State private var adding = false
    @State private var datePickerPresented = false

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            HStack(alignment: .top, spacing: 24) {
                List {
                    if !store.error.isEmpty { errorRow }
                    if store.isFutureDate { Text("未来日期不能补录").foregroundStyle(ThemeColors.inkSoft) }
                    if narrow { Section { summary.padding(16).background(ThemeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14)) }.listRowBackground(ThemeColors.surface) }
                    Section("时间轴") {
                        if focus.snapshot.hasActiveSession && focus.snapshot.sessionLogicalDate == store.selectedDate {
                            HStack {
                                Capsule().fill(ThemeColors.accentInk).frame(width: 4)
                                VStack(alignment: .leading) {
                                    Text(focus.snapshot.phase == 2 || focus.snapshot.phase == 3 ? "正在休息" : "正在专注 · " + focus.miniTimerLabel).font(.headline)
                                    Text(DurationFormat.seconds(Double(focus.snapshot.elapsedSeconds))).font(.caption.monospacedDigit())
                                }
                            }.padding(.vertical, 8).listRowBackground(ThemeColors.accentSoft)
                        }
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
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity)
                if !narrow {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("当日汇总").font(.headline)
                        summary
                    }.padding(16).frame(width: 300).background(ThemeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(.horizontal, narrow ? 16 : 32).padding(.top, 16)
        }
        .navigationTitle("今日专注")
        .navigationSubtitle(TodayDisplayDate.title(store.selectedDate))
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
            Capsule().fill(row.isRest ? ThemeColors.focusBreakAccent : ThemeColors.accentInk).frame(width: 4)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("今日专注").font(.headline).foregroundStyle(ThemeColors.inkSoft)
            Text(store.formatDuration(store.statistics.totalDuration)).font(.largeTitle).monospacedDigit()
            Text("\(store.statistics.sessionCount) 段专注 · \(store.statistics.pomodoroCount) 个番茄")
                .font(.callout).foregroundStyle(ThemeColors.inkSoft)
            if !store.categoryStatistics.categories.isEmpty {
                Text("按科目").font(.headline)
                ForEach(Array(store.categoryStatistics.categories.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(item.name); Spacer(); Text(store.formatDuration(item.duration)).monospacedDigit() }.font(.caption)
                        // 百分比和条形顺序均来自服务，控件只画比例，不重算或加总记录。
                        ProgressView(value: item.percentage, total: 100).tint(ThemeColors.accentFill)
                            .accessibilityLabel(item.name + "，" + store.formatDuration(item.duration))
                    }
                }
            }
        }.foregroundStyle(ThemeColors.ink).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func shiftDate(_ delta: Int) {
        if let date = store.adjacentDate(days: delta) { store.selectDate(date) }
    }
}
