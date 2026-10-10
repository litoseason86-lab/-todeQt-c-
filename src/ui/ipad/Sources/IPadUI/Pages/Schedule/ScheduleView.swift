import IPadCore
import SwiftUI

@MainActor struct ScheduleView: View {
    @Bindable var store: ScheduleStore
    let categories: any CategoryBridgeProtocol
    @State private var editor: EntryPresentation?
    @State private var settingsPresented = false
    @State private var deleting: ScheduleEntry?
    private struct EntryPresentation: Identifiable {
        let id = UUID()
        let entry: ScheduleEntry?
        let weekday: Int
        let minutes: Int
    }
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            VStack(spacing: 0) {
                if !store.error.isEmpty {
                    HStack {
                        Text(store.error).foregroundStyle(ThemeColors.ink)
                        Spacer()
                        Button("重试") { store.refresh() }
                    }.padding().background(ThemeColors.surfaceRaised)
                }
                if narrow { weekdaySelector }
                if store.settings.semesterStartDate.isEmpty {
                    ContentUnavailableView {
                        Label("设置学期起始日", systemImage: "calendar")
                    } actions: { Button("课表设置") { settingsPresented = true } }
                } else {
                    if narrow { compactList }
                    else { WeekGrid(store: store, weekdays: store.visibleWeekdays,
                             add: { day, minutes in editor = EntryPresentation(entry: nil, weekday: day, minutes: minutes) },
                             edit: { entry in editor = EntryPresentation(entry: entry, weekday: entry.weekday, minutes: entry.startMinutes) },
                             delete: { deleting = $0 })
                        .padding(.horizontal, 32)
                        if !store.undisplayedEntryTitles.isEmpty { hiddenMessage.padding(.horizontal, 32) }
                    }
                }
            }
        }
        .navigationTitle("课表")
        .navigationSubtitle("第 \(store.weekIndex) 周 · " + store.dateForWeekday(1) + " – " + store.dateForWeekday(7))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { store.goToWeek(store.weekIndex - 1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一周").disabled(store.weekIndex <= 1)
                Button { store.goToWeek(store.weekIndex + 1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一周").disabled(store.weekIndex >= store.settings.semesterWeeks)
                Picker("显示方式", selection: Binding(get: { store.displayMode }, set: { _ = store.setDisplayMode($0) })) {
                    Text("时间").tag(ScheduleDisplayMode.time); Text("节次").tag(ScheduleDisplayMode.period)
                }.pickerStyle(.segmented).frame(width: 132)
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
    private var weekdaySelector: some View {
        HStack(spacing: 2) {
            ForEach(1...7, id: \.self) { day in
                Button { store.selectWeekday(day) } label: {
                    VStack(spacing: 4) {
                        Text(Self.weekdayName(day)).font(.callout)
                        Text(String(store.dateForWeekday(day).suffix(2))).font(.caption.monospacedDigit())
                        Circle().fill(store.weekIndex == store.currentWeekIndex && store.todayWeekday == day ? ThemeColors.accentInk : ThemeColors.surface.opacity(0)).frame(width: 4, height: 4).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, minHeight: 52)
                        .background(store.selectedWeekday == day ? ThemeColors.accentSoft : ThemeColors.surface, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("周" + Self.weekdayName(day))
            }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
    private var hiddenMessage: some View {
        Text("未显示：" + store.undisplayedEntryTitles.joined(separator: "、"))
            .font(.callout).foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var compactList: some View {
        List {
            ForEach(store.selectedDayEntries) { entry in
                Button { editor = EntryPresentation(entry: entry, weekday: entry.weekday, minutes: entry.startMinutes) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Capsule().fill(TaskCategoryColor.value(entry.categoryColor)).frame(width: 4)
                        VStack(alignment: .leading, spacing: 5) {
                            if store.displayMode == .period { Text(store.periodLabel(for: entry)).font(.caption).foregroundStyle(ThemeColors.accentInk) }
                            Text(ScheduleFormat.formatMinutes(Double(entry.startMinutes)) + "–" + ScheduleFormat.formatMinutes(Double(entry.endMinutes))).font(.caption.monospacedDigit()).foregroundStyle(ThemeColors.inkSoft)
                            Text(entry.title).font(.headline)
                            Text([entry.location, ScheduleFormat.weekRangeLabel(start: Double(entry.weekStart), end: Double(entry.weekEnd), parity: Double(entry.weekParity), semesterWeeks: Double(store.settings.semesterWeeks))].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.callout).foregroundStyle(ThemeColors.inkSoft)
                        }
                        Spacer()
                    }.padding(.vertical, 8).foregroundStyle(ThemeColors.ink)
                }.buttonStyle(.plain).listRowBackground(ThemeColors.surface)
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { editor = EntryPresentation(entry: entry, weekday: entry.weekday, minutes: entry.startMinutes) }
                        Button("删除", systemImage: "trash", role: .destructive) { deleting = entry }
                    }
            }
            if !store.undisplayedEntryTitles.isEmpty { hiddenMessage.listRowBackground(ThemeColors.surface) }
        }.listStyle(.plain).scrollContentBackground(.hidden).padding(.horizontal, 16)
    }
    static func weekdayName(_ day: Int) -> String { ["一", "二", "三", "四", "五", "六", "日"][day - 1] }
}
