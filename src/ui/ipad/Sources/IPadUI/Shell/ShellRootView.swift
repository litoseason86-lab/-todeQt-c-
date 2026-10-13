import IPadCore
import SwiftUI
import UIKit

private enum ShellTab: Hashable { case page(PageID), more }
// 宽窗标签值：页面之外还有一个原生搜索标签（定稿侧栏顶部的搜索框）。
private enum RegularTab: Hashable { case page(PageID), search }
// 窄窗「更多」里推入的目标：页面或搜索。同一条路径一次换成 [.search]，
// 不和 navigationDestination(isPresented:) 混用（10-11 真机：先清路径再置推入标志，搜索页是空白）。
private enum MoreRoute: Hashable { case page(PageID), search }

struct ShellRootView: View {
    @Bindable var store: ShellStore
    @Environment(CoreBridges.self) private var core
    @Environment(\.horizontalSizeClass) private var sizeClass
    // 宽窄各用一份选中状态：两个分支的标签集合不同，共用一份会把窄窗不存在的页面值交给窄窗标签栏。
    @State private var regularTab: RegularTab = .page(.dashboard)
    @State private var compactTab: ShellTab = .page(.dashboard)
    @State private var morePath: [MoreRoute] = []

    // 10-12 真机测速：本视图的 body 每重算一次，十几个标签页和整条侧栏都要重新交给系统比对；原来每切一次页
    // 要重算 3 次（读了选中页、标签选中值和整份外壳快照），一次切页主线程忙约 170 毫秒。
    // 所以这里只搭结构，不读选中页、计时、计数、提示条这些常变的状态：读它们的部分拆成下面的小视图和修饰器，
    // 状态变了只重算那一小块。标签只用 $ 绑定交给 TabView，绑定本身不算读。
    var body: some View {
        // 10-12 用户要求去掉跨页迷你计时条（底部附件位）：没用还挡内容；计时在专注页和侧栏摘要块里看。
        tabs
            .tint(ThemeColors.accentInk)
            .modifier(ShellAppearanceModifier(store: store))
            .background { ShellKeyboardCommands(store: store, compactTab: $compactTab, morePath: $morePath) }
            .modifier(OperationBlockModifier(store: store))
            .modifier(SelectionSyncModifier(store: store, regularTab: $regularTab, compactTab: $compactTab, morePath: $morePath))
    }

    // 055-R4：宽窄是两个独立的 TabView，切换尺寸时整份重建，不在同一个标签控制器里改标签。
    // iPadOS 27.0.1 实测（10-10、10-11 崩溃日志）：同一个 sidebarAdaptable 标签栏在窄窗口里
    // 把仅侧栏、侧栏隐藏的标签显示进底栏，点下去 -[UITabBarController _viewControllerForTabBarItem:] 断言崩溃。
    @ViewBuilder private var tabs: some View {
        if sizeClass == .compact { compactTabs } else { regularTabs }
    }

    // 窄窗口：普通标签栏，只有定稿的五个固定标签；其余页面都从「更多」推入。
    private var compactTabs: some View {
        TabView(selection: $compactTab) {
            ForEach(PageID.primary, id: \.self) { page in
                Tab(page.tabTitle(size: .compact), systemImage: page.symbol, value: ShellTab.page(page)) { pageView(page) }
            }
            Tab("更多", systemImage: "ellipsis", value: ShellTab.more) { MoreRootView(store: store, morePath: $morePath) }
        }
    }

