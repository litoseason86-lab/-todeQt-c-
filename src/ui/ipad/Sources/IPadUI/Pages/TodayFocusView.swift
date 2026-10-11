import IPadCore
import SwiftUI

@MainActor struct TodayFocusView: View {
    @Bindable var store: TimelineStore
    let shell: ShellStore
    @Environment(FocusStore.self) private var focus
    @State private var editing: SessionValue?
    @State private var datePickerPresented = false

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            if narrow { compactBody(geometry) } else { wideBody(geometry) }
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { shiftDate(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("前一天")
                Button { shiftDate(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("后一天")
                Button("补录", systemImage: "plus") { store.manualAddPresented = true }.disabled(!store.canAddManualSession)
            }
        }
        .sheet(isPresented: $datePickerPresented) {
            NavigationStack {
                DatePicker("日期", selection: Binding(
                    get: { LogicalDateNavigation.date(store.selectedDate) ?? .now },
                    set: { store.selectDate(LogicalDateNavigation.isoDate($0)) }), displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .navigationTitle("选择日期").sheetChrome()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { datePickerPresented = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(item: $editing) { SessionEditorSheet(store: store, session: $0) }
        .sheet(isPresented: $store.manualAddPresented) { SessionEditorSheet(store: store, session: nil) }
        .onAppear { store.selectRequestedDate(from: shell) }
        .onChange(of: shell.requestedFocusDate) { store.selectRequestedDate(from: shell) }
    }

    // 页头副标题可点开系统日期选择（定稿右上只有前一天、后一天、补录三个按钮）。
    private var header: some View {
        Button { datePickerPresented = true } label: {
            PageHeader(title: "今日专注",
                       subtitle: TodayDisplayDate.title(store.selectedDate) + (store.isSelectedToday ? " · 今天" : ""))
        }
        .buttonStyle(.plain)
        .accessibilityHint("选择日期")
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.error.isEmpty { errorRow }
            if store.isFutureDate { Text("未来日期不能补录").font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft) }
        }
    }

    // 宽：左边时间轴卡片（整点刻度两小时一格，专注、休息分色），右边 300 宽的汇总栏。
    private func wideBody(_ geometry: GeometryProxy) -> some View {
        let margin = Design.pageMargin(geometry: geometry, compact: false, maxWidth: 1200)
        return VStack(alignment: .leading, spacing: 12) {
            header
            notices
            HStack(alignment: .top, spacing: 24) {
                timelineCard
                VStack(spacing: 14) {
                    totalCard(compact: false)
                    categoryCard
                }
                .frame(width: 300)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 4).padding(.bottom, 24)
        .safeAreaPadding(.horizontal, margin)
    }

    // 进行中色块从服务给的真实开始时刻画起，结束保存后的正式记录也是这个时刻，不会跳位。
    // 不用「现在 − 有效计时」：有效计时不含暂停，暂停过就会画晚。
    private var activeStartMinute: Int? {
        guard focus.snapshot.hasActiveSession, focus.snapshot.sessionLogicalDate == store.selectedDate else { return nil }
        return TimelineLayout.minute(of: focus.snapshot.sessionStartTime, day: store.selectedDate)
    }

    private var timelineCard: some View {
        let blocks = TimelineLayout.blocks(store.visibleSessions, day: store.selectedDate)
        let active = activeStartMinute
        let hours = TimelineLayout.hourRange(blocks, extraMinutes: active.map { [$0] } ?? [])
        let hourHeight: CGFloat = 50
        let top: CGFloat = 30
        func y(_ minute: Int) -> CGFloat { top + CGFloat(minute - hours.lowerBound * 60) / 60 * hourHeight }
        return ScrollView {
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: hours.lowerBound, through: hours.upperBound, by: 2)), id: \.self) { hour in
                    Rectangle().fill(ThemeColors.borderSubtle).frame(height: 1).offset(y: y(hour * 60))
                    Text(String(format: "%02d:00", hour % 24)).font(.system(size: 12)).foregroundStyle(ThemeColors.inkSoft)
                        .padding(.trailing, 6).background(ThemeColors.surface)
                        .offset(x: 12, y: y(hour * 60) - 8)
                }
                ForEach(blocks, id: \.session.timelineID) { block in
                    let height = max(16, y(block.endMinute) - y(block.startMinute) - 2)
                    Button { editing = block.session } label: { sessionBlock(block, height: height) }
                        .buttonStyle(.plain)
                        .offset(x: 68, y: y(block.startMinute) + 1)
                        .padding(.trailing, 84)
                        .contextMenu {
                            Button("编辑") { editing = block.session }
                            Button("删除", role: .destructive) { _ = store.deleteSession(block.session) }
                        }
                }
                if let active {
                    activeBlock.offset(x: 68, y: y(active)).padding(.trailing, 84)
                }
            }
            .frame(maxWidth: .infinity, minHeight: y(hours.upperBound * 60) + 24, alignment: .topLeading)
        }
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }

