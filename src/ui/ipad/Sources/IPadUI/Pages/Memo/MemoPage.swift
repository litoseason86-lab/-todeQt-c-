import IPadCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor struct MemoPage: View {
    @Environment(MemoStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 20) {
                Text("备忘录").font(.largeTitle.bold())
                if wide {
                    HStack(alignment: .top, spacing: 20) {
                        listCard.frame(width: min(380, geometry.size.width * 0.38))
                        paper.frame(maxWidth: .infinity)
                    }
                } else { listCard }
            }
            .padding(.horizontal, wide ? 32 : 16).padding(.vertical, 16)
            .navigationDestination(isPresented: Binding(get: { !wide && store.detailPresented }, set: { value in
                if !value { commitInput(); _ = store.dismissMemo() }
            })) {
                paper.padding(16).navigationTitle("备忘录").navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("备忘录", systemImage: "chevron.left") { commitInput(); _ = store.dismissMemo() }
                        }
                    }
                    .onAppear { store.setActive(true) }.onDisappear { commitInput(); store.setActive(false) }
            }
            .onChange(of: wide) { commitInput() }
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbar {
            Menu("新建", systemImage: "plus") {
                Button("新建备忘录") { commitInput(); _ = store.createAndPresentMemo() }
                Button("新建分类…") { commitInput(); _ = store.requestCategorySheet() }
            }
        }
        .sheet(isPresented: Binding(get: { store.categorySheetPresented }, set: { if !$0 { store.dismissCategorySheet() } })) { categoryPicker }
        .confirmationDialog("删除「\(store.pendingDelete.map { MemoFormat.shownTitle(title: $0.title, body: $0.body) } ?? "")」？", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.cancelDelete() } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { commitInput(); store.confirmDelete() }
            Button("取消", role: .cancel) { store.cancelDelete() }
        }
        .onAppear { store.setActive(shell.selection == .memo) }
        .onDisappear { commitInput(); store.setActive(false) }
        .onChange(of: shell.selection) { _, page in
            if page != .memo { commitInput() }; store.setActive(page == .memo)
        }
        .task { await refreshDisplayClock(forDetail: false) }
    }
    private var listCard: some View {
        VStack(spacing: 0) {
            if !store.items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.categoryFilters, id: \.self) { id in
                            Button { commitInput(); _ = store.selectFilter(id) } label: {
                                HStack(spacing: 6) {
                                    Text(id == -1 ? "全部" : store.categoryName(id))
                                    Text("\(store.categoryCount(id))").monospacedDigit()
                                }
                                .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(store.filterCategoryID == id ? ThemeColors.accentForeground : ThemeColors.inkSoft)
                                .background(store.filterCategoryID == id ? ThemeColors.accentFill : ThemeColors.surfaceSunken, in: Capsule())
                            }
                            .buttonStyle(.plain).accessibilityLabel("\(id == -1 ? "全部" : store.categoryName(id))，\(store.categoryCount(id)) 条")
                            .accessibilityAddTraits(store.filterCategoryID == id ? .isSelected : [])
                        }
                    }.padding(16)
                }.scrollIndicators(.hidden)
            }
            ScrollViewReader { proxy in
                List {
                    if !store.errorMessage.isEmpty { errorRow }
                    ForEach(store.visibleItems) { memo in
                        Button { commitInput(); _ = store.presentMemo(memo.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(MemoFormat.shownTitle(title: memo.title, body: memo.body)).font(.headline).foregroundStyle(ThemeColors.ink)
                                    Spacer(minLength: 8)
                                    Text(MemoFormat.formatUpdatedAt(memo.updatedAt, now: store.displayNow))
                                        .font(.caption).foregroundStyle(ThemeColors.inkMuted)
                                }
                                Text(memo.body.components(separatedBy: "\n").first ?? "").font(.subheadline)
                                    .foregroundStyle(ThemeColors.inkSoft).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain).id(memo.id)
                        .listRowBackground(store.selectedID == memo.id ? ThemeColors.accentSoft : ThemeColors.surface)
                        .contextMenu { moveMenu(memo) }
                        .onDrag {
                            commitInput()
                            guard store.beginDrag(memo.id) else { return NSItemProvider() }
                            return NSItemProvider(object: "\(memo.id)" as NSString)
                        }
                        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                            guard let provider = providers.first, store.draggingID != nil else { return false }
                            let session = store, target = memo.id
                            // 只接受当前拖动编号，远端刷新取消拖动后不提交旧集合。
                            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                guard let text = object as? String, let source = Int(text) else { return }
                                Task { @MainActor in
                                    guard session.draggingID == source else { return }
                                    _ = session.drop(before: target)
                                }
                            }
                            return true
                        }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).contentMargins(.top, 0, for: .scrollContent)
                .onChange(of: store.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }.background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private var paper: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.selectedID != nil {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
        .task { await refreshDisplayClock(forDetail: true) }
    }
    private func refreshDisplayClock(forDetail: Bool) async {
        // 更新时间仅是自然日期显示口径；分钟刷新不改变业务归属或自动保存会话。
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { break }
            // 推入详情后列表任务会退场；宽窗两者同时存在时只让当前展示意图对应的一端刷新。
            if store.detailPresented == forDetail { store.refresh() }
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
        @Bindable var binding = store
        return NavigationStack {
            Form {
                if !store.unusedCategories.isEmpty {
                    ForEach(store.unusedCategories, id: \.id) { category in
                        Button(category.name) { if store.createAndPresentMemo(categoryID: category.id) { store.dismissCategorySheet() } }
                    }
                } else {
                    TextField("科目名称", text: $binding.newCategoryName)
                    Button("新建") {
                        // 表单取色沿用 Mac；科目合法性与写入仍由服务负责。
                        _ = store.createAndPresentCategory()
                    }
                }
                if !store.errorMessage.isEmpty { errorRow }
            }
            .navigationTitle("新建分类")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { store.dismissCategorySheet() } } }
        }
    }
    private func requestDelete(_ id: Int) { commitInput(); if store.selectMemo(id) { store.requestDelete() } }
    private func commitInput() {
        // 切换与后台保存只打断输入一次；UIKit 先结束组合，再由编辑器回调把上屏文字交给 Store。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