    // 宽窗口：侧栏可收起的标签栏。收起后顶部只有仪表盘、专注、今日专注三页（10-12 用户定），侧栏展开时它们也常驻列表；
    // 今日任务、本周只从侧栏摘要块进入，侧栏列表和收起后的顶部都不放；其余页面只在侧栏；
    // 废纸篓、设置的入口在侧栏底栏，标签只为承载页面，侧栏与标签栏都不显示。
    // 标签的可见性一律固定，不随侧栏显隐切换：10-12 按侧栏显隐切换时，第一次收起顶部标签停在侧栏大字号、被裁掉，
    // 改成过渡结束后再切又让展开时列表闪出多余的行（真机）。iPadOS 27 对 .sidebar 的 defaultVisibility 会把收起后
    // 标签栏里的项一起去掉，所以要放进顶部的页必须同时留在列表里。
    // 不能用 .hidden()：它把标签移出标签集合，而今日任务、本周常是选中页，10-11 18:39 真机启动即崩
    // （-[_UITabModel _setSelectedItem:] 断言）；defaultVisibility 隐藏的标签仍可被选中。
    private var regularTabs: some View {
        TabView(selection: $regularTab) {
            // iPadOS 的搜索标签放在侧栏最上方，就是定稿侧栏顶部的搜索框；侧栏收起时在顶部标签栏末尾。
            Tab(value: RegularTab.search, role: .search) {
                NavigationStack { SearchPage().shellChrome(store: store, anchor: .search) }
            }
            ForEach(PageID.collapsedBarTabs, id: \.self) { page in
                Tab(page.tabTitle(size: .regular), systemImage: page.symbol, value: RegularTab.page(page)) { regularPage(page) }
            }
            ForEach(PageID.tileOnlyTabs, id: \.self) { page in
                Tab(page.tabTitle(size: .regular), systemImage: page.symbol, value: RegularTab.page(page)) { regularPage(page) }
                    .tabPlacement(.sidebarOnly)
                    .defaultVisibility(.hidden, for: .sidebar)
            }
            ForEach(store.sidebarPages.filter { !PageID.regularTabs.contains($0) }, id: \.self) { page in
                Tab(page.title, systemImage: page.symbol, value: RegularTab.page(page)) { regularPage(page) }
                    .badge(store.sidebarBadge(for: page).map { Text(String($0)) })
                    .tabPlacement(.sidebarOnly)
            }
            ForEach(PageID.fixed, id: \.self) { page in
                Tab(page.title, systemImage: page.symbol, value: RegularTab.page(page)) { regularPage(page) }
                    .tabPlacement(.sidebarOnly)
                    .defaultVisibility(.hidden, for: .sidebar)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.sidebar)
        .tabViewSidebarHeader { SidebarSummaryTiles(store: store).background { SidebarSwipeProbe() } }
        .tabViewSidebarBottomBar { SidebarFixedEntries(store: store) }
    }

    private func pageView(_ page: PageID) -> some View {
        NavigationStack {
            PageRegistry.view(for: page, core: core, shell: store).shellChrome(store: store, anchor: .page(page))
        }
    }
    private func regularPage(_ page: PageID) -> some View {
        pageView(page)
    }
}

// ---- 以下各块从外壳根视图拆出（10-12 测速，见 ShellRootView.body 的说明）：各自只读自己用到的状态。

// 配色方案、主题特征与整窗壁纸：只读外观那一项，计时与计数变化不会带动。
private struct ShellAppearanceModifier: ViewModifier {
    let store: ShellStore
    @Environment(\.previewThemeID) private var previewThemeID
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferredScheme)
            .background { ThemeAppearance(themeID: previewThemeID ?? store.selectedTheme ?? "").frame(width: 0, height: 0) }
            .background { WallpaperBackground(theme: store.appearanceState.backgroundTheme, enabled: store.wallpaperVisible) }
    }
    private var preferredScheme: ColorScheme? {
        if let previewThemeID { return SettingsAvailability.theme(previewThemeID).mode == "dark" ? .dark : .light }
        switch store.appearanceState.appearance {
        case "light": return .light
        case "dark": return .dark
        case "theme": return SettingsAvailability.theme(store.appearanceState.backgroundTheme).mode == "dark" ? .dark : .light
        default: return nil
        }
    }
}

// 恢复备份等阻断操作期间整窗不可操作，盖一层说明。
private struct OperationBlockModifier: ViewModifier {
    let store: ShellStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .disabled(store.operationBlocksUI)
            .overlay {
                if store.operationBlocksUI {
                    ZStack {
                        Group {
                            if reduceTransparency { ThemeColors.surface }
                            else { ThemeColors.modalScrim }
                        }.ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                            Text(store.operationText.isEmpty ? "正在恢复数据" : store.operationText)
                        }
                        .padding(28)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .accessibilityAddTraits(.isModal)
                    .accessibilityLabel("正在恢复数据，暂时不能操作")
                }
            }
    }
}

