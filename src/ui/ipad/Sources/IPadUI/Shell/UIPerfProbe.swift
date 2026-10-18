import Darwin
import IPadCore
import MachO
import SwiftUI
import UIKit

// 10-12 调试测速：只有同时带 --ipad-ui-tour 与 --ipad-ui-tour-perf 启动才运行，平时没有任何副作用。
// 用户反映各页点按都有点卡：在应用的主窗口里（不另开窗口，另开的窗口共用同一套 Store，会让每次刷新多画一遍）
// 依次切每一页、做页内的只读切换、开关各个表单、搜索、记一笔、设置分组、侧栏收放，再在几页上静置，
// 记下主线程每次被占用多久。只读：不完成、不删除、不开始计时；唯一的写入是选中页偏好，结束时还原。
//
// 测法：在主运行循环上挂两个观察者，「醒来」记起点、「将要睡眠」记终点，两者之差就是这一轮主线程连续忙了多久
// （终点观察者排在 Core Animation 提交之后，含界面提交）。这一轮没结束之前，手指点下去也得等它结束才处理，
// 所以「最长一段」近似一次点按最多要等多久。测量窗口内不写日志，结果攒在内存里，全部测完一次写出。
@MainActor enum UIPerfProbe {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-perf") }
    // 各页 Store 的只读重读：写库后各页就是这样整份重读的，单独计时看桥接与查询要多久。
    static var refreshers: [PageID: () -> Void] = [:]
    static var shellRefresh: (() -> Void)?
    // 页内只读切换（翻周、翻月、切统计周期、切筛选、选另一条等），按页登记。
    static var interactions: [PageID: [(name: String, action: () -> Void)]] = [:]
    // 第二条编辑与行数直接读列表实际使用的 Store 集合，不依赖虚拟化后的辅助功能节点。
    static var editSecondTodayTask: (() -> Bool)?
    static var todayTaskCounts: (() -> (unfinished: Int, finished: Int)?)?
    struct TodayEditingState {
        let secondTaskID: Int?
        let taskID: Int
        let focusRequested: Bool
        let isEditing: Bool
        let isComposing: Bool
    }
    // 编辑器状态与预期第二条编号同一次读取，避免把辅助功能树没生成节点误报成编辑没有打开。
    static var todayEditingState: (() -> TodayEditingState?)?
    // 今日任务页登记的「打开 / 关闭某条任务的详情浮层」：浮层状态在视图里，测速只能经它触发。
    static var todayDetail: ((Int?) -> Void)?
    // 另带 --ipad-ui-tour-sample 时同时采样主线程调用栈，看时间花在哪些函数上（采样本身让主线程每毫秒停几微秒，
    // 所以计时数字以不带采样的那一轮为准）。
    private static var samplingRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-sample") }
    private static var sampler: MainThreadSampler?
    // 只改界面状态的模拟动作（计时跳一下、提示条出现与收起），看它们会让哪些页面跟着重算。
    static var extraActions: [(name: String, action: () -> Void)] = []

    private struct Chunk { let start: Double; let duration: Double }
    private static var chunks: [Chunk] = []
    private static var iterationStart = 0.0
    private static var observers: [CFRunLoopObserver] = []
    private static var rows: [String] = []
    private static var segmentRows: [String] = []

    private static func now() -> Double { CFAbsoluteTimeGetCurrent() }