    // 定稿 .blk：圆角 10、左边 4 宽色条；专注浅焦糖底，休息浅绿底；矮块用 12 号单行字。
    private func sessionBlock(_ block: TimelineBlock, height: CGFloat) -> some View {
        let session = block.session
        let small = height < 30
        let title = session.isRest ? "休息" : (session.taskTitle.isEmpty ? "自由专注" : session.taskTitle)
        let detail = session.isRest ? store.formatDuration(session.durationSeconds)
            : clock(block.startMinute) + " · " + store.formatDuration(session.durationSeconds)
        return HStack(alignment: small ? .center : .top) {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: small ? 12 : 14))
        .foregroundStyle(session.isRest ? ThemeColors.focusBreakInk : ThemeColors.accentFillInk)
        .padding(.horizontal, 12).padding(.vertical, small ? 0 : 6)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: small ? .leading : .topLeading)
        .background(session.isRest ? ThemeColors.focusBreakAccent.opacity(0.18) : ThemeColors.accentFill,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                .fill(session.isRest ? ThemeColors.focusBreakAccent : ThemeColors.accentInk).frame(width: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("编辑这段记录")
    }

    private var activeBlock: some View {
        let resting = focus.snapshot.phase == 2 || focus.snapshot.phase == 3
        return HStack {
            Text(resting ? "正在休息" : "正在专注 · " + focus.miniTimerLabel).lineLimit(1)
            Spacer(minLength: 8)
            Text(DurationFormat.seconds(Double(focus.snapshot.elapsedSeconds))).monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(ThemeColors.danger)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .background(ThemeColors.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9, style: .continuous)
                .fill(ThemeColors.dangerBorder).frame(width: 4)
        }
    }

    private func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
    }

    // 汇总卡：「今日专注」、大号时长、「N 段专注 · M 个番茄」（数字均来自服务）。
    private func totalCard(compact: Bool) -> some View {
        let total = MixedNumberText(parts: MixedNumberText.split(store.formatDuration(store.statistics.totalDuration)),
                                    numberSize: compact ? 26 : 30, unitSize: 15)
        let counts = "\(store.statistics.sessionCount) 段专注 · \(store.statistics.pomodoroCount) 个番茄"
        return Group {
            if compact {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日专注").font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
                        total
                    }
                    Spacer()
                    Text(counts).font(.system(size: 14)).foregroundStyle(ThemeColors.inkSoft).multilineTextAlignment(.trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日专注").font(.system(size: 14)).foregroundStyle(ThemeColors.inkSoft)
                    total
                    Text(counts).font(.system(size: 14)).foregroundStyle(ThemeColors.inkSoft)
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // 按科目：名称、时长与一条比例条；百分比和顺序都来自服务。
    @ViewBuilder private var categoryCard: some View {
        if !store.categoryStatistics.categories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("按科目").font(.system(size: 14)).foregroundStyle(ThemeColors.inkSoft)
                ForEach(Array(store.categoryStatistics.categories.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(store.formatDuration(item.duration)).monospacedDigit()
                        }
                        .font(.system(size: 14)).foregroundStyle(ThemeColors.inkStrong)
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule().fill(ThemeColors.accentFill)
                                Capsule().fill(TaskCategoryColor.value(item.color))
                                    .frame(width: bar.size.width * min(max(item.percentage, 0), 100) / 100)
                            }
                        }
                        .frame(height: 8)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.name + "，" + store.formatDuration(item.duration))
                }
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        }
    }

    // 窄：顶部汇总卡，下面一张记录卡（时间、色条、任务与时长），左滑删除。
    private func compactBody(_ geometry: GeometryProxy) -> some View {
        let blocks = TimelineLayout.blocks(store.visibleSessions, day: store.selectedDate)
        return List {
            header.plainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
            if !store.error.isEmpty || store.isFutureDate {
                notices.plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
            }
            totalCard(compact: true).plainRow(insets: EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))
            if activeStartMinute != nil {
                activeBlock.plainRow(insets: EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))
            }
            ForEach(Array(blocks.enumerated()), id: \.element.session.timelineID) { index, block in
                VStack(spacing: 0) {
                    if index > 0 { CardDivider() }
                    Button { editing = block.session } label: { compactRow(block) }.buttonStyle(.plain)
                }
                .cardRow(blocks.count == 1 ? .single : index == 0 ? .top : index == blocks.count - 1 ? .bottom : .middle)
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) { _ = store.deleteSession(block.session) }.tint(ThemeColors.danger)
                }
            }
        }
        .modifier(PageListModifier(geometry: geometry, compact: true))
    }

    private func compactRow(_ block: TimelineBlock) -> some View {
        let session = block.session
        return HStack(spacing: 14) {
            Text(clock(block.startMinute)).font(.system(size: 14)).monospacedDigit().foregroundStyle(ThemeColors.inkSoft)
                .frame(width: 48, alignment: .leading)
            Capsule().fill(session.isRest ? ThemeColors.focusBreakAccent : ThemeColors.accentInk).frame(width: 4, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                if session.isRest {
                    Text("休息 · " + store.formatDuration(session.durationSeconds)).font(.system(size: 17))
                        .foregroundStyle(ThemeColors.focusBreakInk)
                } else {
                    Text(session.taskTitle.isEmpty ? "自由专注" : session.taskTitle).font(.system(size: 17))
                        .foregroundStyle(ThemeColors.inkStrong).lineLimit(1)
                    Text(store.formatDuration(session.durationSeconds)).font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).frame(minHeight: 68)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var errorRow: some View {
        HStack {
            Text(store.error).foregroundStyle(ThemeColors.danger)
            Spacer()
            Button("重试") { store.selectDate(store.selectedDate) }.buttonStyle(SoftPillStyle())
        }
    }
    private func shiftDate(_ delta: Int) {
        if let date = store.adjacentDate(days: delta) { store.selectDate(date) }
    }
}
