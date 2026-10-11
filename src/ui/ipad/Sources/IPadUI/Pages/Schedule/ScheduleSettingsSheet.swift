import IPadCore
import SwiftUI

@MainActor struct ScheduleSettingsSheet: View {
    let store: ScheduleStore
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: String
    @State private var weeks: String
    @State private var showWeekend: Bool
    @State private var periodDrafts: [PeriodDraft]
    @State private var error = ""
    private struct PeriodDraft: Identifiable {
        let id = UUID()
        var start: String
        var end: String
    }
    init(store: ScheduleStore) {
        self.store = store
        _startDate = State(initialValue: store.settings.semesterStartDate)
        _weeks = State(initialValue: String(store.settings.semesterWeeks))
        _showWeekend = State(initialValue: store.settings.showWeekend)
        _periodDrafts = State(initialValue: store.periods.map {
            PeriodDraft(start: ScheduleFormat.formatMinutes(Double($0.startMinutes)), end: ScheduleFormat.formatMinutes(Double($0.endMinutes)))
        })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("学期") {
                    TextField("起始日 yyyy-MM-dd（可留空）", text: $startDate).keyboardType(.numbersAndPunctuation)
                    TextField("总周数", text: $weeks).keyboardType(.numberPad)
                    Toggle("显示周末", isOn: $showWeekend)
                }
                Section {
                    ForEach($periodDrafts) { $period in
                        VStack(alignment: .leading, spacing: 8) {
                            let number = (periodDrafts.firstIndex { $0.id == period.id } ?? 0) + 1
                            HStack {
                                Text("第 \(number) 节")
                                Spacer()
                                Button("移除", role: .destructive) { periodDrafts.removeAll { $0.id == period.id } }
                                    .accessibilityLabel("移除第 \(number) 节")
                            }
                            TextField("开始 HH:mm", text: $period.start).keyboardType(.numbersAndPunctuation)
                                .accessibilityLabel("第 \(number) 节开始时间")
                            TextField("结束 HH:mm", text: $period.end).keyboardType(.numbersAndPunctuation)
                                .accessibilityLabel("第 \(number) 节结束时间")
                        }
                    }
                    Button("添加节次", systemImage: "plus") {
                        // 空文本要求用户明确输入，不根据旧节次猜测学校的间隔规则。
                        periodDrafts.append(PeriodDraft(start: "", end: ""))
                    }.disabled(periodDrafts.count >= store.maxPeriodCount)
                } header: { Text("节次") } footer: { Text("节次与学期设置全部保存成功后才关闭。节次排序、重叠和学期范围由服务校验。") }
                if !error.isEmpty { Section { Text(error).foregroundStyle(ThemeColors.danger).accessibilityLabel("错误：" + error) } }
            }
            .scrollContentBackground(.hidden).background(ThemeColors.surface)
            .navigationTitle("课表设置").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }.presentationDetents([.large])
    }
    private func save() {
        guard let weeks = Int(weeks) else { error = "学期总周数应为整数"; return }
        var periods: [SchedulePeriod] = []
        for (index, row) in periodDrafts.enumerated() {
            let start = ScheduleFormat.parseMinutes(row.start), end = ScheduleFormat.parseMinutes(row.end)
            guard start >= 0, end >= 0 else { error = "第 \(index + 1) 行节次时间格式应为 HH:mm"; return }
            periods.append(SchedulePeriod(startMinutes: start, endMinutes: end))
        }
        let draft = ScheduleSettings(semesterStartDate: startDate.trimmingCharacters(in: .whitespacesAndNewlines), semesterWeeks: weeks, showWeekend: showWeekend)
        if store.saveSettings(draft, periods: periods) { dismiss() } else { error = store.error }
    }
}