    private static func install() {
        guard observers.isEmpty else { return }
        // 观察者回调就在主线程上；按 MainActor 访问静态状态。
        let begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { iterationStart = now(); sampler?.setBusy(true) }
        }
        let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                let finished = now()
                if iterationStart > 0 { chunks.append(Chunk(start: iterationStart, duration: finished - iterationStart)) }
                iterationStart = 0
                sampler?.setBusy(false)
            }
        }
        for observer in [begin, end].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }
    private static func uninstall() {
        observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
        observers.removeAll()
    }

    // 一次动作：动作本身同步耗时、到第一次界面提交的时间、之后 settle 毫秒内主线程总共忙了多久、最长一段、超过 50 毫秒的段数。
    private static func measure(_ section: String, _ name: String, settle: Int = 900, _ action: () -> Void) async {
        try? await Task.sleep(for: .milliseconds(350))
        chunks.removeAll()
        sampler?.setTag(rows.count)
        let start = now()
        action()
        let sync = now() - start
        try? await Task.sleep(for: .milliseconds(settle))
        sampler?.setTag(-1)
        // 动作所在的那一轮在 start 之前就醒了，只算 start 之后的部分。
        let after = chunks.filter { $0.start + $0.duration >= start }
        let clipped = after.map { max(0, $0.start + $0.duration - max($0.start, start)) }
        let firstCommit = after.first.map { $0.start + $0.duration - start } ?? 0
        let busy = clipped.reduce(0, +)
        let longest = clipped.max() ?? 0
        let long = clipped.filter { $0 > 0.05 }.count
        rows.append([section, name, ms(sync), ms(firstCommit), ms(busy), ms(longest), "\(long)"].joined(separator: "\t"))
        // 逐段表与聚合表共用同一份裁切结果，保留发生顺序；不另计标签，采样标签仍只对应 perf.tsv 的数据行。
        segmentRows.append([section, name, "\(clipped.count)", clipped.map(ms).joined(separator: ",")].joined(separator: "\t"))
    }
    // 静置：什么都不做，看计时器每秒跳动等后台刷新让主线程每秒忙多久。
    private static func idle(_ name: String, seconds: Int) async {
        try? await Task.sleep(for: .milliseconds(800))
        chunks.removeAll()
        sampler?.setTag(rows.count)
        let start = now()
        try? await Task.sleep(for: .seconds(seconds))
        let span = now() - start
        sampler?.setTag(-1)
        let after = chunks.filter { $0.start >= start }
        let busy = after.map(\.duration).reduce(0, +)
        let longest = after.map(\.duration).max() ?? 0
        let perSecond = busy / span
        let wakes = Double(after.count) / span
        rows.append(["静置", name, "", "", ms(perSecond) + "/秒", ms(longest), String(format: "%.1f次/秒", wakes)].joined(separator: "\t"))
    }
    // 同步重读：连读三次取中位数，只含 Store 内的桥接与查询，不含之后的界面重算。
    private static func timeRefresh(_ name: String, _ refresh: () -> Void) -> String {
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = now(); refresh(); samples.append(now() - start)
        }
        return ms(samples.sorted()[1])
    }
    private static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    // 另带 --ipad-ui-tour-sheetdiag 时只做一件事：开、关一个表单，记下前后根视图、标签控制器、当前页的
    // 尺寸、安全区、变换和特征集合，找出弹出表单时让背后整页重排的那一项变化。
    static var sheetDiagnosisRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ipad-ui-tour-sheetdiag") }
    static func diagnoseSheet(shell: ShellStore, log: (String) -> Void) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
              let root = window.rootViewController,
              let sheet = UITour.sheets.first(where: { $0.name == "gap" }) else { log("诊断：缺少窗口或表单"); return }
        func describe(_ label: String) -> [String: String] {
            var result: [String: String] = [:]
            var targets: [(String, UIViewController)] = [("root", root)]
            if let tabs = tabControllers(root).first {
                targets.append(("tabs", tabs))
                if let selected = tabs.selectedViewController {
                    targets.append(("page", selected))
                    if let nav = selected as? UINavigationController, let top = nav.topViewController { targets.append(("pageTop", top)) }
                }
            }
            for (name, controller) in targets {
                let view = controller.view!
                result["\(name).bounds"] = "\(view.bounds.size)"
                result["\(name).frameInWindow"] = "\(view.convert(view.bounds, to: nil))"
                result["\(name).safe"] = "\(view.safeAreaInsets)"
                result["\(name).transform"] = "\(view.transform) layer=\(view.layer.transform.m11)"
                result["\(name).superTransform"] = "\(view.superview?.transform ?? .identity)"
                result["\(name).tintMode"] = "\(view.tintAdjustmentMode.rawValue)"
                for part in controller.traitCollection.description.components(separatedBy: "; ") {
                    let pieces = part.split(separator: "=", maxSplits: 1)
                    if pieces.count == 2 { result["\(name).trait.\(pieces[0].trimmingCharacters(in: .whitespaces))"] = String(pieces[1]) }
                }
            }
            return result
        }
        shell.select(.knowledgeGap)
        try? await Task.sleep(for: .milliseconds(1500))
        let before = describe("开表单前")
        sheet.open()
        try? await Task.sleep(for: .milliseconds(1200))
        let during = describe("表单开着")
        sheet.close()
        try? await Task.sleep(for: .milliseconds(1200))
        let after = describe("关表单后")
        for key in before.keys.sorted() where before[key] != during[key] || before[key] != after[key] {
            log("诊断 \(key)：前 \(before[key] ?? "-") ｜ 开着 \(during[key] ?? "-") ｜ 关后 \(after[key] ?? "-")")
        }
        log("诊断完成，共比较 \(before.count) 项")
    }

    static func run(shell: ShellStore, log: (String) -> Void, write: (String, String) -> Void) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            log("测速：没有可用场景"); return
        }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first { !$0.isHidden }
        let tabs = window?.rootViewController.flatMap { tabControllers($0).first }
        let original = shell.selection
        let wide = tabs?.traitCollection.horizontalSizeClass == .regular
        log("测速开始：主窗口 \(Int(window?.bounds.width ?? 0))×\(Int(window?.bounds.height ?? 0))，\(wide ? "宽" : "窄")，"
            + "侧栏\(tabs.map { $0.sidebar.isHidden ? "收起" : "展开" } ?? "无")，计时 \(shell.snapshot.hasTimer ? (shell.snapshot.running ? "进行中" : "暂停") : "无")，"
            + "系统 \(UIDevice.current.systemVersion)，最高 \(window?.screen.maximumFramesPerSecond ?? 0) 帧/秒，减少动态效果=\(UIAccessibility.isReduceMotionEnabled)")
        rows = ["分组\t动作\t动作同步ms\t到首次提交ms\t之后主线程总忙ms\t最长一段ms\t超50ms段数"]
        segmentRows = ["分组\t动作\t段数\t各段时长ms"]
        install()
        defer { uninstall() }
        if samplingRequested {
            sampler = MainThreadSampler()
            sampler?.start()
            log("测速：同时采样主线程调用栈")
        }

        // 1. 切页：第一轮多数页是第一次创建，第二轮是再次进入。
        let pages = PageID.allCases.filter { $0 != shell.selection } + [shell.selection]
        for round in 1...2 {
            for page in pages {
                await measure("切页第\(round)轮", page.title) { shell.select(page) }
                if round == 1 && page == .today {
                    if let counts = todayTaskCounts?() {
                        log("测速：首次进入今日任务的任务行数：未完成=\(counts.unfinished)，已完成=\(counts.finished)（TodayStore 列表集合）")
                    } else {
                        log("测速：今日任务行数入口未登记或 Store 已释放，跳过行数记录")
                    }
                }
            }
            log("测速：切页第 \(round) 轮完成")
        }

        // 2. 每页：同步重读耗时，以及重读后界面重算（相当于每次写库后的那次整页刷新）。
        var refreshRows: [String] = []
        for page in PageID.allCases {
            shell.select(page)
            try? await Task.sleep(for: .milliseconds(1200))
            if let refresh = refreshers[page] {
                refreshRows.append("\(page.title)\t\(timeRefresh(page.title, refresh))")
                await measure("重读后重算", page.title) { refresh() }
            }
            for item in interactions[page] ?? [] {
                await measure("页内·\(page.title)", item.name, item.action)
                if page == .today && item.name == "结束行内编辑" {
                    await repeatInlineEditing(in: window, close: item.action, log: log)
                }
                if page == .today && item.name == "结束新建",
                   let open = interactions[.today]?.first(where: { $0.name == "起一行新任务" })?.action {
                    guard let window, presentationIsClosed(in: window),
                          todayEditingState?()?.isComposing == false else {
                        log("测速：上一次新建尚未收起或窗口不可用，跳过起一行新任务·第2次")
                        continue
                    }
                    await measure("页内·今日任务", "起一行新任务·第2次", open)
                    await measure("页内·今日任务", "结束新建·第2次", item.action)
                }
            }
        }
        if let shellRefresh {
            refreshRows.append("外壳摘要\t\(timeRefresh("外壳摘要", shellRefresh))")
            await measure("重读后重算", "外壳摘要") { shellRefresh() }
        }
        log("测速：页内与重读完成")

        // 3. 其它表单与浮层：沿用原来的关闭动作和等待时间，确认已收起后才测第二次，避免把叠层当成再次打开。
        for sheet in UITour.sheets {
            await measure("表单", "开·\(sheet.name)", settle: 1200) { sheet.open() }
            var closeRequestedAt = 0.0
            await measure("表单", "关·\(sheet.name)", settle: 1000) {
                closeRequestedAt = now()
                sheet.close()
            }
            if sheet.name == "session" {
                if let window {
                    await diagnoseSessionDismissal(in: window, requestedAt: closeRequestedAt, log: log)
                } else {
                    log("测速：关·session 测完后窗口不可用，无法检查补录浮层收起")
                }
            }
            if ["new-task", "gap", "countdown", "session"].contains(sheet.name) {
                guard let window, presentationIsClosed(in: window),
                      sheet.name != "new-task" || todayEditingState?()?.isComposing == false else {
                    log("测速：\(sheet.name) 上一次表单尚未收起或窗口不可用，跳过开·\(sheet.name)·第2次")
                    continue
                }
                await measure("表单", "开·\(sheet.name)·第2次", settle: 1200) { sheet.open() }
                await measure("表单", "关·\(sheet.name)·第2次", settle: 1000) { sheet.close() }
            }
        }
        shell.select(.today)
        try? await Task.sleep(for: .milliseconds(1000))
        await measure("浮层", "开·记一笔", settle: 1000) { shell.presentCapture(from: .page(.today)) }
        var captureCloseRequestedAt = 0.0
        await measure("浮层", "关·记一笔", settle: 800) {
            captureCloseRequestedAt = now()
            shell.dismissCapture()
        }
        var captureClosed = false
        if let window {
            captureClosed = await observePresentationDismissal(in: window, name: "记一笔", action: "关·记一笔",
                                                               requestedAt: captureCloseRequestedAt, log: log)
        }
        if captureClosed && !shell.capturePresented {
            await measure("浮层", "开·记一笔·第2次", settle: 1000) { shell.presentCapture(from: .page(.today)) }
            await measure("浮层", "关·记一笔·第2次", settle: 800) { shell.dismissCapture() }
        } else {
            log("测速：上一次记一笔尚未收起或窗口不可用，跳过开·记一笔·第2次")
        }
        if let openSearch = UITour.openSearch {
            await measure("搜索", "打开并搜「线」", settle: 1200) { openSearch("线") }
            await measure("搜索", "关闭", settle: 1000) { shell.closeSearch() }
        }
        if let selectSection = UITour.selectSettingsSection {
            shell.select(.settings)
            try? await Task.sleep(for: .milliseconds(1200))
            for section in SettingsAvailability.sections {
                await measure("设置分组", section.rawValue) { selectSection(section) }
            }
            selectSection(.general)
        }
        if let tabs, wide, !tabs.sidebar.isHidden {
            shell.select(.today)
            try? await Task.sleep(for: .milliseconds(1000))
            await measure("侧栏", "收起", settle: 1500) { tabs.sidebar.isHidden = true }
            await measure("侧栏", "展开", settle: 1500) { tabs.sidebar.isHidden = false }
        }

        shell.select(.today)
        try? await Task.sleep(for: .milliseconds(1000))
        for item in extraActions {
            await measure("模拟", item.name, settle: 700, item.action)
        }

        // 4. 静置：计时在走时每秒的刷新代价。
        for page in [PageID.today, .dashboard, .focus, .todayFocus, .week, .statistics] {
            shell.select(page)
            await idle(page.title, seconds: 6)
        }
        shell.select(original)
        write("perf.tsv", rows.joined(separator: "\n") + "\n")
        write("perf-segments.tsv", segmentRows.joined(separator: "\n") + "\n")
        write("perf-refresh.tsv", "页面\t同步重读中位ms\n" + refreshRows.joined(separator: "\n") + "\n")
        if let sampler {
            sampler.stop()
            // 整理采样（遍历系统库方法表、逐个查地址）要好几秒，放到后台线程，主线程不卡、也不会被系统当成无响应。
            let (samples, symbols) = await Task.detached(priority: .userInitiated) { sampler.export() }.value
            write("samples.txt", samples)
            write("symbols.txt", symbols)
            self.sampler = nil
        }
        log("测速完成，结果在 perf.tsv、perf-refresh.tsv、perf-segments.tsv")
    }

    private static func presentationIsClosed(in window: UIWindow) -> Bool {
        guard let root = window.rootViewController else { return false }
        return root.presentedViewController == nil
    }

    // 收起检查放在测量窗口之外；每 100 ms 观察一次，既不把等待算进关表单耗时，也不给第二次打开混入残留浮层。
    private static func waitForPresentationToClose(in window: UIWindow) async -> Bool {
        let deadline = now() + 3
        while !presentationIsClosed(in: window) && now() < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return presentationIsClosed(in: window) }
        }
        return presentationIsClosed(in: window)
    }

    private static func presentedControllers(in window: UIWindow) -> [UIViewController] {
        var chain: [UIViewController] = []
        var presented = window.rootViewController?.presentedViewController
        while let controller = presented {
            chain.append(controller)
            presented = controller.presentedViewController
        }
        return chain
    }

    // 补录和记一笔共用关闭后的观察；超时保留当时的控制器链，第二次打开由调用方据结果放行。
    private static func observePresentationDismissal(in window: UIWindow, name: String, action: String,
                                                     requestedAt: Double, log: (String) -> Void) async -> Bool {
        let checkStartedAt = now()
        if await waitForPresentationToClose(in: window) {
            log("测速：\(name)浮层已收起，\(action) 测完后等待 \(ms(now() - checkStartedAt)) ms，距关闭请求 \(ms(now() - requestedAt)) ms")
            return true
        }
        // 只记录 UIKit 实际持有的逐级弹出控制器；不改产品绑定，也不直接 dismiss 掩盖原来的收起问题。
        log("测速：\(action) 测完后等待 \(ms(now() - checkStartedAt)) ms 仍未收起，弹出控制器链："
            + presentedControllers(in: window).map { String(describing: type(of: $0)) }.joined(separator: " → "))
        return false
    }

    private static func diagnoseSessionDismissal(in window: UIWindow, requestedAt: Double, log: (String) -> Void) async {
        if await observePresentationDismissal(in: window, name: "补录", action: "关·session", requestedAt: requestedAt, log: log) {
            return
        }
        let cancelStartedAt = now()
        if let controller = presentedControllers(in: window).last,
           let cancel = findElement(in: controller.view, labelPrefix: "取消") {
            log("测速：在补录弹出视图中激活「取消」：\(cancel.accessibilityActivate() ? "成功" : "失败")")
        } else {
            log("测速：补录弹出视图里未找到「取消」，无法激活")
        }
        let closed = await waitForPresentationToClose(in: window)
        log("测速：补录取消取证后等待 \(ms(now() - cancelStartedAt)) ms，\(closed ? "已收起" : "仍未收起，将跳过第二次打开")")
    }

    private static func repeatInlineEditing(in window: UIWindow?, close: () -> Void, log: (String) -> Void) async {
        guard let window, presentationIsClosed(in: window) else {
            log("测速：仍有浮层或窗口不可用，跳过行内编辑第二条")
            return
        }
        guard let state = todayEditingState?() else {
            log("测速：编辑器状态入口不可用，跳过行内编辑第二条")
            return
        }
        guard !state.isEditing else {
            log("测速：上一次行内编辑尚未收起（taskID=\(state.taskID)），跳过行内编辑第二条")
            return
        }
        guard let secondTaskID = state.secondTaskID, let open = editSecondTodayTask else {
            log("测速：未完成任务不足两条或第二条编辑入口不可用，跳过行内编辑第二条")
            return
        }
        var activated = false
        await measure("页内·今日任务", "行内编辑第二条") { activated = open() }
        guard activated else {
            log("测速：第二条编辑入口返回失败，跳过行内编辑第二条，该次结果不可用")
            return
        }
        if let current = todayEditingState?() {
            if current.taskID != secondTaskID {
                log("测速：第二条编辑 taskID 不匹配（预期=\(secondTaskID)，实际=\(current.taskID)），该次结果不可用")
            }
            if current.focusRequested {
                log("测速：第二条编辑 focusRequested 未清掉，该次结果不可用")
            }
            if current.taskID == secondTaskID && !current.focusRequested {
                log("测速：第二条编辑状态核对通过（taskID=\(current.taskID)，focusRequested=false）")
            }
        } else {
            log("测速：第二条编辑测完后状态入口不可用，该次结果不可用")
        }
        // 没有输入任何字符，复用第一条的结束入口，只释放编辑；不提交新标题或备注。
        await measure("页内·今日任务", "结束行内编辑·第2次", close)
    }

    private static func tabControllers(_ controller: UIViewController) -> [UITabBarController] {
        ((controller as? UITabBarController).map { [$0] } ?? []) + controller.children.flatMap(tabControllers)
    }
    // 只在补录弹出视图内查首个「取消」，不查列表行，也不遍历背后页面，避免误点其它入口。
    private static func findElement(in root: NSObject, labelPrefix: String) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        let matching: (NSObject) -> Bool = { object in
            object.isAccessibilityElement && object.accessibilityLabel?.hasPrefix(labelPrefix) == true
        }
        return search(root, matching: matching, depth: 0, seen: &seen)
    }
    private static func search(_ object: NSObject, matching: (NSObject) -> Bool, depth: Int,
                               seen: inout Set<ObjectIdentifier>) -> NSObject? {
        guard depth < 80, seen.count < 20000,
              seen.insert(ObjectIdentifier(object)).inserted else { return nil }
        if matching(object) { return object }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements as? [NSObject] {
            children = elements
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                children = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let view = object as? UIView { children += view.subviews.filter { !$0.isHidden && $0.alpha > 0 } }
        for child in children {
            if let match = search(child, matching: matching, depth: depth + 1, seen: &seen) { return match }
        }
        return nil
    }
}

