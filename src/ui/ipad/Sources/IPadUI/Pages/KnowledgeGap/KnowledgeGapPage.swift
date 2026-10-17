import IPadCore
import SwiftUI

@MainActor struct KnowledgeGapPage: View {
    @Environment(GapStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "知识缺口", subtitle: subtitle)
                if wide {
                    // 定稿：左边列表卡（最宽 380）、右边详情卡，两张卡都只包住内容，长了在卡内滚动。
                    HStack(alignment: .top, spacing: 20) {
                        ScrollView { listCard(compact: false) }.scrollIndicators(.hidden)
                            .frame(width: min(380, geometry.size.width * 0.38))
                        ScrollView { if let gap = store.selected { detail(gap) } }.scrollIndicators(.hidden)
                            .frame(maxWidth: .infinity)
                    }
                    .onAppear { selectFirstIfNeeded() }
                    .onChange(of: store.items.map(\.id)) { selectFirstIfNeeded() }
                } else {
                    ScrollView { listCard(compact: true) }.scrollIndicators(.hidden)
                }
            }
            .padding(.top, 4)
            .safeAreaPadding(.horizontal, wide ? Design.pageMargin(geometry: geometry, compact: false, maxWidth: 1100) : 16)
            .navigationDestination(isPresented: Binding(get: { !wide && store.detailPresented }, set: { if !$0 { store.closeDetail() } })) {
                if let gap = store.selected {
                    ScrollView { detail(gap).padding(16) }
                        .modifier(PageBackground())
                        .navigationTitle("知识缺口")
                        .onAppear { store.setActive(true) }.onDisappear { if shell.selection != .knowledgeGap { store.setActive(false) } }
                }
            }
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.requestForm(.add) } label: { ToolbarTextLabel(title: "新增", systemImage: "plus") }
                    // 新增从按钮弹出浮层（10-13 真机：系统表单开约 245 毫秒，浮层不走表单的背景缩放）；窄窗系统改成整页表单。
                    .popover(isPresented: Binding(get: { store.form == .add }, set: { if !$0 && store.form == .add { store.dismissForm() } })) {
                        GapSheet(intent: .add, store: store, subjects: store.categories).frame(idealWidth: 440, idealHeight: 560)
                    }
            }
        }
        // 编辑、排期、解决仍是整页表单：它们从详情里的按钮和长按菜单打开，两处入口没有共同的锚点。
        .sheet(item: Binding(get: { store.form == .add ? nil : store.form }, set: { if $0 == nil { store.dismissForm() } })) { intent in
            GapSheet(intent: intent, store: store, subjects: store.categories)
        }
        .confirmationDialog("删除「\(store.pendingDelete?.title ?? "")」？", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.cancelDelete() } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.confirmDelete() }
            Button("取消", role: .cancel) { store.cancelDelete() }
        }
        .onAppear { store.setActive(true) }
        .onDisappear {
            // 内部推入详情仍是同一业务页面，不依赖父子 onAppear/onDisappear 的先后顺序停掉订阅。
            if !store.detailPresented || shell.selection != .knowledgeGap { store.setActive(false) }
        }
        .onShellSelectionChange(shell) { page in store.setActive(page == .knowledgeGap) }
    }

    // 副标题：「5 条未解决 · 2 条到期」；到期数取外壳摘要（服务），已解决列表不写到期。
    private var subtitle: String {
        let base = "\(store.items.count) 条\(store.statusFilter == 2 ? "已解决" : "未解决")"
        return store.statusFilter != 2 && shell.dueGapCount > 0 ? base + " · \(shell.dueGapCount) 条到期" : base
    }

    // 宽窗进页时右边不留空卡：没有选中就选列表第一条（只是展示选择，不写数据）。
    // 只设选中，不标记「已推入」：否则窗口缩到窄时会自动推进详情（10-11 巡检截图）。
    private func selectFirstIfNeeded() {
        if store.selected == nil, let first = store.items.first { store.selectedID = first.id }
    }

    private func listCard(compact: Bool) -> some View {
        @Bindable var binding = store
        return VStack(spacing: 10) {
            Picker("状态", selection: $binding.statusFilter) {
                Text("未解决").tag(-2); Text("已解决").tag(2)
            }.pickerStyle(.segmented)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ThemeColors.inkSoft).accessibilityHidden(true)
                TextField("搜索", text: $binding.search).accessibilityLabel("搜索知识缺口")
            }
            .scaledSystemFont(size: 15)
            .padding(.horizontal, 12).frame(height: 40)
            .background(ThemeColors.accentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !store.errorMessage.isEmpty { errorRow }
            VStack(spacing: 2) {
                ForEach(store.items) { gap in
                    let selected = !compact && store.selectedID == gap.id
                    Button { store.select(gap.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(gap.title).scaledSystemFont(size: 16, weight: .semibold).foregroundStyle(ThemeColors.inkStrong)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Circle().fill(TaskCategoryColor.value(gap.categoryColor)).frame(width: 7, height: 7)
                                    .opacity(gap.categoryName.isEmpty ? 0 : 1).accessibilityHidden(true)
                                metadata(gap)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(selected ? ThemeColors.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { gapMenu(gap) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(12)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .onChange(of: store.statusFilter) { store.refresh() }
        .onChange(of: store.search) { store.refresh() }
    }

    // 定稿详情：大标题、科目 / 优先级 / 到期三个胶囊标签、两段原文（空写「—」）、四个同样宽的操作。
    private func detail(_ gap: GapValue) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(gap.title).scaledSystemFont(size: 26, weight: .bold).foregroundStyle(ThemeColors.inkStrong)
            HStack(spacing: 8) {
                tag {
                    HStack(spacing: 6) {
                        Circle().fill(TaskCategoryColor.value(gap.categoryColor)).frame(width: 7, height: 7)
                        Text(gap.categoryName.isEmpty ? "未分类" : gap.categoryName)
                    }
                }
                tag { Text("优先级 " + priority(gap.priority)) }
                tag { Text(dueText(gap)).fontWeight(gap.overdue || gap.dueToday ? .semibold : .regular).foregroundStyle(dueColor(gap)) }
            }
            if !store.errorMessage.isEmpty { errorRow }
            section("当时遇到了什么", gap.detail)
            section("后来想明白了什么", gap.resolution)
            if !gap.linkedTaskTitle.isEmpty {
                Text("已转成任务：\(gap.linkedTaskTitle)").scaledSystemFont(size: 15).foregroundStyle(ThemeColors.inkSoft)
            }
            // 四个操作同分量常驻：放得下就一行四个等宽，窄时两行两个。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions(gap) }
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow { actionButtons(gap)[0]; actionButtons(gap)[1] }
                    GridRow { actionButtons(gap)[2]; actionButtons(gap)[3] }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .contextMenu { gapMenu(gap) }
    }
    // 长按菜单与详情里的四个操作同一套（10-12 对齐提醒事项：列表行长按就能做，不必先点进详情）；删除仍先确认（10-04 定）。
    @ViewBuilder private func gapMenu(_ gap: GapValue) -> some View {
        Button("今天做", systemImage: "checklist") { store.convert(gap) }.disabled(gap.status == 2 || gap.linkedTaskOpen)
        Button("排期…", systemImage: "calendar") { store.requestForm(.schedule(gap)) }.disabled(gap.status == 2)
        if gap.status == 2 {
            Button("重新打开", systemImage: "arrow.uturn.backward") { store.reopen(gap) }
        } else {
            Button("解决…", systemImage: "checkmark.seal") { store.requestForm(.resolve(gap)) }
        }
        Button("编辑", systemImage: "pencil") { store.requestForm(.edit(gap)) }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { store.requestDelete(gap) }
    }
    @ViewBuilder private func actions(_ gap: GapValue) -> some View {
        ForEach(0..<4, id: \.self) { actionButtons(gap)[$0].frame(minWidth: 96) }
    }
    private func actionButtons(_ gap: GapValue) -> [AnyView] {
        [AnyView(action("今天做") { store.convert(gap) }.disabled(gap.status == 2 || gap.linkedTaskOpen)),
         AnyView(action("排期") { store.requestForm(.schedule(gap)) }.disabled(gap.status == 2)),
         AnyView(action(gap.status == 2 ? "重新打开" : "解决") {
             if gap.status == 2 { store.reopen(gap) } else { store.requestForm(.resolve(gap)) }
         }),
         AnyView(action("编辑") { store.requestForm(.edit(gap)) })]
    }
    private func tag<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().scaledSystemFont(size: 14).foregroundStyle(ThemeColors.ink)
            .padding(.horizontal, 12).frame(height: 30)
            .background(ThemeColors.accentFill, in: Capsule())
    }
    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).scaledSystemFont(size: 13, weight: .semibold).foregroundStyle(ThemeColors.inkSoft)
            Text(text.isEmpty ? "—" : text).scaledSystemFont(size: 16).foregroundStyle(ThemeColors.inkStrong).textSelection(.enabled)
        }
    }
    private func action(_ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(SoftPillStyle())
    }
    private func dueColor(_ gap: GapValue) -> Color {
        gap.overdue ? ThemeColors.danger : gap.dueToday ? ThemeColors.accentInk : ThemeColors.inkSoft
    }
    private func metadata(_ gap: GapValue) -> some View {
        // 颜色只消费服务的到期事实；不拿 Swift 日期比较来派生今天或逾期。
        let prefix = (gap.categoryName.isEmpty ? "未分类" : gap.categoryName) + " · " + priority(gap.priority) + " · "
        return Text("\(Text(prefix).foregroundStyle(ThemeColors.inkSoft))\(Text(dueText(gap)).foregroundStyle(dueColor(gap)).fontWeight(gap.overdue || gap.dueToday ? .semibold : .regular))")
            .scaledSystemFont(size: 13).lineLimit(1)
    }
    private func priority(_ value: Int) -> String { switch value { case 2: "高"; case 1: "中"; default: "低" } }
    private func dueText(_ gap: GapValue) -> String {
        if gap.overdue { return "逾期 \(gap.overdueDays) 天" }
        if gap.dueToday { return "今天到期" }
        return gap.scheduled ? TrashFormat.dateLabel(gap.dueDate, today: store.logicalToday) : "未排期"
    }
    private var errorRow: some View {
        HStack {
            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
            Spacer()
            Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle())
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
            .navigationTitle(intent.gap == nil ? "新增知识缺口" : "知识缺口").sheetChrome()
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
                DatePicker("到期日", selection: Binding(get: { ContentDateFormat.date(value.dueDate) ?? LogicalDateNavigation.dateOrLogicalToday(store.logicalToday) }, set: { value.dueDate = ContentDateFormat.isoDate($0) }), displayedComponents: .date)
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
