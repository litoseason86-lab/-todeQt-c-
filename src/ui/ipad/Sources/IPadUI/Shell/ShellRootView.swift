import IPadCore
import SwiftUI

private enum ShellTab: Hashable { case page(PageID), more }

struct ShellRootView: View {
    @Bindable var store: ShellStore
    @Environment(CoreBridges.self) private var core
    @Environment(FocusStore.self) private var focus
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var tab: ShellTab = .page(.dashboard)
    @State private var morePath: [PageID] = []

    var body: some View {
        TabView(selection: $tab) {
            ForEach([PageID.today, .focus, .week], id: \.self) { page in
                Tab(page.title, systemImage: page.symbol, value: ShellTab.page(page)) { pageView(page) }
                    .tabPlacement(.pinned)
                    .defaultVisibility(.hidden, for: .sidebar)
            }
            // 知识缺口入口在摘要块里，注册隐藏的页面值供头部切页；不占窄窗口标签栏。
            Tab(PageID.knowledgeGap.title, systemImage: PageID.knowledgeGap.symbol,
                value: ShellTab.page(.knowledgeGap)) { pageView(.knowledgeGap) }
                .tabPlacement(.sidebarOnly)
                .defaultVisibility(.hidden, for: .sidebar)
            TabSection("页面") {
                ForEach(store.sidebarPages, id: \.self) { page in
                    Tab(page.title, systemImage: page.symbol, value: ShellTab.page(page)) { pageView(page) }
                        .tabPlacement(page == .dashboard ? .pinned : .sidebarOnly)
                }
            }
            // 两组都使用 TabSection，避免 Qt 验证版里普通标签被系统排到分组之前。
            TabSection("应用") {
                ForEach(PageID.fixed, id: \.self) { page in
                    Tab(page.title, systemImage: page.symbol, value: ShellTab.page(page)) { pageView(page) }
                        .tabPlacement(.sidebarOnly)
                }
            }
            // 「更多」始终注册，宽窗口只由系统隐藏；动态增删 Tab 会让 iPadOS 重建标签控制器时
            // 出现标签项与页面控制器错位，窄窗口点击标签可能触发 UIKit 断言崩溃。
            Tab("更多", systemImage: "ellipsis", value: ShellTab.more) { moreView }
                .tabPlacement(.pinned)
                .defaultVisibility(.hidden, for: .sidebar)
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.sidebar)
        .tabViewSidebarHeader { summaryTiles }
        .tabViewBottomAccessory(isEnabled: store.miniTimerVisible) { miniTimer }
        .tint(ThemeColors.accentInk)
        .preferredColorScheme(store.snapshot.useWallpaper
            ? (["starry", "rainy", "moon"].contains(store.snapshot.backgroundTheme) ? .dark : .light) : nil)
        .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.snapshot.useWallpaper) }
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
        .onChange(of: sizeClass) { _, _ in scheduleSelectionSync() }
        .onChange(of: tab) { _, selected in
            if case let .page(page) = selected { store.select(page) }
        }
    }

    // 窄窗口非主标签页由「更多」的 NavigationStack 承载；旋转回宽窗口时恢复同一页面。
    private func syncSelection() {
        let size: ShellWindowSize = sizeClass == .compact ? .compact : .regular
        switch ShellStore.navigationTarget(for: store.selection, size: size) {
        case .page(let page):
            morePath = []
            tab = .page(page)
        case .more(let path):
            morePath = path
            tab = .more
        }
    }

    private func scheduleSelectionSync() {
        // UIKit 处理标签点击的同一轮里不能再改变标签结构或选中值；推迟到下一轮，
        // 让 TabView 先完成自身的 selection 更新，避免 iPadOS 26 的控制器断言。
        Task { @MainActor in
            await Task.yield()
            syncSelection()
        }
    }

    private func pageView(_ page: PageID) -> some View {
        NavigationStack {
            PageRegistry.view(for: page, core: core, shell: store).shellChrome(store: store)
                .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.snapshot.useWallpaper) }
        }
    }
    private var moreView: some View {
        NavigationStack(path: $morePath) {
            List(store.morePages, id: \.self) { page in
                NavigationLink(value: page) { Label(page.title, systemImage: page.symbol) }
                    .listRowBackground(store.snapshot.useWallpaper ? ThemeColors.surface : nil)
            }
            .scrollContentBackground(store.snapshot.useWallpaper ? .hidden : .visible)
            .background { WallpaperBackground(theme: store.snapshot.backgroundTheme, enabled: store.snapshot.useWallpaper) }
            .navigationTitle("更多")
            .navigationDestination(for: PageID.self) { page in
                PageRegistry.view(for: page, core: core, shell: store).shellChrome(store: store)
                    .onAppear { store.select(page) }
            }
            .shellChrome(store: store)
        }
    }
    private var summaryTiles: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { tile(.today, value: "\(store.snapshot.todayPendingCount)"); tile(.focus, value: focusSummary) }
            GridRow { tile(.week, value: "\(store.snapshot.weekPendingCount)"); tile(.knowledgeGap, value: "\(store.snapshot.dueGapCount)") }
        }
        .padding(.vertical, 8)
    }
    private var focusSummary: String {
        store.snapshot.hasTimer ? focus.primaryTimeText : DurationFormat.seconds(Double(store.snapshot.todayFocusedSeconds))
    }
    private var clock: String {
        ShellDisplay.clock(store.snapshot.mode == 1 ? store.snapshot.remainingSeconds : store.snapshot.elapsedSeconds)
    }
    private func tile(_ page: PageID, value: String) -> some View {
        Button { store.select(page) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: page.symbol); Spacer(); Text(value).monospacedDigit() }
                Text(page.title).font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(page.title)，\(value)")
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
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.presentCapture() } label: { Label("记一笔", systemImage: "square.and.pencil") }
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