// 标签选中值与 Store 的选中页互相对齐。放在修饰器里：选中页、标签值一变只重算这里，不重算外壳根视图。
private struct SelectionSyncModifier: ViewModifier {
    let store: ShellStore
    @Binding var regularTab: RegularTab
    @Binding var compactTab: ShellTab
    @Binding var morePath: [MoreRoute]
    @Environment(\.horizontalSizeClass) private var sizeClass
    func body(content: Content) -> some View {
        content
            .onAppear { syncSelection() }
            .onChange(of: store.selection) { _, _ in scheduleSelectionSync() }
            .onChange(of: store.navigationRequest) { _, _ in scheduleSelectionSync() }
            .onChange(of: sizeClass) { _, _ in syncSelection() }
            // 用户在标签栏或侧栏里直接点：页面标签走 select，宽窗的原生搜索标签记成打开搜索。
            .onChange(of: regularTab) { _, selected in
                switch selected {
                case .page(let page): store.select(page)
                case .search: if !store.searchShown { store.openSearch() }
                }
            }
            .onChange(of: compactTab) { _, selected in
                store.dismissCapture()
                switch selected {
                case .page(let page): store.select(page)
                // 切回「更多」时栈顶仍是搜索页：重新记成在搜索。
                case .more: if morePath.last == .search && !store.searchShown { store.openSearch() }
                }
            }
            // 「更多」根列表和推入页各有工具栏；进出页面先关闭记一笔，避免下层页面留着浮层。
            .onChange(of: morePath) { _, path in
                store.dismissCapture()
                if path.last == .search { if !store.searchShown { store.openSearch() } }
                else if store.searchShown { store.closeSearch() }
            }
    }

    // 窄窗口非主标签页由「更多」的 NavigationStack 承载；旋转回宽窗口时恢复同一页面。
    // 一律按 Store 的当前状态重建（不按触发它的事件），排队的同步晚执行也只会落到最新状态。
    // 在搜索时宽窄都停在搜索：宽窗是搜索标签，窄窗是「更多」里的搜索页。
    private func syncSelection() {
        if store.searchShown {
            if regularTab != .search { regularTab = .search }
            if compactTab != .more { compactTab = .more }
            if morePath != [.search] { morePath = [.search] }
            return
        }
        if regularTab != .page(store.selection) { regularTab = .page(store.selection) }
        switch ShellStore.navigationTarget(for: store.selection, size: .compact) {
        case .page(let page):
            if compactTab != .page(page) { compactTab = .page(page) }
            if !morePath.isEmpty { morePath = [] }
        case .more(let path):
            if compactTab != .more { compactTab = .more }
            let routes = path.map(MoreRoute.page)
            if morePath != routes { morePath = routes }
        }
    }

    private func scheduleSelectionSync() {
        // 标签点击处理中不改选中值，推迟到下一轮，让 TabView 先完成自身的 selection 更新。
        Task { @MainActor in
            await Task.yield()
            syncSelection()
        }
    }
}

