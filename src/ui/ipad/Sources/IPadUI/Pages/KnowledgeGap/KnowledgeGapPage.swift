import IPadCore
import SwiftUI

@MainActor struct KnowledgeGapPage: View {
    @Environment(GapStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("知识缺口").font(.largeTitle.bold())
                    Text("\(store.items.count) 条\(store.statusFilter == 2 ? "已解决" : "未解决")")
                        .font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                }
                if wide {
                    HStack(alignment: .top, spacing: 20) {
                        listCard.frame(width: min(380, geometry.size.width * 0.38))
                        if let gap = store.selected { detail(gap).frame(maxWidth: .infinity) }
                        else { ThemeColors.surface.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 18)) }
                    }
                } else { listCard }
            }
            .padding(.horizontal, wide ? 32 : 16).padding(.vertical, 16)
            .navigationDestination(isPresented: Binding(get: { !wide && store.detailPresented }, set: { if !$0 { store.closeDetail() } })) {
                if let gap = store.selected {
                    detail(gap).padding(16).navigationTitle("知识缺口")
                        .onAppear { store.setActive(true) }.onDisappear { store.setActive(false) }
                }
            }
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbar { Button("新增", systemImage: "plus") { store.requestForm(.add) } }
        .sheet(item: Binding(get: { store.form }, set: { if $0 == nil { store.dismissForm() } })) { intent in
            GapSheet(intent: intent, store: store, subjects: store.categories)
        }
        .confirmationDialog("删除「\(store.pendingDelete?.title ?? "")」？", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.cancelDelete() } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.confirmDelete() }
            Button("取消", role: .cancel) { store.cancelDelete() }
        }
        .onAppear { store.setActive(true) }.onDisappear { store.setActive(false) }
    }
    private var listCard: some View {
        @Bindable var binding = store
        return VStack(spacing: 12) {
            Picker("状态", selection: $binding.statusFilter) {
                Text("未解决").tag(-2); Text("已解决").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 16)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(ThemeColors.inkMuted).accessibilityHidden(true)
                TextField("搜索", text: $binding.search).accessibilityLabel("搜索知识缺口")
            }.padding(10).background(ThemeColors.surfaceSunken, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
            List {
                if !store.errorMessage.isEmpty { errorRow }
                ForEach(store.items) { gap in
                    Button { store.select(gap.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(gap.title).font(.headline).foregroundStyle(ThemeColors.ink)
                            metadata(gap)
                            if !gap.linkedTaskTitle.isEmpty {
                                Text("已转成任务：\(gap.linkedTaskTitle)").font(.caption).foregroundStyle(ThemeColors.inkMuted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(store.selectedID == gap.id ? ThemeColors.accentSoft : ThemeColors.surface)
                    .contextMenu { Button("删除", systemImage: "trash", role: .destructive) { store.requestDelete(gap) } }
                    .accessibilityElement(children: .combine)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).contentMargins(.top, 0, for: .scrollContent)
        }
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: store.statusFilter) { store.refresh() }
        .onChange(of: store.search) { store.refresh() }
    }
    private func detail(_ gap: GapValue) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(gap.title).font(.title2.bold()).foregroundStyle(ThemeColors.inkStrong)
                metadata(gap)
                if !store.errorMessage.isEmpty { errorRow }
                VStack(alignment: .leading, spacing: 8) {
                    Text("当时遇到了什么").font(.headline).foregroundStyle(ThemeColors.inkSoft)
                    Text(gap.detail.isEmpty ? "—" : gap.detail).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("后来想明白了什么").font(.headline).foregroundStyle(ThemeColors.inkSoft)
                    Text(gap.resolution.isEmpty ? "—" : gap.resolution).textSelection(.enabled)
                }
                if !gap.linkedTaskTitle.isEmpty {
                    Text("已转成任务：\(gap.linkedTaskTitle)").foregroundStyle(ThemeColors.inkMuted)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    Button { store.convert(gap) } label: { Text("今天做").frame(maxWidth: .infinity) }
                        .disabled(gap.status == 2 || gap.linkedTaskOpen)
                    Button { store.requestForm(.schedule(gap)) } label: { Text("排期").frame(maxWidth: .infinity) }
                        .disabled(gap.status == 2)
                    Button {
                        if gap.status == 2 { store.reopen(gap) } else { store.requestForm(.resolve(gap)) }
                    } label: { Text(gap.status == 2 ? "重新打开" : "解决").frame(maxWidth: .infinity) }
                    Button { store.requestForm(.edit(gap)) } label: { Text("编辑").frame(maxWidth: .infinity) }
                }.buttonStyle(.bordered).controlSize(.large)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
        .contextMenu { Button("删除", systemImage: "trash", role: .destructive) { store.requestDelete(gap) } }
    }
    private func metadata(_ gap: GapValue) -> some View {
        // 颜色只消费服务的到期事实；不拿 Swift 日期比较来派生今天或逾期。
        let prefix = (gap.categoryName.isEmpty ? "未分类" : gap.categoryName) + " · " + priority(gap.priority) + " · "
        let color = gap.overdue ? ThemeColors.danger : gap.dueToday ? ThemeColors.accentInk : ThemeColors.inkSoft
        return Text("\(Text(prefix).foregroundStyle(ThemeColors.inkSoft))\(Text(dueText(gap)).foregroundStyle(color))")
            .font(.subheadline)
    }
    private func priority(_ value: Int) -> String { switch value { case 2: "高"; case 1: "中"; default: "低" } }
    private func dueText(_ gap: GapValue) -> String {
        if gap.overdue { return "逾期 \(gap.overdueDays) 天" }
        if gap.dueToday { return "今天到期" }
        return gap.scheduled ? TrashFormat.dateLabel(gap.dueDate, today: store.logicalToday) : "未排期"
    }
    private var errorRow: some View {
        VStack(alignment: .leading) {
            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
            Button("重试") { store.refresh() }
        }
    }
}

@MainActor private struct GapSheet: View {
    let intent: GapFormIntent
    let store: GapStore
    var subjects: [CategoryValue] { store.categories }
    @Environment(\.dismiss) private var dismiss
    @State private var value: GapValue
    init(intent: GapFormIntent, store: GapStore, subjects: [CategoryValue]) {
        self.intent = intent; self.store = store
        var value = intent.gap ?? GapValue(); if intent.gap == nil { value.priority = 1 }
        _value = State(initialValue: value)
    }
    var body: some View {
        NavigationStack {
            Form {
                switch intent {
                case .add, .edit:
                    TextField("标题", text: $value.title)
                    Picker("科目", selection: $value.categoryID) {
                        Text("不指定").tag(0)
                        ForEach(subjects, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("优先级", selection: $value.priority) { Text("低").tag(0); Text("中").tag(1); Text("高").tag(2) }
                    Section("当时遇到了什么") { TextEditor(text: $value.detail).frame(minHeight: 120) }
                    dateFields
                case .schedule: dateFields
                case .resolve: Section("后来想明白了什么") { TextEditor(text: $value.resolution).frame(minHeight: 180) }
                }
                if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle(intent.gap == nil ? "新增知识缺口" : "知识缺口")
            .onChange(of: subjects.map(\.id)) { _, ids in
                // 同步删科目后不能把已不存在的外键交回服务；不改其它已输入字段。
                if value.categoryID > 0 && !ids.contains(value.categoryID) { value.categoryID = 0 }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }
    private var dateFields: some View {
        Group {
            Toggle("排期", isOn: Binding(get: { !value.dueDate.isEmpty }, set: { enabled in value.dueDate = enabled ? store.logicalToday : "" }))
            if !value.dueDate.isEmpty {
                DatePicker("到期日", selection: Binding(get: { ContentDateFormat.date(value.dueDate) ?? ContentDateFormat.date(store.logicalToday) ?? Date() }, set: { value.dueDate = ContentDateFormat.isoDate($0) }), displayedComponents: .date)
            }
        }
    }
    private func save() {
        let ok: Bool
        switch intent {
        case .add: ok = store.add(title: value.title, categoryID: value.categoryID, detail: value.detail, priority: value.priority, dueDate: value.dueDate)
        case .edit(let opened): ok = store.update(opened: opened, edited: value)
        case .schedule(let gap): ok = store.schedule(gap, date: value.dueDate)
        case .resolve(let gap): ok = store.resolve(gap, resolution: value.resolution)
        }
        if ok { dismiss() }
    }
}
