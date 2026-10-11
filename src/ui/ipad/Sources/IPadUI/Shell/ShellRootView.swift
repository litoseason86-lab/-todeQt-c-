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
        tabs
            .modifier(TimerAccessoryModifier(store: store, accessory: miniTimer))
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
            .onChange(of: sizeClass) { _, _ in syncSelection() }
            .onChange(of: regularTab) { _, selected in
                if case let .page(page) = selected { store.select(page) }
            }
            .onChange(of: store.searchRequest) { _, _ in
                if sizeClass == .compact { compactTab = .more; morePath = [.search] } else { regularTab = .search }
            }
            .onChange(of: compactTab) { _, selected in
                if case let .page(page) = selected { store.select(page) }
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
        .tabViewSidebarHeader { summaryTiles }
        .tabViewSidebarBottomBar { fixedEntries }
    }

    // 窄窗口非主标签页由「更多」的 NavigationStack 承载；旋转回宽窗口时恢复同一页面。
    private func syncSelection() {
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
    // 宽窗当前页：搜索标签选中时没有当前页，摘要块和底栏都不高亮。
    private var currentRegularPage: PageID? {
        if case let .page(page) = regularTab { page } else { nil }
    }
    // 摘要块与底栏点选直接改宽窗标签：从搜索回到原来那页时 store.selection 没变，只调 select 不会切走。
    private func selectRegular(_ page: PageID) {
        regularTab = .page(page)
        store.select(page)
    }
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
                Button { selectRegular(page) } label: {
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
    private var clock: String {
        ShellDisplay.clock(store.snapshot.mode == 1 ? store.snapshot.remainingSeconds : store.snapshot.elapsedSeconds)
    }
    // 定稿侧栏摘要块：当前页那块焦糖实底、浅色字，其余浅焦糖底；数字 22 粗、单位 13。
    private func tile(_ tile: ShellSummaryTile) -> some View {
        let selected = currentRegularPage == tile.page
        return Button { selectRegular(tile.page) } label: {
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
    private var miniTimer: some View {
        HStack(spacing: 12) {
            Button { store.select(.focus) } label: {
                HStack {
                    Text(clock).monospacedDigit()
                    Text(focus.miniTimerLabel).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { store.toggleTimer() } label: {
                Image(systemName: store.snapshot.running ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(store.snapshot.running ? "暂停计时" : "继续计时")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
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
    func body(content: Content) -> some View {
        content
            // 统一放开主题页底，列表行仍由各页的语义纸面令牌决定；系统外观保留系统滚动底色。
            .scrollContentBackground(store.selectedTheme != nil ? .hidden : .visible)
            .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.wallpaperVisible) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 定稿：宽窗「✎ 记一笔」带文字，窄窗只留图标。
                    Button { store.presentCapture() } label: {
                        if sizeClass == .compact { Image(systemName: "pencil") }
                        else { ToolbarTextLabel(title: "记一笔", systemImage: "pencil") }
                    }.accessibilityLabel("记一笔")
                        .popover(isPresented: $store.capturePresented) { capturePopover }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // 由页面安全区让开标签栏与附件位，提示不写固定底边偏移量。
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
    }
    private var capturePopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("记一笔").font(.headline)
            TextField("写下问题或关键词", text: $store.captureTitle, axis: .vertical)
                .lineLimit(2...5).onSubmit { store.capture() }
            if !store.captureError.isEmpty { Text(store.captureError).foregroundStyle(ThemeColors.danger) }
            HStack {
                Spacer()
                Button("记下") { store.capture() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(minWidth: 280, idealWidth: 340)
        .presentationCompactAdaptation(.sheet)
    }
}
private extension View {
    func shellChrome(store: ShellStore) -> some View { modifier(ShellChrome(store: store)) }
}

private struct TimerAccessoryModifier<Accessory: View>: ViewModifier {
    @Bindable var store: ShellStore
    let accessory: Accessory

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: store.miniTimerVisible) { accessory }
        } else if store.miniTimerVisible {
            // iOS 26.0 没有 isEnabled 重载；无计时时不应用附件位修饰器，避免系统创建空容器。
            content.tabViewBottomAccessory { accessory }
        } else {
            content
        }
    }
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
