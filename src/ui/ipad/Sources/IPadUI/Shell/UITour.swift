import IPadCore
import SwiftUI
import UIKit

// 055-R4 调试巡检：只有带 --ipad-ui-tour 启动才生效，不带参数时没有任何副作用。
// 在同一场景里另开两个固定尺寸的窗口（宽 1210×834、窄 375×834，与定稿画板同尺寸），
// 用同一套 Store 依次切到每一页截图，存进 Documents/ui-tour/，由 Mac 用 devicectl 拉回与定稿对照。
// 只读页面：唯一的写入是选中页偏好，结束时还原成启动时的那一页。
// 另带 --ipad-ui-tour-taps 时，截图之后在窄窗口里逐个触发底部标签按钮，复现标签栏崩溃；
// 每一步先写进 tour.log 再执行，崩溃时日志停在出事的那一步。
@MainActor enum UITour {
    static var rootView: (() -> AnyView)?
    // 设置页各分组也逐个截图，用来确认宽窗左栏切换。
    static var selectSettingsSection: ((SettingsSection) -> Void)?
    // 某页截完后追加的状态：有后缀的截一张，后缀为空的只执行（用于还原）。
    static var extras: [PageID: [(suffix: String?, action: () -> Void)]] = [:]
    // 打开搜索并填入查询词，截搜索结果页。
    static var openSearch: ((String) -> Void)?
    // 表单截图：打开、关闭各一个闭包，表单都由页面真实弹出，带上主题与表单底色。
    static var sheets: [(name: String, open: () -> Void, close: () -> Void)] = []
    private static var windows: [UIWindow] = []

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour") }
    private static var tapsRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-taps") }
    // 另带 --ipad-ui-tour-warm 时再用暖色主题各拍一轮（只在巡检窗口里套用，不改设置），对照浅色定稿。
    private static var warmRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-warm") }
    // 另带 --ipad-ui-tour-focus 时只拍专注页的几种小窗口（含应用当前窗口的实际尺寸），每种切过去后 0.3 秒、
    // 3.5 秒各一张，不拍其它页。只有启动巡检时已有正在走的计时且满足自动隐藏条件，按钮才会在 3 秒后隐藏，
    // 两张图才可对照隐藏前后布局；没有计时会话时两张图的控制显隐相同，只能核对首帧布局。
    private static var focusOnlyRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-focus") }
    // 另带 --ipad-ui-tour-capture 时只复现 10-12 用户报的问题：记一笔浮层开着时切页再切回（之后记一笔、补录都弹不出），
    // 并顺带跑一遍下面的侧栏巡检、拍专注历史的月历时长。每步截图，并把各窗口当前挂着的弹出链写进 tour.log。
    private static var captureDiagnosisRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-capture") }
    // 另带 --ipad-ui-tour-sidebar 时只跑侧栏巡检：经真实 SidebarSwipeProbe 的处理函数收起侧栏、再展开，逐帧截图。
    // 主窗口是宽窗且侧栏展开时就在主窗口里做（不改尺寸）；否则另开 1210×834 的宽窗口做，结果只作参考——
    // 10-12 第二个窗口里看着正常的收起写法，在主窗口真实左滑时仍出过问题。
    private static var sidebarOnlyRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-sidebar") }
    // 真实左滑探针在巡检启动时登记的收起入口，按窗口匹配。
    static var sidebarTriggers: [ObjectIdentifier: (UIWindow) -> Bool] = [:]

    static func startIfRequested(shell: ShellStore) {
        guard isRequested else { return }
        Task { @MainActor in
            // 等主窗口挂上、各 Store 首次读取完成。
            try? await Task.sleep(for: .seconds(2))
            await run(shell: shell)
        }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ui-tour")
    }

