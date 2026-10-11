import IPadCore
import SwiftUI

private enum ShellTab: Hashable { case page(PageID), more }

struct ShellRootView: View {
    @Bindable var store: ShellStore
    @Environment(CoreBridges.self) private var core
    @Environment(FocusStore.self) private var focus
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // 宽窄各用一份选中状态：两个分支的标签集合不同，共用一份会把窄窗不存在的页面值交给窄窗标签栏。
    @State private var regularTab: PageID = .dashboard
    @State private var compactTab: ShellTab = .page(.dashboard)
    @State private var morePath: [PageID] = []

    var body: some View {
        tabs
            .modifier(TimerAccessoryModifier(store: store, accessory: miniTimer))
            .tint(ThemeColors.accentInk)
            .preferredColorScheme(preferredScheme)
            .background { ThemeAppearance(themeID: store.selectedTheme ?? "").frame(width: 0, height: 0) }
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
            .onChange(of: regularTab) { _, page in store.select(page) }
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

    // 宽窗口：侧栏可收起的标签栏。收起后顶部只有五个常用页；其余页面只在侧栏；
    // 废纸篓、设置的入口在侧栏底栏，标签只为承载页面，侧栏与标签栏都不显示。
    private var regularTabs: some View {
        TabView(selection: $regularTab) {
            ForEach(PageID.regularTabs, id: \.self) { page in
                Tab(page.tabTitle(size: .regular), systemImage: page.symbol, value: page) { pageView(page) }
                    .defaultVisibility(PageID.summary.prefix(3).contains(page) ? .hidden : .visible, for: .sidebar)
            }
            ForEach(store.sidebarPages.filter { !PageID.regularTabs.contains($0) }, id: \.self) { page in
                Tab(page.title, systemImage: page.symbol, value: page) { pageView(page) }
                    .badge(store.sidebarBadge(for: page).map { Text(String($0)) })
                    .tabPlacement(.sidebarOnly)
            }
            ForEach(PageID.fixed, id: \.self) { page in
                Tab(page.title, systemImage: page.symbol, value: page) { pageView(page) }
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
        if regularTab != store.selection { regularTab = store.selection }
        switch ShellStore.navigationTarget(for: store.selection, size: .compact) {
        case .page(let page):
            if compactTab != .page(page) { compactTab = .page(page) }
            if !morePath.isEmpty { morePath = [] }
        case .more(let path):
            if compactTab != .more { compactTab = .more }
            if morePath != path { morePath = path }
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
    private var moreView: some View {
        NavigationStack(path: $morePath) {
            List(store.morePages, id: \.self) { page in
                NavigationLink(value: page) {
                    Label { Text(page.title).foregroundStyle(ThemeColors.inkStrong) }
                    icon: { Image(systemName: page.symbol).foregroundStyle(ThemeColors.accentInk) }
                }
                    .listRowBackground(store.selectedTheme != nil ? ThemeColors.surface : nil)
            }
            .scrollContentBackground(store.selectedTheme != nil ? .hidden : .visible)
            .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.wallpaperVisible) }
            .navigationTitle("更多")
            .navigationDestination(for: PageID.self) { page in
                PageRegistry.view(for: page, core: core, shell: store).shellChrome(store: store)
                    .onAppear { store.select(page) }
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
    // 定稿侧栏底部：细分隔线下两行，图标焦糖、文字 16 常规，行高 44；当前页浅焦糖底。
    private var fixedEntries: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(PageID.fixed, id: \.self) { page in
                let selected = store.selection == page
                Button { store.select(page) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 18)).foregroundStyle(ThemeColors.accentInk)
                            .frame(width: 24)
                        Text(page.title).font(.system(size: 16)).foregroundStyle(ThemeColors.inkStrong)
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(selected ? ThemeColors.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(ThemeColors.border).frame(height: 1) }
    }
    private var preferredScheme: ColorScheme? {
        switch store.snapshot.appearance {
        case "light": .light
        case "dark": .dark
        case "theme": SettingsAvailability.theme(store.snapshot.backgroundTheme).mode == "dark" ? .dark : .light
        default: nil
        }
    }
    private var clock: String {
        ShellDisplay.clock(store.snapshot.mode == 1 ? store.snapshot.remainingSeconds : store.snapshot.elapsedSeconds)
    }
    // 定稿侧栏摘要块：当前页那块焦糖实底、浅色字，其余浅焦糖底；数字 22 粗、单位 13。
    private func tile(_ tile: ShellSummaryTile) -> some View {
        let selected = store.selection == tile.page
        return Button { store.select(tile.page) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: tile.page.symbol).font(.system(size: 17))
                        .foregroundStyle(selected ? ThemeColors.surface : ThemeColors.accentInk)
                    Spacer(minLength: 4)
                    MixedNumberText(parts: MixedNumberText.split(tile.value), numberSize: 22, unitSize: 13)
                        .foregroundStyle(selected ? ThemeColors.surface : ThemeColors.inkStrong)
                        .lineLimit(1).minimumScaleFactor(0.7)
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