// 主线程调用栈采样：后台线程每毫秒暂停主线程一次，读出寄存器后沿帧指针链往上走，记下返回地址就立即恢复。
// 主线程暂停期间不能分配内存（主线程可能正握着 malloc 的锁，会互相等死），所以先写进预先分配的缓冲区，恢复后再拷贝。
// 只在测量窗口内（标签 >= 0）采样；地址在测完后用 dladdr 就地查出所在镜像与最近的导出符号，
// 应用自己的函数再在 Mac 上用 atos 按镜像加载地址还原。
private final class MainThreadSampler: @unchecked Sendable {
    private let target: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let lock = NSLock()
    private var tag = -1
    // 主线程这一轮是否醒着（运行循环观察者置位）；睡着时不采样，样本只剩真在干活的时刻，内存小得多
    // （10-12：连睡眠一起采，三分钟十万份样本，整理时被系统因内存结束）。
    private var busy = false
    private var running = false
    private var records: [(tag: Int, frames: [UInt])] = []
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: 160)

    // 只能在主线程上创建：记下的是创建时所在线程。
    init() {
        target = pthread_mach_thread_np(pthread_self())
        let high = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = high
        stackLow = high - UInt(pthread_get_stacksize_np(pthread_self()))
    }
    deinit { buffer.deallocate() }

    func setTag(_ value: Int) { lock.lock(); tag = value; lock.unlock() }
    func setBusy(_ value: Bool) { lock.lock(); busy = value; lock.unlock() }
    private func currentTag() -> Int { lock.lock(); defer { lock.unlock() }; return busy ? tag : -1 }
    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    func start() {
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [self] in
            while isRunning() {
                let current = currentTag()
                if current >= 0 {
                    let count = sampleOnce()
                    if count > 0 {
                        let frames = Array(UnsafeBufferPointer(start: buffer, count: count))
                        lock.lock(); records.append((current, frames)); lock.unlock()
                    }
                }
                usleep(1000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func stop() { lock.lock(); running = false; lock.unlock(); usleep(5000) }

    // 返回写进缓冲区的帧数；暂停期间只做寄存器读取和栈上的指针读取。
    private func sampleOnce() -> Int {
        guard thread_suspend(target) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(target) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(target, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // 系统库是 arm64e，返回地址带指针认证位；去掉高位才是真实地址。
        func strip(_ value: UInt64) -> UInt { UInt(value & 0x0000_000F_FFFF_FFFF) }
        var written = 0
        buffer[written] = strip(state.__pc); written += 1
        buffer[written] = strip(state.__lr); written += 1
        var frame = UInt(state.__fp)
        while written < 160, frame >= stackLow, frame + 16 <= stackHigh, frame & 7 == 0 {
            let pointer = UnsafePointer<UInt>(bitPattern: frame)!
            let next = pointer[0]
            let returnAddress = strip(UInt64(pointer[1]))
            if returnAddress == 0 { break }
            buffer[written] = returnAddress; written += 1
            if next <= frame { break }
            frame = next
        }
        return written
    }

    // samples.txt：每行「标签<TAB>十六进制地址，叶子在前」；symbols.txt：「地址<TAB>镜像<TAB>镜像加载地址<TAB>最近导出符号」。
    func export() -> (String, String) {
        lock.lock(); let all = records; lock.unlock()
        var lines: [String] = []
        var unique = Set<UInt>()
        for record in all {
            lines.append("\(record.tag)\t" + record.frames.map { String($0, radix: 16) }.joined(separator: " "))
            unique.formUnion(record.frames)
        }
        var symbols: [String] = []
        let methods = Self.objcMethods()
        for address in unique {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { continue }
            let image = info.dli_fname.map { String(cString: $0) } ?? "?"
            let base = UInt(bitPattern: info.dli_fbase)
            var symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
            // 系统库的内部符号在设备上被抹成 <redacted>；Objective-C 方法可以按实现地址就近找回名字。
            if symbol == "<redacted>" || symbol == "?", let method = Self.nearest(methods, address) { symbol = method }
            symbols.append("\(String(address, radix: 16))\t\((image as NSString).lastPathComponent)\t\(String(base, radix: 16))\t\(symbol)")
        }
        return (lines.joined(separator: "\n") + "\n", symbols.joined(separator: "\n") + "\n")
    }

    // UIKit、SwiftUI 等系统库里全部 Objective-C 方法的实现地址，按地址排序；只在测完导出时建一次。
    // 只存方法句柄，名字等查到了才拼（几十万个方法名一次全拼出来太占内存）。
    private static func objcMethods() -> [(address: UInt, method: Method, prefix: String, cls: AnyClass)] {
        let wanted: Set<String> = ["UIKitCore", "SwiftUI", "SwiftUICore", "QuartzCore", "UIFoundation"]
        var result: [(address: UInt, method: Method, prefix: String, cls: AnyClass)] = []
        var classes: [AnyClass] = []
        for image in 0..<_dyld_image_count() {
            guard let path = _dyld_get_image_name(image),
                  wanted.contains((String(cString: path) as NSString).lastPathComponent) else { continue }
            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(path, &count) else { continue }
            // 不用 Swift 的类型转换：它会给类发消息，遇到不继承 NSObject 的类会走消息转发崩溃（10-12 真机）。
            for index in 0..<Int(count) { if let cls = objc_lookUpClass(names[index]) { classes.append(cls) } }
            free(names)
        }
        for cls in classes {
            var targets: [(AnyClass, String)] = [(cls, "-")]
            if let meta = object_getClass(cls) { targets.append((meta, "+")) }
            for pair in targets {
                let target: AnyClass = pair.0, prefix = pair.1
                var methodCount: UInt32 = 0
                guard let list = class_copyMethodList(target, &methodCount) else { continue }
                for item in 0..<Int(methodCount) {
                    let implementation = UInt(bitPattern: unsafeBitCast(method_getImplementation(list[item]), to: Int.self)) & 0x0000_000F_FFFF_FFFF
                    result.append((implementation, list[item], prefix, cls))
                }
                free(list)
            }
        }
        return result.sorted { $0.address < $1.address }
    }
    // 不超过 address 的最近一个方法实现，且相距不到 16 KB（再远多半是夹在中间的 C 函数，名字不可信）。
    private static func nearest(_ methods: [(address: UInt, method: Method, prefix: String, cls: AnyClass)], _ address: UInt) -> String? {
        var low = 0, high = methods.count - 1, found = -1
        while low <= high {
            let middle = (low + high) / 2
            if methods[middle].address <= address { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        guard found >= 0, address - methods[found].address < 0x4000 else { return nil }
        let item = methods[found]
        return "\(item.prefix)[\(String(cString: class_getName(item.cls))) \(NSStringFromSelector(method_getName(item.method)))]+0x"
            + String(address - item.address, radix: 16)
    }
}