    private static func log(_ line: String) {
        let url = directory.appendingPathComponent("tour.log")
        let text = "\(Date().formatted(.iso8601)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.synchronize(); try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    private static func run(shell: ShellStore) async {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let rootView else { log("没有可用场景或根视图"); return }
        let original = shell.selection
        log("开始，原选中页 \(original.rawValue)")
        if UIPerfProbe.sheetDiagnosisRequested {
            await UIPerfProbe.diagnoseSheet(shell: shell, log: { log($0) })
            shell.select(original)
            log("完成")
            return
        }
        if UIPerfProbe.isRequested {
            await UIPerfProbe.run(shell: shell, log: { log($0) },
                                  write: { name, text in try? Data(text.utf8).write(to: directory.appendingPathComponent(name)) })
            shell.select(original)
            log("完成")
            return
        }
        if sidebarOnlyRequested {
            await diagnoseSidebar(scene: scene, root: rootView, shell: shell)
            shell.select(original)
            log("完成")
            return
        }
        if focusOnlyRequested {
            await captureFocusSizes(scene: scene, root: rootView, shell: shell)
            shell.select(original)
            log("完成")
            return
        }
        if captureDiagnosisRequested {
            await diagnoseCaptureAndSidebar(scene: scene, root: rootView, shell: shell)
            shell.select(original)
            log("完成")
            return
        }
        var sizes: [(name: String, size: CGSize, compact: Bool, theme: String?)] = [
            ("wide", CGSize(width: 1210, height: 834), false, nil),
            ("compact", CGSize(width: 375, height: 834), true, nil)]
        if warmRequested {
            sizes += [("wide-warm", CGSize(width: 1210, height: 834), false, "warm"),
                      ("compact-warm", CGSize(width: 375, height: 834), true, "warm")]
        }
        for item in sizes {
            let root = item.theme.map { AnyView(rootView().environment(\.previewThemeID, $0)) } ?? rootView()
            let window = makeWindow(scene: scene, size: item.size, compact: item.compact, root: root)
            for page in PageID.allCases {
                shell.select(page)
                try? await Task.sleep(for: .milliseconds(1500))
                save(window, name: "\(page.rawValue)-\(item.name)")
                for extra in extras[page] ?? [] {
                    extra.action()
                    try? await Task.sleep(for: .milliseconds(1200))
                    if let suffix = extra.suffix { save(window, name: "\(page.rawValue)-\(suffix)-\(item.name)") }
                }
            }
            if let openSearch {
                openSearch("线")
                try? await Task.sleep(for: .milliseconds(1500))
                save(window, name: "search-\(item.name)")
                openSearch("")
            }
            if !item.compact && item.theme == nil {
                await captureCollapsedSidebar(in: window, shell: shell, name: item.name)
                for sheet in sheets {
                    sheet.open()
                    try? await Task.sleep(for: .milliseconds(1500))
                    save(window, name: "sheet-\(sheet.name)-\(item.name)")
                    sheet.close()
                    try? await Task.sleep(for: .milliseconds(800))
                }
            }
            if !item.compact, item.theme == nil, let selectSettingsSection {
                shell.select(.settings)
                for (index, section) in SettingsAvailability.sections.enumerated() {
                    selectSettingsSection(section)
                    try? await Task.sleep(for: .milliseconds(1000))
                    save(window, name: "settings-\(index)-\(item.name)")
                }
                selectSettingsSection(.general)
            }
            if item.compact && item.theme == nil && tapsRequested {
                await tapTabBar(in: window)
                await toggleSizes(in: window, shell: shell)
            }
            window.isHidden = true
            windows.removeAll { $0 === window }
        }
        shell.select(original)
        log("完成")
    }

    private static func captureFocusSizes(scene: UIWindowScene, root: () -> AnyView, shell: ShellStore) async {
        let current = scene.effectiveGeometry.coordinateSpace.bounds.size
        let minimum = scene.sizeRestrictions?.minimumSize ?? .zero
        log("当前窗口 \(Int(current.width))×\(Int(current.height))，系统最小 \(Int(minimum.width))×\(Int(minimum.height))，"
            + "尺寸类别 \(scene.traitCollection.horizontalSizeClass == .compact ? "窄" : "宽")")
        var sizes: [(name: String, size: CGSize)] = [("current", current)]
        if minimum.width > 0 && minimum.height > 0 { sizes.append(("minimum", minimum)) }
        sizes += [("600x410", CGSize(width: 600, height: 410)), ("500x580", CGSize(width: 500, height: 580)),
                  ("375x834", CGSize(width: 375, height: 834))]
        for item in sizes {
            // 与系统一致：窄于 700 按窄窗口（标签栏在底部）排。
            let window = makeWindow(scene: scene, size: item.size, compact: item.size.width < 700, root: root())
            shell.select(.today)
            try? await Task.sleep(for: .milliseconds(1200))
            shell.select(.focus)
            try? await Task.sleep(for: .milliseconds(300))
            save(window, name: "focus-\(item.name)-0.3s")
            try? await Task.sleep(for: .milliseconds(3200))
            save(window, name: "focus-\(item.name)-3.5s")
            window.isHidden = true
            windows.removeAll { $0 === window }
        }
    }

