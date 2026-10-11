import IPadCore
import SwiftUI

@MainActor struct ScheduleEntrySheet: View {
    let store: ScheduleStore
    let categories: any CategoryBridgeProtocol
    let original: ScheduleEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduleEntry
    @State private var startText: String
    @State private var endText: String
    @State private var weekStartText: String
    @State private var weekEndText: String
    @State private var categoryOptions: [CategoryValue] = []
    @State private var error = ""
    @State private var conflictText = ""
    @State private var confirmingDelete = false

    init(store: ScheduleStore, categories: any CategoryBridgeProtocol, entry: ScheduleEntry?, weekday: Int, minutes: Int) {
        self.store = store; self.categories = categories; original = entry
        var initial = entry ?? ScheduleEntry()
        if entry == nil {
            initial.weekday = weekday; initial.startMinutes = minutes
            initial.endMinutes = min(1440, minutes + 45)
            initial.weekEnd = store.settings.semesterWeeks
        }
        _draft = State(initialValue: initial)
        _startText = State(initialValue: ScheduleFormat.formatMinutes(Double(initial.startMinutes)))
        _endText = State(initialValue: ScheduleFormat.formatMinutes(Double(initial.endMinutes)))
        _weekStartText = State(initialValue: String(initial.weekStart))
        _weekEndText = State(initialValue: String(initial.weekEnd))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("课程") {
                    TextField("课程名称", text: $draft.title)
                    TextField("地点", text: $draft.location)
                    Picker("星期", selection: $draft.weekday) {
                        ForEach(1...7, id: \.self) { day in Text("星期" + ScheduleView.weekdayName(day)).tag(day) }
                    }
                    Picker("科目", selection: $draft.categoryID) {
                        Text("不关联科目").tag(-1)
                        // 删除中的科目或刷新后已不可读的旧归属仍保留，打开表单不等于清空归属。
                        if draft.categoryID != -1 && !categoryOptions.contains(where: { $0.id == draft.categoryID }) {
                            Text(draft.categoryName.isEmpty ? "原科目" : draft.categoryName).tag(draft.categoryID)
                        }
                        ForEach(categoryOptions, id: \.id) { category in Text(category.name).tag(category.id) }
                    }
                }
                Section("时间") {
                    TextField("开始 HH:mm", text: $startText).keyboardType(.numbersAndPunctuation)
                    TextField("结束 HH:mm（支持 24:00）", text: $endText).keyboardType(.numbersAndPunctuation)
                    if !store.periods.isEmpty {
                        Menu("按节次填充") {
                            ForEach(Array(store.periods.enumerated()), id: \.offset) { _, period in
                                Button("第 \(period.index) 节  \(ScheduleFormat.formatMinutes(Double(period.startMinutes)))–\(ScheduleFormat.formatMinutes(Double(period.endMinutes)))") {
                                    startText = ScheduleFormat.formatMinutes(Double(period.startMinutes))
                                    endText = ScheduleFormat.formatMinutes(Double(period.endMinutes))
                                }
                            }
                        }
                    }
                }
                Section("生效周次") {
                    TextField("开始周", text: $weekStartText).keyboardType(.numberPad)
                    TextField("结束周", text: $weekEndText).keyboardType(.numberPad)
                    Picker("单双周", selection: $draft.weekParity) {
                        Text("每周").tag(0); Text("单周").tag(1); Text("双周").tag(2)
                    }
                }
                if !conflictText.isEmpty { Section { Text(conflictText).foregroundStyle(ThemeColors.inkSoft) } }
                if !error.isEmpty { Section { Text(error).foregroundStyle(ThemeColors.danger).accessibilityLabel("错误：" + error) } }
                if let original {
                    Section { Button("删除课程", role: .destructive) { confirmingDelete = true } }
                    .confirmationDialog("删除「\(original.title)」？", isPresented: $confirmingDelete) {
                        Button("删除", role: .destructive) {
                            if store.deleteEntry(id: original.id) { dismiss() } else { error = store.error }
                        }
                    } message: { Text("该课程会从整张课表移除。") }
                }
            }
            .navigationTitle(original == nil ? "添加课程" : "编辑课程").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
        .presentationDetents([.large])
        .task {
            do { categoryOptions = try categories.allCategories(); refreshConflict() }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: draft) { refreshConflict() }
        .onChange(of: startText) { refreshConflict() }
        .onChange(of: endText) { refreshConflict() }
        .onChange(of: weekStartText) { refreshConflict() }
        .onChange(of: weekEndText) { refreshConflict() }
    }
    private func parsedDraft() -> ScheduleEntry? {
        let start = ScheduleFormat.parseMinutes(startText), end = ScheduleFormat.parseMinutes(endText)
        guard start >= 0, end >= 0, let weekStart = Int(weekStartText), let weekEnd = Int(weekEndText) else { return nil }
        var value = draft
        value.startMinutes = start; value.endMinutes = end; value.weekStart = weekStart; value.weekEnd = weekEnd
        return value
    }
    private func refreshConflict() {
        conflictText = ""
        guard let value = parsedDraft() else { return }
        do {
            // 冲突仅作提示；是否允许保存由服务决定，不在 Swift 拦截并列课程。
            if let row = try store.conflicts(for: value).first {
                conflictText = "与「\(row.title)」\(ScheduleFormat.formatMinutes(Double(row.startMinutes)))–\(ScheduleFormat.formatMinutes(Double(row.endMinutes))) 重叠，仍可保存"
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard let value = parsedDraft() else { error = "时间格式应为 HH:mm，周次应为整数"; return }
        if store.saveEntry(value, original: original) { dismiss() } else { error = store.error }
    }
}
