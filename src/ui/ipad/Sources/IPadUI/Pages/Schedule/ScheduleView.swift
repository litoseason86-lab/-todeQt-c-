import IPadCore
import SwiftUI

@MainActor struct ScheduleView: View {
    @Bindable var store: ScheduleStore
    let categories: any CategoryBridgeProtocol
    @State private var editor: EntryPresentation?
    @State private var settingsPresented = false
    @State private var deleting: ScheduleEntry?
    @Environment(\.horizontalSizeClass) private var sizeClass
    private struct EntryPresentation: Identifiable {
        let id = UUID()
        let entry: ScheduleEntry?
        let weekday: Int
        let minutes: Int
    }
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "课表", subtitle: subtitle)
                if !store.error.isEmpty {
                    HStack {
                        Text(store.error).foregroundStyle(ThemeColors.danger)
                        Spacer()
                        Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle())
                    }
                }
                if narrow { weekdaySelector }
                if store.settings.semesterStartDate.isEmpty {
                    ContentUnavailableView {
                        Label("设置学期起始日", systemImage: "calendar")
                    } actions: { Button("课表设置") { settingsPresented = true }.buttonStyle(ProminentPillStyle()) }
                } else {
                    if narrow { compactList }
                    else { WeekGrid(store: store, weekdays: store.visibleWeekdays,
                             add: { day, minutes in editor = EntryPresentation(entry: nil, weekday: day, minutes: minutes) },
                             edit: { entry in editor = EntryPresentation(entry: entry, weekday: entry.weekday, minutes: entry.startMinutes) },
                             delete: { deleting = $0 })
                        if !store.undisplayedEntryTitles.isEmpty { hiddenMessage }
                    }
                }
            }
            .padding(.top, 4).padding(.bottom, narrow ? 0 : 24)
            .safeAreaPadding(.horizontal, Design.pagePadding(compact: narrow))
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { store.goToWeek(store.weekIndex - 1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一周").disabled(store.weekIndex <= 1)
                Button { store.goToWeek(store.weekIndex + 1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一周").disabled(store.weekIndex >= store.settings.semesterWeeks)
                if sizeClass != .compact {
                    Picker("显示方式", selection: Binding(get: { store.displayMode }, set: { _ = store.setDisplayMode($0) })) {
                        Text("时间").tag(ScheduleDisplayMode.time); Text("节次").tag(ScheduleDisplayMode.period)
                    }.pickerStyle(.segmented).frame(width: 132)
                }
                Button("添加", systemImage: "plus") {
                    editor = EntryPresentation(entry: nil, weekday: store.selectedWeekday, minutes: 480)
                }
                Menu {
                    Button("本周") { store.goToCurrentWeek() }
                    Button("学期与节次设置", systemImage: "gearshape") { settingsPresented = true }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $editor) { item in
            ScheduleEntrySheet(store: store, categories: categories, entry: item.entry,
                               weekday: item.weekday, minutes: item.minutes)
        }
        .sheet(isPresented: $settingsPresented) { ScheduleSettingsSheet(store: store) }
        .confirmationDialog("删除「\(deleting?.title ?? "")」？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let deleting { _ = store.deleteEntry(id: deleting.id) }
                deleting = nil
            }
        } message: { Text("该课程会从整张课表移除。") }
    }
    // 副标题：「第 6 周 · 10月6日 – 12日」，周次与日期都来自服务。
    private var subtitle: String {
        let first = store.dateForWeekday(1), last = store.dateForWeekday(7)
        guard !first.isEmpty else { return "" }
        return "第 \(store.weekIndex) 周 · " + WeekView.monthDay(first) + " – " + (first.prefix(7) == last.prefix(7) ? WeekView.day(last) + "日" : WeekView.monthDay(last))
    }
    // 窄：星期条（白卡片、选中焦糖实底、今天数字下一个红点），下面「时间 | 节次」，再下当天课程卡。
    private var weekdaySelector: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    let selected = store.selectedWeekday == day
                    let today = store.weekIndex == store.currentWeekIndex && store.todayWeekday == day
                    Button { store.selectWeekday(day) } label: {
                        VStack(spacing: 2) {
                            Text(Self.weekdayName(day)).scaledSystemFont(size: 12)
                            Text(WeekView.day(store.dateForWeekday(day))).scaledSystemFont(size: 18, weight: .semibold).monospacedDigit()
                            Circle().fill(today && !selected ? ThemeColors.danger : Color.clear).frame(width: 4, height: 4)
                        }
                        .foregroundStyle(selected ? ThemeColors.surface : ThemeColors.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(selected ? ThemeColors.accentInk : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("周" + Self.weekdayName(day) + (today ? "，今天" : ""))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(6)
            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
            Picker("显示方式", selection: Binding(get: { store.displayMode }, set: { _ = store.setDisplayMode($0) })) {
                Text("时间").tag(ScheduleDisplayMode.time); Text("节次").tag(ScheduleDisplayMode.period)
            }.pickerStyle(.segmented)
        }
    }
    private var hiddenMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(ThemeColors.accentInk)
            Text("未显示：" + store.undisplayedEntryTitles.joined(separator: "、"))
        }
        .scaledSystemFont(size: 14).foregroundStyle(ThemeColors.ink)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.accentFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private var compactList: some View {
        let entries = store.selectedDayEntries
        return List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                VStack(spacing: 0) {
                    if index > 0 { CardDivider() }
                    Button { editor = EntryPresentation(entry: entry, weekday: entry.weekday, minutes: entry.startMinutes) } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                if store.displayMode == .period {
                                    Text(store.periodLabel(for: entry)).scaledSystemFont(size: 14, weight: .semibold).foregroundStyle(ThemeColors.inkStrong)
                                }
                                Text(ScheduleFormat.formatMinutes(Double(entry.startMinutes)) + "–" + ScheduleFormat.formatMinutes(Double(entry.endMinutes)))
                                    .scaledSystemFont(size: store.displayMode == .period ? 12 : 14, weight: store.displayMode == .period ? .regular : .semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(store.displayMode == .period ? ThemeColors.inkSoft : ThemeColors.inkStrong)
                            }
                            .frame(width: 92, alignment: .leading)
                            Capsule().fill(TaskCategoryColor.value(entry.categoryColor)).frame(width: 4, height: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).scaledSystemFont(size: 17).foregroundStyle(ThemeColors.inkStrong).lineLimit(1)
                                Text([entry.location, ScheduleFormat.weekRangeLabel(start: Double(entry.weekStart), end: Double(entry.weekEnd), parity: Double(entry.weekParity), semesterWeeks: Double(store.settings.semesterWeeks))].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .scaledSystemFont(size: 13).foregroundStyle(ThemeColors.inkSoft).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 68).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .cardRow(entries.count == 1 ? .single : index == 0 ? .top : index == entries.count - 1 ? .bottom : .middle)
                .contextMenu {
                    Button("编辑", systemImage: "pencil") { editor = EntryPresentation(entry: entry, weekday: entry.weekday, minutes: entry.startMinutes) }
                    Button("删除", systemImage: "trash", role: .destructive) { deleting = entry }
                }
            }
            if !store.undisplayedEntryTitles.isEmpty {
                hiddenMessage.plainRow(insets: EdgeInsets(top: 14, leading: 0, bottom: 0, trailing: 0))
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 1)
    }
    static func weekdayName(_ day: Int) -> String { ["一", "二", "三", "四", "五", "六", "日"][day - 1] }
}