    private static func diagnoseCaptureAndSidebar(scene: UIWindowScene, root: () -> AnyView, shell: ShellStore) async {
        // 两个窗口共用同一个 ShellStore，也有相同的打开位置；复现期间先把其它窗口藏起来，隔离这次巡检，结束还原。
        let hidden = scene.windows.filter { !$0.isHidden && $0.rootViewController.map(hasTabController) == true }
        hidden.forEach { $0.isHidden = true }
        defer { hidden.forEach { $0.isHidden = false } }
        let window = makeWindow(scene: scene, size: CGSize(width: 1210, height: 834), compact: false, root: root())
        func step(_ name: String, wait milliseconds: Int) async {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            logPresentations(name, shell: shell, scene: scene)
            save(window, name: "capture-\(name)")
        }
        shell.select(.today)
        await step("0-today", wait: 1500)
        shell.presentCapture(from: .page(.today))
        await step("1-open", wait: 1200)
        shell.select(.dashboard)
        await step("2-switched", wait: 1500)
        shell.select(.today)
        await step("3-back", wait: 1500)
        // 工具栏按钮走的是切换：按两次，记下每次之后能否弹出。
        shell.toggleCapture(from: .page(.today))
        await step("4-toggle1", wait: 1200)
        shell.toggleCapture(from: .page(.today))
        await step("5-toggle2", wait: 1200)
        shell.dismissCapture()
        if let session = sheets.first(where: { $0.name == "session" }) {
            session.open()
            await step("6-session", wait: 1500)
            session.close()
            try? await Task.sleep(for: .milliseconds(800))
        }
        window.isHidden = true
        windows.removeAll { $0 === window }
        // 侧栏优先在主窗口测；记一笔与月历仍保留各自原有的巡检窗口。
        hidden.forEach { $0.isHidden = false }
        await diagnoseSidebar(scene: scene, root: root, shell: shell)
        hidden.forEach { $0.isHidden = true }
        // 专注历史：侧栏展开（格子窄，时长折两行）与收起（格子宽，一行）各一张。
        let history = makeWindow(scene: scene, size: CGSize(width: 1210, height: 834), compact: false, root: root())
        shell.select(.monthGoal)
        try? await Task.sleep(for: .milliseconds(1500))
        save(history, name: "history-sidebar")
        if let tabs = history.rootViewController.flatMap({ tabControllers($0).first }) {
            tabs.sidebar.isHidden = true
            try? await Task.sleep(for: .milliseconds(2000))
            save(history, name: "history-collapsed")
        }
        history.isHidden = true
        windows.removeAll { $0 === history }
    }
    private static func diagnoseSidebar(scene: UIWindowScene, root: () -> AnyView, shell: ShellStore) async {
        let candidates = scene.windows.filter {
            !$0.isHidden && !windows.contains($0) && $0.rootViewController.map(hasTabController) == true
        }
        var window = candidates.first(where: \.isKeyWindow) ?? candidates.first
        var tabs = window?.rootViewController.flatMap { tabControllers($0).first }
        var extra: UIWindow?
        if let current = tabs, current.traitCollection.horizontalSizeClass == .regular, !current.sidebar.isHidden {
            log("侧栏巡检在主窗口 \(Int(window?.bounds.width ?? 0))×\(Int(window?.bounds.height ?? 0))")
        } else {
            let fresh = makeWindow(scene: scene, size: CGSize(width: 1210, height: 834), compact: false, root: root())
            extra = fresh; window = fresh
            try? await Task.sleep(for: .milliseconds(1500))
            tabs = fresh.rootViewController.flatMap { tabControllers($0).first }
            log("主窗口不是展开侧栏的宽窗，改在另开的 1210×834 窗口里做（结果只作参考）")
        }
        defer { if let extra { extra.isHidden = true; windows.removeAll { $0 === extra } } }
        guard let window, let tabs else { log("侧栏巡检跳过：没有标签控制器"); return }
        log("系统 \(UIDevice.current.systemVersion)，减少动态效果=\(UIAccessibility.isReduceMotionEnabled)；调用真实探针处理函数，不合成触摸")
        // 先像日常使用那样切几页，最后停在只从摘要块进入的今日任务，看它被选中时收起顶部怎么显示。
        for page in [PageID.dashboard, .week, .focus, .today] {
            shell.select(page)
            try? await Task.sleep(for: .milliseconds(900))
        }
        save(window, name: "sidebar-0-before")
        let start = Date()
        guard Array(sidebarTriggers.values).contains(where: { $0(window) }) else {
            log("侧栏巡检停止：这个窗口没有登记的 SidebarSwipeProbe，不退回直接修改 isHidden")
            return
        }
        for milliseconds in [100, 300, 800, 1500, 3000] {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            if milliseconds > elapsed { try? await Task.sleep(for: .milliseconds(milliseconds - elapsed)) }
            save(window, name: "sidebar-1-collapse-\(milliseconds)ms")
        }
        log("收起后 hidden=\(tabs.sidebar.isHidden) tabBarFrame=\(tabs.tabBar.frame)")
        // 再展开：看列表里会不会闪出不该出现的行（10-12 上一种写法展开时闪出三行）。
        let expand = Date()
        tabs.sidebar.isHidden = false
        for milliseconds in [100, 300, 800, 1500] {
            let elapsed = Int(Date().timeIntervalSince(expand) * 1000)
            if milliseconds > elapsed { try? await Task.sleep(for: .milliseconds(milliseconds - elapsed)) }
            save(window, name: "sidebar-2-expand-\(milliseconds)ms")
        }
    }

