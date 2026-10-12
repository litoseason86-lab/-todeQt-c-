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
    @Environment(FocusStore.self) private var focus
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.previewThemeID) private var previewThemeID
    // 宽窄各用一份选中状态：两个分支的标签集合不同，共用一份会把窄窗不存在的页面值交给窄窗标签栏。
    @State private var regularTab: RegularTab = .page(.dashboard)
    @State private var compactTab: ShellTab = .page(.dashboard)
    @State private var morePath: [MoreRoute] = []
    @State private var sidebar = SidebarWatcher()

    var body: some View {
        // 10-12 用户要求去掉跨页迷你计时条（底部附件位）：没用还挡内容；计时在专注页和侧栏摘要块里看。
        tabs
            .tint(ThemeColors.accentInk)
            .preferredColorScheme(preferredScheme)
            .background { ThemeAppearance(themeID: previewThemeID ?? store.selectedTheme ?? "").frame(width: 0, height: 0) }
            .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.wallpaperVisible) }
            .background { keyboardCommands }
            .disabled(store.snapshot.operationBlocksUI)
            .overlay {
                if store.snapshot.operationBlocksUI {
                    ZStack {
                        Group {
                            if reduceTransparency { ThemeColors.surface }
                            else { ThemeColors.modalScrim }
                        }.ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                            Text(store.snapshot.operationText.isEmpty ? "正在恢复数据" : store.snapshot.operationText)
                        }
                        .padding(28)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .accessibilityAddTraits(.isModal)
                    .accessibilityLabel("正在恢复数据，暂时不能操作")
                }
            }
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
                switch selected {
                case .page(let page): store.select(page)
                // 切回「更多」时栈顶仍是搜索页：重新记成在搜索。
                case .more: if morePath.last == .search && !store.searchShown { store.openSearch() }
                }
            }
            // 窄窗在「更多」里推入或退出搜索页。
            .onChange(of: morePath) { _, path in
                if path.last == .search { if !store.searchShown { store.openSearch() } }
                else if store.searchShown { store.closeSearch() }
            }
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
            Tab("更多", systemImage: "ellipsis", value: ShellTab.more) { moreView }
        }
    }

    // 宽窗口：侧栏可收起的标签栏。收起后顶部是五个常用页；其余页面只在侧栏；
    // 废纸篓、设置的入口在侧栏底栏，标签只为承载页面，侧栏与标签栏都不显示。
    // 今日任务、专注、本周在侧栏展开时由摘要块进入，列表里不重复；收起后要回到顶部标签栏。
    // iPadOS 27 只有「侧栏、标签栏一起隐藏」（defaultVisibility 对 .sidebar 也会把收起后的标签栏项去掉，
    // 10-11 真机截图只剩今日专注、仪表盘），所以按侧栏当前显隐切这三个标签的可见性。
    // 不能用 .hidden()：它把标签移出标签集合，而这三页常是选中页，10-11 18:39 真机启动即崩
    // （-[_UITabModel _setSelectedItem:] 断言）；defaultVisibility 隐藏的标签仍可被选中。
    private var regularTabs: some View {
        TabView(selection: $regularTab) {
            // iPadOS 的搜索标签放在侧栏最上方，就是定稿侧栏顶部的搜索框；侧栏收起时在顶部标签栏末尾。
            Tab(value: RegularTab.search, role: .search) {
                NavigationStack { SearchPage().shellChrome(store: store) }.background { SidebarProbe(watcher: sidebar) }
            }
            ForEach(PageID.regularTabs, id: \.self) { page in
                Tab(page.tabTitle(size: .regular), systemImage: page.symbol, value: RegularTab.page(page)) { regularPage(page) }
                    .defaultVisibility(sidebar.shown && PageID.summary.prefix(3).contains(page) ? .hidden : .visible, for: .sidebar)
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
        .tabViewSidebarHeader { summaryTiles.background { SidebarSwipeProbe() } }
        .tabViewSidebarBottomBar { fixedEntries }
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

    private func pageView(_ page: PageID) -> some View {
        NavigationStack {
            PageRegistry.view(for: page, core: core, shell: store).shellChrome(store: store)
        }
    }
    private func regularPage(_ page: PageID) -> some View {
        pageView(page).background { SidebarProbe(watcher: sidebar) }
    }
    // 宽窗当前页：在搜索时没有当前页，摘要块和底栏都不高亮。
    private var currentRegularPage: PageID? { store.searchShown ? nil : store.selection }
    private var moreView: some View {
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
            .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.wallpaperVisible) }
            .navigationTitle("更多")
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .search: SearchPage().shellChrome(store: store)
                case .page(let page):
                    PageRegistry.view(for: page, core: core, shell: store).shellChrome(store: store)
                        .onAppear { store.select(page) }
                }
            }
            .shellChrome(store: store)
        }
    }
    private var summaryTiles: some View {
        let tiles = store.summaryTiles(focusTimeText: focus.primaryTimeText)
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { tile(tiles[0]); tile(tiles[1]) }
            GridRow { tile(tiles[2]); tile(tiles[3]) }
        }.padding(.vertical, 8)
    }
    // 定稿侧栏底部：细分隔线下两行，图标焦糖、文字与侧栏列表同字号，行高 44；当前页浅焦糖底。
    // 底栏视图铺满侧栏宽度，系统列表行却有内缩：10-11 真机实测列表图标中心距侧栏左缘 46、文字起点 70，
    // 分隔线与摘要块同为两侧 32，这里按这几个数对齐（20 外边距 + 14 行内边距 + 图标中心 12）。
    private var fixedEntries: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(ThemeColors.border).frame(height: 1)
                .padding(.horizontal, 12).padding(.bottom, 8)
            ForEach(PageID.fixed, id: \.self) { page in
                let selected = currentRegularPage == page
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
    private var preferredScheme: ColorScheme? {
        if let previewThemeID { return SettingsAvailability.theme(previewThemeID).mode == "dark" ? .dark : .light }
        switch store.snapshot.appearance {
        case "light": return .light
        case "dark": return .dark
        case "theme": return SettingsAvailability.theme(store.snapshot.backgroundTheme).mode == "dark" ? .dark : .light
        default: return nil
        }
    }
    // 定稿侧栏摘要块：当前页那块焦糖实底、浅色字，其余浅焦糖底；数字 22 粗、单位 13。
    private func tile(_ tile: ShellSummaryTile) -> some View {
        let selected = currentRegularPage == tile.page
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
    private var keyboardCommands: some View {
        VStack {
            ForEach(Array(store.orderedPages.prefix(7).enumerated()), id: \.element) { index, page in
                Button(page.title) { store.select(page) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("记一笔") { store.presentCapture() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("新建任务") { store.onNewTask?() }.keyboardShortcut("n", modifiers: .command)
            Button("开始或暂停") { store.onStartOrPause?() }.keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
        .disabled(store.snapshot.operationBlocksUI)
    }
}

private struct ShellChrome: ViewModifier {
    @Bindable var store: ShellStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var captureHostID = UUID()
    func body(content: Content) -> some View {
        content
            // 统一放开主题页底，列表行仍由各页的语义纸面令牌决定；系统外观保留系统滚动底色。
            .scrollContentBackground(store.selectedTheme != nil ? .hidden : .visible)
            .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.wallpaperVisible) }
            .toolbar {
                // 专注页计时中无操作时整项移出，和底部计时按钮一起淡出（记一笔浮层开着时专注页不会隐藏）。
                if !store.focusChromeHidden {
                    ToolbarItem(placement: .topBarTrailing) {
                        // 定稿：宽窗「✎ 记一笔」带文字，窄窗只留图标。
                        Button { store.toggleCapture(for: captureHostID) } label: {
                            if sizeClass == .compact { Image(systemName: "pencil") }
                            else { ToolbarTextLabel(title: "记一笔", systemImage: "pencil") }
                        }.accessibilityLabel("记一笔")
                            .popover(isPresented: Binding(
                                get: { store.capturePresented(for: captureHostID) },
                                set: { if !$0 { store.captureDismissed(by: captureHostID) } }
                            )) { capturePopover }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // 由页面安全区让开标签栏，提示不写固定底边偏移量。
                if let toast = store.toast {
                    HStack {
                        Text(toast.message)
                        if let title = toast.actionTitle { Button(title) { store.triggerToastAction() } }
                        Button { store.retireToast() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("关闭提示")
                    }
                    .padding(12).background(.regularMaterial, in: Capsule()).padding(12)
                }
            }
            .overlay(alignment: .top) {
                if !store.errorMessage.isEmpty {
                    HStack {
                        Text(store.errorMessage)
                        Button("重试") { store.refresh() }
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
            .onAppear { _ = store.claimCaptureHost(captureHostID) }
            .onDisappear { store.releaseCaptureHost(captureHostID) }
    }
    private var capturePopover: some View {
        let form = VStack(alignment: .leading, spacing: 16) {
            Text("记一笔").font(.headline)
            TextField("写下问题或关键词", text: $store.captureTitle, axis: .vertical)
                .lineLimit(2...5).onSubmit { store.capture() }
            if !store.captureError.isEmpty { Text(store.captureError).foregroundStyle(ThemeColors.danger) }
            HStack {
                Button("取消") { store.dismissCapture() }
                Spacer()
                Button("记下") { store.capture() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        return Group {
            // 窄窗口退化成整页表单。带输入框的表单不用半高：10-12 目标表单在窄窗口半高表单里点输入框弹键盘时
            // 两次闪退（见 TodaySheets.swift）。
            if sizeClass == .compact {
                form.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .presentationDetents([.large])
            } else {
                form.frame(minWidth: 280, idealWidth: 340)
            }
        }.presentationCompactAdaptation(.sheet)
    }
}
private extension View {
    func shellChrome(store: ShellStore) -> some View { modifier(ShellChrome(store: store)) }
}

// 宽窗侧栏当前是否展开。SwiftUI 没有读侧栏显隐的接口，借 UIKit 侧栏代理（UITabBarController.Sidebar.Delegate，
// 侧栏显隐将要变化时回调）得知；SwiftUI 若已设过侧栏代理，其余回调原样转交给它。
@MainActor @Observable private final class SidebarWatcher: NSObject, UITabBarController.Sidebar.Delegate {
    private(set) var shown = true
    // 只在主线程读写；声明成 nonisolated(unsafe) 是因为 responds(to:) 等 NSObject 方法不在主线程隔离域内。
    @ObservationIgnored nonisolated(unsafe) private weak var forwarded: (any UITabBarController.Sidebar.Delegate)?

    func attach(_ controller: UITabBarController) {
        if controller.sidebar.delegate !== self {
            forwarded = controller.sidebar.delegate
            controller.sidebar.delegate = self
        }
        update(!controller.sidebar.isHidden)
    }
    func tabBarController(_ tabBarController: UITabBarController, sidebarVisibilityWillChange sidebar: UITabBarController.Sidebar,
                          animator: any UITabBarController.Sidebar.Animating) {
        forwarded?.tabBarController?(tabBarController, sidebarVisibilityWillChange: sidebar, animator: animator)
        update(!sidebar.isHidden)
    }
    // 回调可能落在 SwiftUI 更新或布局过程中，推迟到下一轮再改观察值，避免在视图更新里改状态。
    private func update(_ value: Bool) {
        guard value != shown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shown != value else { return }
            self.shown = value
        }
    }
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwarded?.responds(to: selector) ?? false)
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if !super.responds(to: selector), let forwarded, forwarded.responds(to: selector) { return forwarded }
        return super.forwardingTarget(for: selector)
    }
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
            let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(collapseSidebar))
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
            if newWindow == nil { host?.removeGestureRecognizer(swipe); host = nil }
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
        }
        @objc private func collapseSidebar() {
            var responder: UIResponder? = self
            while let current = responder, !(current is UITabBarController) { responder = current.next }
            guard let controller = responder as? UITabBarController, !controller.sidebar.isHidden else { return }
            if UIAccessibility.isReduceMotionEnabled { controller.sidebar.isHidden = true }
            else { UIView.animate(withDuration: 0.3) { controller.sidebar.isHidden = true } }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// 放进宽窗每个标签页内容里的零尺寸视图：上了窗口后沿响应链找到承载它的标签控制器，把侧栏代理接上。
// 宽窄切换会整份重建标签控制器，新控制器的页面一出现就重新接上。
private struct SidebarProbe: UIViewRepresentable {
    let watcher: SidebarWatcher
    func makeUIView(context: Context) -> ProbeView { ProbeView(watcher: watcher) }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        private let watcher: SidebarWatcher
        init(watcher: SidebarWatcher) {
            self.watcher = watcher
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }
        private func attach() {
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder, !(current is UITabBarController) { responder = current.next }
            if let controller = responder as? UITabBarController { watcher.attach(controller) }
        }
    }
}
