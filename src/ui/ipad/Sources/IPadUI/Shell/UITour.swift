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
    // 表单截图：打开、关闭各一个闭包；补录表单是页面自己的状态，单独放进一个表单大小的窗口里画。
    static var sheets: [(name: String, open: () -> Void, close: () -> Void)] = []
    static var sessionSheet: (() -> AnyView)?
    private static var windows: [UIWindow] = []

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour") }
    private static var tapsRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-taps") }
    // 另带 --ipad-ui-tour-warm 时再用暖色主题各拍一轮（只在巡检窗口里套用，不改设置），对照浅色定稿。
    private static var warmRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-warm") }

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
                if let sessionSheet {
                    let sheetWindow = makeWindow(scene: scene, size: CGSize(width: 560, height: 620), compact: false, root: sessionSheet())
                    try? await Task.sleep(for: .milliseconds(1500))
                    save(sheetWindow, name: "sheet-session-\(item.name)")
                    sheetWindow.isHidden = true
                    windows.removeAll { $0 === sheetWindow }
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
