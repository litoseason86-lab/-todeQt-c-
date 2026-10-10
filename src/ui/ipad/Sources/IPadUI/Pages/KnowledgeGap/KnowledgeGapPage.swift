import IPadCore
import SwiftUI

@MainActor struct KnowledgeGapPage: View {
    @Environment(GapStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @State private var form: GapFormIntent?
    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selectedID) {
                if !store.errorMessage.isEmpty { errorRow }
                ForEach([0, 1, 2], id: \.self) { status in
                    let rows = store.gaps(status: status)
                    if !rows.isEmpty {
                        Section(["待处理", "已安排", "已解决"][status]) {
                            ForEach(rows) { gap in
                                NavigationLink(value: gap.id) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(gap.title).foregroundStyle(ThemeColors.ink)
                                        Text(GapFormat.meta(gap)).font(.caption).foregroundStyle(ThemeColors.inkSoft)
                                    }
                                }
                                .listRowBackground(ThemeColors.surface)
                            }
                        }
                    }
                }
            }
            .searchable(text: $store.search, prompt: "搜索")
            .onChange(of: store.search) { _, _ in store.refresh() }
            .safeAreaInset(edge: .top) {
                Picker("状态", selection: $store.statusFilter) {
                    Text("未解决").tag(-2); Text("已解决").tag(2)
                }.pickerStyle(.segmented).padding()
            }
            .onChange(of: store.statusFilter) { _, _ in store.refresh() }
            .navigationTitle("知识缺口")
            .toolbar {
                Button("新增", systemImage: "plus") { form = .add }
                Button("记一笔", systemImage: "square.and.pencil") { shell.presentCapture() }
            }
        } detail: {
            if let gap = store.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(gap.title).font(.title2).foregroundStyle(ThemeColors.inkStrong)
                        Text(GapFormat.meta(gap)).foregroundStyle(ThemeColors.inkSoft)
                        if !store.errorMessage.isEmpty { errorRow }
                        LabeledContent("当时遇到了什么") { Text(gap.detail).textSelection(.enabled) }
                        LabeledContent("后来想明白了什么") { Text(gap.resolution).textSelection(.enabled) }
                        if gap.linkedTaskOpen { Text("已转成任务：\(gap.linkedTaskTitle)").foregroundStyle(ThemeColors.inkSoft) }
                        // 四项同分量；自适应网格在窄窗换行，动态字体不会把按钮挤出窗口。
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                            Button("今天做") { store.convert(gap) }.disabled(gap.status == 2 || gap.linkedTaskOpen)
                            Button("排期") { form = .schedule(gap) }.disabled(gap.status == 2)
                            Button(gap.status == 2 ? "重新打开" : "解决") {
                                if gap.status == 2 { store.reopen(gap) } else { form = .resolve(gap) }
                            }
                            Button("编辑") { form = .edit(gap) }
                        }.buttonStyle(.bordered).controlSize(.large)
                        Button("删除", role: .destructive) { store.requestDelete(gap) }
                    }.padding().foregroundStyle(ThemeColors.ink)
                }.navigationTitle("知识缺口")
            } else { Color.clear }
        }
        .sheet(item: $form) { intent in GapSheet(intent: intent, store: store, subjects: store.categories) }
        .confirmationDialog("删除「\(store.pendingDelete?.title ?? "")」？", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.cancelDelete() } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.confirmDelete() }
            Button("取消", role: .cancel) { store.cancelDelete() }
        }
        .onAppear { store.setActive(true) }
        .onDisappear { store.setActive(false) }
    }
    private var errorRow: some View {
        VStack(alignment: .leading) {
            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
            Button("重试") { store.refresh() }
        }
    }
}

private enum GapFormIntent: Identifiable {
    case add, edit(GapValue), schedule(GapValue), resolve(GapValue)
    var id: String {
        switch self { case .add: "add"; case .edit(let g): "edit\(g.id)"; case .schedule(let g): "date\(g.id)"; case .resolve(let g): "resolve\(g.id)" }
    }
    var gap: GapValue? {
        switch self { case .add: nil; case .edit(let g), .schedule(let g), .resolve(let g): g }
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