// 硬件键盘快捷键：零尺寸、不参与无障碍。
private struct ShellKeyboardCommands: View {
    let store: ShellStore
    @Binding var compactTab: ShellTab
    @Binding var morePath: [MoreRoute]
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        VStack {
            ForEach(Array(store.orderedPages.prefix(7).enumerated()), id: \.element) { index, page in
                Button(page.title) { store.select(page) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("记一笔") {
                let anchor: CaptureAnchor = store.searchShown ? .search
                    : (sizeClass == .compact && compactTab == .more && morePath.isEmpty ? .moreRoot : .page(store.selection))
                store.presentCapture(from: anchor)
            }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("新建任务") { store.onNewTask?() }.keyboardShortcut("n", modifiers: .command)
            Button("开始或暂停") { store.onStartOrPause?() }.keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
        .disabled(store.operationBlocksUI)
    }
}

// 定稿侧栏摘要块：当前页那块焦糖实底、浅色字，其余浅焦糖底；数字 22 粗、单位 13。
// 计时在走时专注那块每秒变，只有这里跟着重算。
private struct SidebarSummaryTiles: View {
    let store: ShellStore
    @Environment(FocusStore.self) private var focus
    var body: some View {
        let tiles = store.summaryTiles(focusTimeText: focus.primaryTimeText)
        // 宽窗当前页：在搜索时没有当前页，摘要块和底栏都不高亮。
        let current: PageID? = store.searchShown ? nil : store.selection
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { tile(tiles[0], current: current); tile(tiles[1], current: current) }
            GridRow { tile(tiles[2], current: current); tile(tiles[3], current: current) }
        }.padding(.vertical, 8)
    }
    private func tile(_ tile: ShellSummaryTile, current: PageID?) -> some View {
        let selected = current == tile.page
        return Button { store.select(tile.page) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: tile.page.symbol).font(.system(size: 17))
                        .foregroundStyle(selected ? ThemeColors.surface : ThemeColors.accentInk)
                    Spacer(minLength: 4)
                    MixedNumberText(parts: MixedNumberText.split(tile.value), numberSize: 22, unitSize: 13,
                                    color: selected ? ThemeColors.surface : ThemeColors.inkStrong)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                Text(tile.title).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(selected ? ThemeColors.surface : ThemeColors.ink)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ThemeColors.accentInk : ThemeColors.accentFill.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.title)，\(tile.value)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// 定稿侧栏底部：细分隔线下两行，图标焦糖、文字与侧栏列表同字号，行高 44；当前页浅焦糖底。
// 底栏视图铺满侧栏宽度，系统列表行却有内缩：10-11 真机实测列表图标中心距侧栏左缘 46、文字起点 70，
// 分隔线与摘要块同为两侧 32，这里按这几个数对齐（20 外边距 + 14 行内边距 + 图标中心 12）。
private struct SidebarFixedEntries: View {
    let store: ShellStore
    var body: some View {
        let current: PageID? = store.searchShown ? nil : store.selection
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(ThemeColors.border).frame(height: 1)
                .padding(.horizontal, 12).padding(.bottom, 8)
            ForEach(PageID.fixed, id: \.self) { page in
                let selected = current == page
                Button { store.select(page) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 17)).imageScale(.large)
                            .foregroundStyle(ThemeColors.accentInk).frame(width: 24)
                        Text(page.title).font(.body).foregroundStyle(ThemeColors.inkStrong)
                        Spacer()
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(selected ? ThemeColors.accentFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 4)
    }
}

// 窄窗「更多」：根列表加推入的页面与搜索。
private struct MoreRootView: View {
    let store: ShellStore
    @Binding var morePath: [MoreRoute]
    @Environment(CoreBridges.self) private var core
    var body: some View {
        NavigationStack(path: $morePath) {
            List {
                // 窄窗没有侧栏，搜索放在「更多」第一行。
                NavigationLink(value: MoreRoute.search) {
                    Label { Text("搜索").foregroundStyle(ThemeColors.inkStrong) }
                    icon: { Image(systemName: "magnifyingglass").foregroundStyle(ThemeColors.accentInk) }
                }
                .listRowBackground(store.selectedTheme != nil ? ThemeColors.surface : nil)
                ForEach(store.morePages, id: \.self) { page in
                    NavigationLink(value: MoreRoute.page(page)) {
                        Label { Text(page.title).foregroundStyle(ThemeColors.inkStrong) }
                        icon: { Image(systemName: page.symbol).foregroundStyle(ThemeColors.accentInk) }
                    }
                    .listRowBackground(store.selectedTheme != nil ? ThemeColors.surface : nil)
                }
            }
            .scrollContentBackground(store.selectedTheme != nil ? .hidden : .visible)
            .background { WallpaperBackground(theme: store.appearanceState.backgroundTheme, enabled: store.wallpaperVisible) }
            .navigationTitle("更多")
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .search: SearchPage().shellChrome(store: store, anchor: .search)
                case .page(let page):
                    PageRegistry.view(for: page, core: core, shell: store).shellChrome(store: store, anchor: .page(page))
                        .onAppear { store.select(page) }
                }
            }
            .shellChrome(store: store, anchor: .moreRoot)
        }
    }
}

