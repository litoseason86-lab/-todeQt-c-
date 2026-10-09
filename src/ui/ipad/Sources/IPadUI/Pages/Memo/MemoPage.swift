import IPadCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor struct MemoPage: View {
    @Environment(MemoStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var categorySheet = false
    @State private var newCategoryName = ""

    var body: some View {
        NavigationSplitView(preferredCompactColumn: Binding(get: { compactColumn }, set: { column in
            if column == .sidebar { commitInput(); if !store.leaveDetail() { return } }
            compactColumn = column
        })) {
            ScrollViewReader { proxy in
                List(selection: Binding(get: { store.selectedID }, set: { id in
                    commitInput(); if let id, store.selectMemo(id) { compactColumn = .detail }
                })) {
                    if !store.errorMessage.isEmpty { errorRow }
                    if !store.items.isEmpty {
                        Section {
                            ScrollView(.horizontal) {
                                Picker("分类", selection: Binding(get: { store.filterCategoryID }, set: { id in commitInput(); _ = store.selectFilter(id) })) {
                                    ForEach(store.categoryFilters, id: \.self) { id in Text(id == -1 ? "全部" : store.categoryName(id)).tag(id) }
                                }.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                    ForEach(store.categoryFilters.filter { $0 != -1 }, id: \.self) { category in
                        let rows = store.rows(categoryID: category)
                        if !rows.isEmpty {
                            Section(store.categoryName(category)) {
                                ForEach(rows) { memo in
                                    NavigationLink(value: memo.id) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(MemoFormat.shownTitle(title: memo.title, body: memo.body)).foregroundStyle(ThemeColors.ink)
                                            Text(MemoFormat.formatUpdatedAt(memo.updatedAt, now: store.displayNow)).font(.caption).foregroundStyle(ThemeColors.inkSoft)
                                        }
                                    }
                                    .id(memo.id)
                                    .listRowBackground(ThemeColors.surface)
                                    .contextMenu { moveMenu(memo) }
                                    .swipeActions { Button("删除", role: .destructive) { requestDelete(memo.id) } }
                                    .onDrag {
                                        commitInput()
                                        guard store.beginDrag(memo.id) else { return NSItemProvider() }
                                        return NSItemProvider(object: "\(memo.id)" as NSString)
                                    }
                                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in store.drop(before: memo.id) }
                                }
                            }
                        }
                    }
                }
                .onChange(of: store.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
            .navigationTitle("备忘录")
            .toolbar {
                Menu("新建", systemImage: "plus") {
                    Button("新建备忘录") { commitInput(); if store.createNew() { compactColumn = .detail } }
                    Button("新建分类…") { commitInput(); categorySheet = true }
                }
                Button("记一笔", systemImage: "square.and.pencil") { shell.presentCapture() }
            }
        } detail: {
            if store.selectedID != nil {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(store.categoryName(store.editorCategoryID)).foregroundStyle(ThemeColors.inkSoft)
                        Spacer()
                        let updated = MemoFormat.formatUpdatedAt(store.updatedAt, now: store.displayNow)
                        if !updated.isEmpty { Text(updated + " 更新").font(.caption).foregroundStyle(ThemeColors.inkSoft) }
                    }
                    if !store.errorMessage.isEmpty { errorRow }
                    MemoTitleEditor(text: store.editorTitle, isComposing: store.titleComposing,
                                    focusGeneration: store.titleFocusGeneration,
                                    onComposition: store.setTitleComposing, onText: store.editTitle)
                        .frame(height: 44)
                    MarkedTextEditor(text: Binding(get: { store.editorBody }, set: { store.editBody($0) }),
                                     isComposing: Binding(get: { store.bodyComposing }, set: { store.setBodyComposing($0) }))
                    if store.remoteDeleted {
                        HStack {
                            Button("另存为新备忘") { commitInput(); _ = store.saveDeletedAsNew() }
                            Button("放弃修改", role: .destructive) { commitInput(); store.discardDeleted() }
                        }.buttonStyle(.bordered)
                    }
                }.padding().background(ThemeColors.surface).navigationTitle("备忘录")
            } else { Color.clear }
        }
        .sheet(isPresented: $categorySheet) { categoryPicker }
        .confirmationDialog("删除「\(store.pendingDelete.map { MemoFormat.shownTitle(title: $0.title, body: $0.body) } ?? "")」？", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.cancelDelete() } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { commitInput(); store.confirmDelete() }
            Button("取消", role: .cancel) { store.cancelDelete() }
        }
        .onAppear { store.setActive(shell.selection == .memo) }
        .onDisappear { commitInput(); store.setActive(false) }
        .onChange(of: shell.selection) { _, page in
            if page != .memo { commitInput() }; store.setActive(page == .memo)
        }
        .onChange(of: store.titleFocusGeneration) { _, _ in compactColumn = .detail }
        .task {
            // 更新时间是显示口径，停在页面时每分钟重算；不计算业务逻辑日或触发写入。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                store.refresh()
            }
        }
    }
    private var errorRow: some View {
        VStack(alignment: .leading) {
            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
            if store.errorFromRead { Button("重试") { store.refresh() } }
        }
    }
    @ViewBuilder private func moveMenu(_ memo: MemoValue) -> some View {
        Menu("改分类") {
            ForEach(store.moveCategoryIDs, id: \.self) { category in
                Button {
                    commitInput(); _ = store.moveCategory(id: memo.id, to: category)
                } label: {
                    if memo.categoryID == category { Label(store.categoryName(category), systemImage: "checkmark") }
                    else { Text(store.categoryName(category)) }
                }
            }
        }
        Button("删除", role: .destructive) { requestDelete(memo.id) }
    }
    private var categoryPicker: some View {
        NavigationStack {
            Form {
                if !store.unusedCategories.isEmpty {
                    ForEach(store.unusedCategories, id: \.id) { category in
                        Button(category.name) { if store.createNew(categoryID: category.id) { categorySheet = false; compactColumn = .detail } }
                    }
                } else {
                    TextField("科目名称", text: $newCategoryName)
                    Button("新建") {
                        // 表单取色沿用 Mac；科目合法性与写入仍由服务负责。
                        if store.createCategory(name: newCategoryName, color: store.newCategoryColor) { categorySheet = false; newCategoryName = ""; compactColumn = .detail }
                    }
                }
                if !store.errorMessage.isEmpty { errorRow }
            }
            .navigationTitle("新建分类")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { categorySheet = false } } }
        }
    }
    private func requestDelete(_ id: Int) { commitInput(); if store.selectMemo(id) { store.requestDelete() } }
    private func commitInput() {
        // 切换与后台保存只打断输入一次；UIKit 先结束组合，再由编辑器回调把上屏文字交给 Store。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
