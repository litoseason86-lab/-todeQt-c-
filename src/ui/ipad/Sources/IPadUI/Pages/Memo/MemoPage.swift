import IPadCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// 拖动载荷随系统拖拽会话销毁时，若未落入 onDrop，延迟一个短周期自动清理 draggingID，防止列表刷新永久被锁。
private final class MemoDragItemProvider: NSItemProvider {
    var onSessionEnded: (@Sendable () -> Void)?
    deinit { onSessionEnded?() }
}

@MainActor struct MemoPage: View {
    @Environment(MemoStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "备忘录")
                if wide {
                    HStack(alignment: .top, spacing: 20) {
                        listCard(wide: true).frame(width: min(380, geometry.size.width * 0.38))
                        paper.frame(maxWidth: .infinity)
                    }
                } else { listCard(wide: false) }
            }
            .padding(.top, 4).padding(.bottom, wide ? 24 : 0)
            .safeAreaPadding(.horizontal, wide ? Design.pageMargin(geometry: geometry, compact: false, maxWidth: 1100) : 16)
            .navigationDestination(isPresented: Binding(get: { !wide && store.detailPresented }, set: { value in
                if !value { commitInput(); _ = store.dismissMemo() }
            })) {
                paper.padding(16).modifier(PageBackground()).navigationTitle("备忘录").navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("备忘录", systemImage: "chevron.left") { commitInput(); _ = store.dismissMemo() }
                        }
                    }
                    .onAppear { store.setActive(shell.selection == .memo && !shell.searchShown) }.onDisappear {
                        commitInput(); if shell.selection != .memo || shell.searchShown { store.setActive(false) }
                    }
            }
            .onChange(of: wide) { _, isWide in
                commitInput()
                // 切到宽窗双栏后纸面已在右侧同屏展示，清掉窄窗推入标记，避免后续离页误判为推入详情。
                if isWide { store.clearDetailPresentation() }
            }
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建备忘录") { commitInput(); _ = store.createAndPresentMemo() }
                    Button("新建分类…") { commitInput(); _ = store.requestCategorySheet() }
                } label: { ToolbarTextLabel(title: "新建", systemImage: "square.and.pencil") }
            }
        }
        .sheet(isPresented: Binding(get: { store.categorySheetPresented }, set: { if !$0 { store.dismissCategorySheet() } })) { categoryPicker }
        .confirmationDialog("删除「\(store.pendingDelete.map { MemoFormat.shownTitle(title: $0.title, body: $0.body) } ?? "")」？", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.cancelDelete() } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { commitInput(); store.confirmDelete() }
            Button("取消", role: .cancel) { store.cancelDelete() }
        }
        .onAppear { store.setActive(shell.selection == .memo && !shell.searchShown) }
        .onDisappear {
            commitInput()
            // 列表推入纸面不代表离开备忘录；打开全局搜索或切换到其它页时释放活跃状态并同步冲刷草稿。
            if !store.detailPresented || shell.selection != .memo || shell.searchShown { store.setActive(false) }
        }
        .onShellSelectionChange(shell) { page in
            if page != .memo { commitInput() }; store.setActive(page == .memo && !shell.searchShown)
        }
        .onChange(of: shell.searchShown) { _, shown in
            if shown { commitInput(); store.setActive(false) }
            else if shell.selection == .memo { store.setActive(true) }
        }
        .task { await refreshDisplayClock(forDetail: false) }
    }
    private func listCard(wide: Bool) -> some View {
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
                                // 定稿：选中的分类焦糖实底浅字，其余浅焦糖底。
                                .scaledSystemFont(size: 14, weight: .semibold).padding(.horizontal, 12).frame(minHeight: 34)
                                .foregroundStyle(store.filterCategoryID == id ? ThemeColors.surface : ThemeColors.accentFillInk)
                                .background(store.filterCategoryID == id ? ThemeColors.accentInk : ThemeColors.accentFill, in: Capsule())
                            }
                            .buttonStyle(.plain).accessibilityLabel("\(id == -1 ? "全部" : store.categoryName(id))，\(store.categoryCount(id)) 条")
                            .accessibilityAddTraits(store.filterCategoryID == id ? .isSelected : [])
                        }
                    }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
                }.scrollIndicators(.hidden)
            }
            ScrollViewReader { proxy in
                List {
                    if !store.errorMessage.isEmpty { errorRow }
                    ForEach(store.visibleItems) { memo in
                        memoRow(memo, wide: wide)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).contentMargins(.top, 0, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 1)
                .onChange(of: store.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }.background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }
    private func memoRow(_ memo: MemoValue, wide: Bool) -> some View {
        Button { commitInput(); _ = wide ? store.selectMemo(memo.id) : store.presentMemo(memo.id) } label: {
            memoRowContent(memo)
        }
        .buttonStyle(.plain).id(memo.id)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
        .contextMenu { moveMenu(memo) }
        .conditionalDrag(enabled: store.canReorder) { memoDragProvider(for: memo) }
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
            handleMemoDrop(providers, before: memo.id)
        }
    }
    private func handleMemoDrop(_ providers: [NSItemProvider], before target: Int) -> Bool {
        guard let provider = providers.first, store.draggingID != nil else { return false }
        let session = store
        // 只接受当前拖动编号，远端刷新取消拖动后不提交旧集合。
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let source = Int(text) else { return }
            Task { @MainActor in
                guard let dragging = session.draggingID, dragging == source else { return }
                _ = session.drop(before: target)
            }
        }
        return true
    }
    private func previewText(for memo: MemoValue) -> String {
        // 优先消费服务已截好的 preview；为空时只扫描到首个换行符，避免每行整篇切分万字正文。
        if !memo.preview.isEmpty { return memo.preview }
        return String(memo.body.prefix(while: { $0 != "\n" }))
    }
    // 拆出单行展示与拖拽载荷构造，避免多层泛型 List/ForEach 闭包内联嵌套触发 Swift 类型推断超时。
    private func memoRowContent(_ memo: MemoValue) -> some View {
        // 定稿行：标题 15 粗、右侧更新时间 12，下面首行预览 13；选中行圆角浅焦糖底。
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(MemoFormat.shownTitle(title: memo.title, body: memo.body))
                    .scaledSystemFont(size: 15, weight: .semibold).foregroundStyle(ThemeColors.inkStrong).lineLimit(1)
                Spacer(minLength: 8)
                Text(MemoFormat.formatUpdatedAt(memo.updatedAt, now: store.displayNow))
                    .scaledSystemFont(size: 12).foregroundStyle(ThemeColors.inkSoft)
            }
            Text(previewText(for: memo))
                .scaledSystemFont(size: 13)
                .foregroundStyle(ThemeColors.inkSoft).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(store.selectedID == memo.id ? ThemeColors.accentFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
    private func memoDragProvider(for memo: MemoValue) -> NSItemProvider {
        commitInput()
        let id = memo.id
        guard store.beginDrag(id) else { return NSItemProvider() }
        let provider = MemoDragItemProvider(object: "\(id)" as NSString)
        provider.onSessionEnded = { [weak store] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if store?.draggingID == id { store?.cancelDrag() }
            }
        }
        return provider
    }
    private var paper: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.selectedID != nil {
                // 定稿纸面：左上分类名（13 粗焦糖），右上「X 更新」，下面大标题与正文。
                HStack {
                    Text(store.categoryName(store.editorCategoryID)).scaledSystemFont(size: 13, weight: .semibold).foregroundStyle(ThemeColors.accentInk)
                    Spacer()
                    let updated = MemoFormat.formatUpdatedAt(store.updatedAt, now: store.displayNow)
                    if !updated.isEmpty { Text(updated + " 更新").scaledSystemFont(size: 13).foregroundStyle(ThemeColors.inkSoft) }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: 28, leading: 36, bottom: 28, trailing: 36))
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .task { await refreshDisplayClock(forDetail: true) }
    }
    private func refreshDisplayClock(forDetail: Bool) async {
        // 更新时间仅是自然日期显示口径；分钟刷新只推进 displayNow，不查库也不打断正在进行的拖拽。
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { break }
            // 推入详情后列表任务会退场；宽窗两者同时存在时只让当前展示意图对应的一端刷新。
            if store.detailPresented == forDetail { store.tickDisplayClock() }
        }
    }
    private var errorRow: some View {
        HStack {
            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
            Spacer()
            if store.errorFromRead { Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle()) }
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
                    Section("选择已有科目") {
                        ForEach(store.unusedCategories, id: \.id) { category in
                            Button(category.name) { if store.createAndPresentMemo(categoryID: category.id) { store.dismissCategorySheet() } }
                        }
                    }
                }
                Section("新建科目") {
                    TextField("科目名称", text: $binding.newCategoryName)
                    Button("新建") {
                        // 表单取色沿用 Mac；科目合法性与写入仍由服务负责。
                        _ = store.createAndPresentCategory()
                    }
                }
                if !store.errorMessage.isEmpty { errorRow }
            }
            .navigationTitle("新建分类").sheetChrome()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { store.dismissCategorySheet() } } }
        }
    }
    private func requestDelete(_ id: Int) { commitInput(); if store.selectMemo(id) { store.requestDelete() } }
    private func commitInput() {
        // 切换与后台保存只打断输入一次；UIKit 先结束组合，再由编辑器回调把上屏文字交给 Store。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