// 每个页面的外壳：主题页底、壁纸、记一笔按钮、提示条、出错条。十几个页面各套一份，
// 所以这里只读外观（很少变）；记一笔、提示条、出错条各拆成小视图，状态变了只重算它们，不重排各页
// （10-12 测速：原来打开记一笔或提示条出现，14 个页面的外壳整体重算）。
private struct ShellChrome: ViewModifier {
    let store: ShellStore
    let anchor: CaptureAnchor
    func body(content: Content) -> some View {
        content
            // 统一放开主题页底，列表行仍由各页的语义纸面令牌决定；系统外观保留系统滚动底色。
            .scrollContentBackground(store.selectedTheme != nil ? .hidden : .visible)
            .background { WallpaperBackground(theme: store.appearanceState.backgroundTheme, enabled: store.wallpaperVisible) }
            .toolbar {
                // 专注页计时中无操作时整项移出，和底部计时按钮一起淡出（记一笔浮层开着时专注页不会隐藏）。
                // 只有专注页读这个开关，其它页的工具栏不随它重算。
                if !(anchor == .page(.focus) && store.focusChromeHidden) {
                    ToolbarItem(placement: .topBarTrailing) { CaptureToolbarButton(store: store, anchor: anchor) }
                }
            }
            .safeAreaInset(edge: .bottom) { ShellToastBar(store: store, anchor: anchor) }
            .overlay(alignment: .top) { ShellErrorBar(store: store) }
    }
}

// 定稿：宽窗「✎ 记一笔」带文字，窄窗只留图标。浮层只在打开它的那一处显示（CaptureAnchor）。
private struct CaptureToolbarButton: View {
    let store: ShellStore
    let anchor: CaptureAnchor
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Button { store.toggleCapture(from: anchor) } label: {
            if sizeClass == .compact { Image(systemName: "pencil") }
            else { ToolbarTextLabel(title: "记一笔", systemImage: "pencil") }
        }.accessibilityLabel("记一笔")
            .popover(isPresented: Binding(
                get: { store.isCapturePresented(at: anchor) },
                set: { if !$0 { store.captureDismissed(at: anchor) } }
            )) { CapturePopover(store: store, windowCompact: sizeClass == .compact) }
    }
}