    private static func tabControllers(_ controller: UIViewController) -> [UITabBarController] {
        ((controller as? UITabBarController).map { [$0] } ?? []) + controller.children.flatMap(tabControllers)
    }
    private static func hasTabController(_ controller: UIViewController) -> Bool { !tabControllers(controller).isEmpty }
    // 每个可见窗口从根控制器往下的弹出链（类名，收起中的标出），以及记一笔的开关与打开位置。
    private static func logPresentations(_ label: String, shell: ShellStore, scene: UIWindowScene) {
        let chains = scene.windows.filter { !$0.isHidden }.map { window -> String in
            var chain: [String] = []
            var current = window.rootViewController?.presentedViewController
            while let controller = current {
                chain.append(String(describing: type(of: controller)) + (controller.isBeingDismissed ? "(收起中)" : ""))
                current = controller.presentedViewController
            }
            return "\(Int(window.bounds.width))×\(Int(window.bounds.height))[\(chain.joined(separator: ">"))]"
        }
        let anchor = shell.captureAnchor.map { String(describing: $0) } ?? "无"
        log("\(label)：记一笔开关=\(shell.capturePresented) captureAnchor=\(anchor) 弹出链 " + chains.joined(separator: "；"))
    }

    // 侧栏收起后顶部是五个常用页的浮动标签栏；巡检时临时收起，截完恢复。
    private static func captureCollapsedSidebar(in window: UIWindow, shell: ShellStore, name: String) async {
        func tabControllers(_ controller: UIViewController) -> [UITabBarController] {
            ((controller as? UITabBarController).map { [$0] } ?? []) + controller.children.flatMap(tabControllers)
        }
        guard let root = window.rootViewController, let tabs = tabControllers(root).first else {
            log("没找到标签控制器，跳过收起侧栏截图"); return
        }
        shell.select(.today)
        tabs.sidebar.isHidden = true
        try? await Task.sleep(for: .milliseconds(1500))
        save(window, name: "collapsed-\(name)")
        tabs.sidebar.isHidden = false
        try? await Task.sleep(for: .milliseconds(800))
    }

    private static func makeWindow(scene: UIWindowScene, size: CGSize, compact: Bool, root: AnyView) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: root)
        controller.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        window.rootViewController = controller
        window.windowLevel = .normal + 1
        window.isHidden = false
        windows.append(window)
        return window
    }

    private static func save(_ window: UIWindow, name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        do {
            try image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
            log("截图 \(name)")
        } catch { log("截图失败 \(name)：\(error.localizedDescription)") }
    }

    private static func tapTabBar(in window: UIWindow) async {
        func tabBars(in view: UIView) -> [UITabBar] {
            (view as? UITabBar).map { [$0] } ?? view.subviews.flatMap(tabBars)
        }
        func controls(in view: UIView) -> [UIControl] {
            view.subviews.flatMap { sub in (sub as? UIControl).map { [$0] } ?? controls(in: sub) }
        }
        guard let bar = tabBars(in: window).first(where: { !$0.isHidden && $0.window != nil }) else {
            log("窄窗口里没找到可见的标签栏"); return
        }
        let buttons = controls(in: bar).filter { !$0.isHidden && $0.alpha > 0 }
        log("标签栏按钮 \(buttons.count) 个")
        for round in 0..<2 {
            for (index, button) in buttons.enumerated() {
                log("第 \(round + 1) 轮点第 \(index + 1) 个：\(button.accessibilityLabel ?? String(describing: type(of: button)))")
                button.sendActions(for: .primaryActionTriggered)
                button.sendActions(for: .touchUpInside)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        log("标签栏点按完成，没有崩溃")
    }

    // 停在「更多」里的页面、侧栏底栏页面或常用页时来回切宽窄，覆盖 10-11 14:10 那份
    // -[_UITabModel _setSelectedItem:] 崩溃（选中值不在当前标签集合里）的路径。
    private static func toggleSizes(in window: UIWindow, shell: ShellStore) async {
        guard let controller = window.rootViewController else { return }
        for page in [PageID.memo, .trash, .week, .settings, .today, .todayFocus] {
            shell.select(page)
            for compact in [false, true, false, true] {
                log("停在 \(page.rawValue) 切到\(compact ? "窄" : "宽")")
                controller.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        log("宽窄切换完成，没有崩溃")
    }
}
