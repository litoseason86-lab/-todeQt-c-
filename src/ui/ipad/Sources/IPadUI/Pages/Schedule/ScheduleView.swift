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
                if !store.hiddenWeekendEntries.isEmpty || !store.unplacedEntries.isEmpty {
                    VStack(alignment: .leading) {
                        if !store.hiddenWeekendEntries.isEmpty { Text("有 \(store.hiddenWeekendEntries.count) 项被周末开关隐藏") }
                        if !store.unplacedEntries.isEmpty { Text("有 \(store.unplacedEntries.count) 项不在任何节次内") }
                    }.font(.callout).foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                HStack {
                    Button { store.goToWeek(store.weekIndex - 1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上一周").disabled(store.weekIndex <= 1)
                    Menu("第 \(store.weekIndex) 周") {
                        Button("本周") { store.goToCurrentWeek() }
                        ForEach(1...max(1, store.settings.semesterWeeks), id: \.self) { week in
                            Button("第 \(week) 周") { store.goToWeek(week) }
                        }
                    }
                    Button { store.goToWeek(store.weekIndex + 1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("下一周").disabled(store.weekIndex >= store.settings.semesterWeeks)
                    Spacer()
                    Picker("版式", selection: Binding(get: { store.displayMode }, set: { store.setDisplayMode($0) })) {
                        Text("时间轴").tag(ScheduleDisplayMode.time)
                        Text("节次").tag(ScheduleDisplayMode.period)
                    }.pickerStyle(.segmented).frame(maxWidth: 200)
                }.padding()
                if narrow {
                    Picker("星期", selection: Binding(get: { store.selectedWeekday }, set: { store.selectWeekday($0) })) {
                        ForEach(1...7, id: \.self) { day in Text(Self.weekdayName(day)).tag(day) }
                    }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                }
                if store.settings.semesterStartDate.isEmpty {
                    ContentUnavailableView {
                        Label("设置学期起始日", systemImage: "calendar")
                    } actions: { Button("课表设置") { settingsPresented = true } }
                } else {
                    WeekGrid(store: store, weekdays: narrow ? [store.selectedWeekday] : store.visibleWeekdays,
                             add: { day, minutes in editor = EntryPresentation(entry: nil, weekday: day, minutes: minutes) },
                             edit: { entry in editor = EntryPresentation(entry: entry, weekday: entry.weekday, minutes: entry.startMinutes) },
                             delete: { deleting = $0 })
                }
            }
        }
        .navigationTitle("课表")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("添加", systemImage: "plus") {
                    editor = EntryPresentation(entry: nil, weekday: store.selectedWeekday, minutes: 480)
                }
                Button("课表设置", systemImage: "gearshape") { settingsPresented = true }
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
    static func weekdayName(_ day: Int) -> String { ["一", "二", "三", "四", "五", "六", "日"][day - 1] }
}