// 10-13 用户反馈宽窗浮层缩得很小、记不了东西，按记录卡重排：输入区至少四行、带浅底，按钮用定稿样式。
// 仍只收一个标题（业务规则「零成本捕获」，上限由服务校验，超长时显示服务原因）。
private struct CapturePopover: View {
    @Bindable var store: ShellStore
    // 宽窄按打开它的窗口判断：浮层内容自己的水平尺寸类别是 compact，原来按它判断，宽窗也走了整页分支，
    // 只剩一个没有理想尺寸的弹性框，浮层按最小尺寸缩到约 115 点宽（10-13 iPadOS 27.0.1 真机截图：标题被裁、提示截断）。
    let windowCompact: Bool
    @FocusState private var focused: Bool
    var body: some View {
        let form = VStack(alignment: .leading, spacing: 14) {
            Text("记一笔").font(.system(size: 17, weight: .semibold)).foregroundStyle(ThemeColors.inkStrong)
            TextField("写下问题或关键词", text: $store.captureTitle, axis: .vertical)
                .font(.system(size: 17)).foregroundStyle(ThemeColors.inputInk)
                .lineLimit(4...8)
                .focused($focused)
                .onSubmit { store.capture() }
                .padding(12)
                .background(ThemeColors.surfaceSunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !store.captureError.isEmpty {
                Text(store.captureError).font(.callout).foregroundStyle(ThemeColors.danger)
            }
            HStack {
                Button("取消") { store.dismissCapture() }.buttonStyle(AccentTextButtonStyle(size: 16))
                Spacer()
                Button("记下") { store.capture() }.buttonStyle(ProminentPillStyle())
            }
        }
        .padding(20)
        .tint(ThemeColors.accentInk)
        // 打开就能直接写，不用再点一下输入框。
        .onAppear { focused = true }
        Group {
            // 窄窗口退化成整页表单。带输入框的表单不用半高：10-12 目标表单在窄窗口半高表单里点输入框弹键盘时
            // 两次闪退（见 TodaySheets.swift）。
            if windowCompact {
                form.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .presentationDetents([.large])
            } else {
                // 宽窗浮层定宽，高度随内容（输入框至少四行），不随打字忽宽忽窄。
                form.frame(width: 420)
            }
        }.presentationCompactAdaptation(.sheet)
    }
}

// 提示条只画在当前显示的那一页（「更多」根列表也画，它在窄窗里可能就是眼前这一页）：
// 别的页面不读提示条内容、不让出底部安全区，提示条出现或收起时它们不必重新排版。
private struct ShellToastBar: View {
    let store: ShellStore
    let anchor: CaptureAnchor
    private var isCurrent: Bool {
        switch anchor {
        case .search: store.searchShown
        case .page(let page): !store.searchShown && store.selection == page
        case .moreRoot: true
        }
    }
    var body: some View {
        // 由页面安全区让开标签栏，提示不写固定底边偏移量。
        if isCurrent, let toast = store.toast {
            HStack {
                Text(toast.message)
                if let title = toast.actionTitle { Button(title) { store.triggerToastAction() } }
                Button { store.retireToast() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭提示")
            }
            .padding(12).background(.regularMaterial, in: Capsule()).padding(12)
        }
    }
}

private struct ShellErrorBar: View {
    let store: ShellStore
    var body: some View {
        if !store.errorMessage.isEmpty {
            HStack {
                Text(store.errorMessage)
                Button("重试") { store.refresh() }
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
        }
    }
}
private extension View {
    func shellChrome(store: ShellStore, anchor: CaptureAnchor) -> some View { modifier(ShellChrome(store: store, anchor: anchor)) }
}

// 宽窗侧栏左滑收起（10-12 用户要求）：不必每次点左上角的收起按钮，在侧栏上向左一扫就收到顶部标签栏。
// SwiftUI 没有控制侧栏显隐的接口，这个零尺寸视图放在侧栏头部（摘要块）里：上了窗口后往上找「仍比窗口窄得多」的
// 最外层祖先视图，也就是整条侧栏（摘要块、页面列表、底栏都在里面），把向左横扫手势挂上去；
// 识别后经响应链找到承载它的标签控制器，把 sidebar.isHidden 置真。侧栏收起时本视图离开窗口，手势随之摘下，
// 再展开时重新挂上。只认横扫，与列表的竖向滚动、行点按同时识别，不抢它们的手势。
private struct SidebarSwipeProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView, UIGestureRecognizerDelegate {
        private weak var host: UIView?
        private lazy var swipe: UISwipeGestureRecognizer = {
            let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe))
            recognizer.direction = .left
            recognizer.delegate = self
            return recognizer
        }()
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }
        // 刚上窗口时祖先视图可能还没排版、宽度为 0，排版后再找一次；找到的还是同一个就不动。
        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }
        // 手势识别器不持有目标；离开窗口先摘下，免得侧栏容器留着一个指向已释放视图的手势。
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                host?.removeGestureRecognizer(swipe); host = nil
                if UITour.isRequested { UITour.sidebarTriggers.removeValue(forKey: ObjectIdentifier(self)) }
            }
        }
        private func attach() {
            guard let window else { return }
            // 侧栏宽约 280–320，标签页内容区和整窗都远宽于它；取窗口宽的六成作分界。
            let limit = window.bounds.width * 0.6
            var target: UIView?
            var current = superview
            while let view = current, view.bounds.width > 0, view.bounds.width < limit {
                target = view
                current = view.superview
            }
            guard let target, target !== host else { return }
            host?.removeGestureRecognizer(swipe)
            target.addGestureRecognizer(swipe)
            host = target
            if UITour.isRequested {
                UITour.sidebarTriggers[ObjectIdentifier(self)] = { [weak self] window in
                    guard let self, self.window === window else { return false }
                    return self.requestCollapse()
                }
            }
        }
        @objc private func handleSwipe() { _ = requestCollapse() }
        // 巡检也从这里进入，复用真实探针、响应链和收起路径；不伪造触摸或调用系统私有按钮动作。
        private func requestCollapse() -> Bool {
            var responder: UIResponder? = self
            while let current = responder, !(current is UITabBarController) { responder = current.next }
            guard let controller = responder as? UITabBarController, let window,
                  !controller.sidebar.isHidden else { return false }
            // 先退出手势回调，避免在识别器分发过程中启动侧栏过渡；这不等同于模拟手指抬起。
            DispatchQueue.main.async { [weak controller, weak window] in
                guard let controller, let window, controller.viewIfLoaded?.window === window,
                      !controller.sidebar.isHidden else { return }
                // 系统自己做侧栏→标签栏的过渡（不套动画块也有，10-12 真机巡检），也自己处理减少动态效果。
                controller.sidebar.isHidden = true
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
