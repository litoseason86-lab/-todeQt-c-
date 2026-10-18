import IPadCore
import PTBridge
import SwiftUI
import UIKit

// C++ 在场景连接后的主队列调用，返回持有一次引用的控制器；不生成 Swift 给 C++ 使用的头文件。
@_cdecl("PTMakeNativeRootViewController")
public func makeNativeRootViewController() -> UnsafeMutableRawPointer {
    let address = MainActor.assumeIsolated { () -> UInt in
        UInt(bitPattern: Unmanaged.passRetained(NativeRoot.makeController()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)!
}

@MainActor enum NativeRoot {
    static func makeController() -> UIViewController {
        let logicalDay = LogicalDayBridgeAdapter()
        // 所有表单装配前注入 C++ 的纯计算日期；闭包实时读取，不能缓存启动时的逻辑今天。
        LogicalDateNavigation.logicalTodayProvider = { logicalDay.today }
        let store = ShellStore(bridge: ShellBridgeAdapter())
        // 055-P3B：各页复用一份动作与撤销槽；每个 Store 独占自己的信号适配器，独立的 Qt 连接仍读取同一 C++ 服务。
        let tasks = TaskBridgeAdapter()
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeAdapter(), tasks: tasks, shell: store)
        store.onAccessibilityTimeoutSuspensionChanged = { [weak pending] suspended in
            pending?.setAutomaticCommitSuspended(suspended)
        }
        let actions = TaskActions(tasks: tasks, pendingDeletion: pending, shell: store)
        store.taskActions = actions
        let statisticsBridge = StatisticsBridgeAdapter()
        let focusHistory = FocusHistoryBridgeAdapter()
        let settingsBridge = SettingsBridgeAdapter()
        let categories = CategoryBridgeAdapter()
        let scheduleBridge = ScheduleBridgeAdapter()
        let interactions = InteractionBridgeAdapter()
        // 本周使用独立任务信号适配器，避免 FocusStore.start 覆盖单槽回调；动作与撤销槽仍共享。
        let week = WeekStore(tasks: TaskBridgeAdapter(), logicalDay: LogicalDayBridgeAdapter(), pendingDeletion: pending, interactions: InteractionBridgeAdapter(),
                             weekStart: "", weekDates: { start in
                                 try statisticsBridge.weekStats(startDate: start).map(\.date)
                             }, weekStartProvider: { try statisticsBridge.currentWeeklyReview().weekStart })
        // TimelineStore 也订阅完成信号；FocusBridge 的回调是单槽，不能与 FocusStore 或 TodayStore 共用适配器。
        let timeline = TimelineStore(history: focusHistory, statistics: statisticsBridge, pendingDeletion: pending,
                                     logicalDay: LogicalDayBridgeAdapter(), date: logicalDay.today,
                                     focus: FocusBridgeAdapter())
        let schedule = ScheduleStore(bridge: scheduleBridge, settingsBridge: SettingsBridgeAdapter(), logicalDay: LogicalDayBridgeAdapter())
        let trash = TrashBridgeAdapter()
        let sync = SyncBridgeAdapter()
        let backup = BackupBridgeAdapter()
        let export = ExportBridgeAdapter()
        let routines = RoutineBridgeAdapter()
        let core = CoreBridges(tasks: tasks, interactions: interactions,
                               categories: categories, logicalDay: logicalDay,
                               settings: settingsBridge, statistics: statisticsBridge,
                               focusHistory: focusHistory, pendingDeletion: pending,
                               taskActions: actions, inlineEditor: InlineTaskEditor(tasks: tasks, interactions: interactions, shell: store),
                               weekStore: week, timelineStore: timeline, scheduleStore: schedule,
                               trash: trash, sync: sync, backup: backup, export: export, routines: routines)
        let focus = FocusStore(focus: FocusBridgeAdapter(), settings: SettingsBridgeAdapter(), tasks: TaskBridgeAdapter(),
                               pendingDeletion: pending, shell: store, reduceMotion: { UIAccessibility.isReduceMotionEnabled })
        focus.start()
        actions.focusHook = focus
        // 055-P4-1：今日任务页的 Store 在根上装配一份，⌘N 经外壳现有回调切页并请求新建输入。
        // 回调槽只有一个，今日页监听信号用的是自己的一份适配器，不占用 CoreBridges 里共享的那份。
        let today = TodayStore(tasks: TaskBridgeAdapter(), interactions: InteractionBridgeAdapter(),
                               logicalDay: LogicalDayBridgeAdapter(), settings: SettingsBridgeAdapter(),
                               statistics: StatisticsBridgeAdapter(), gaps: GapReminderBridgeAdapter(),
                               pendingDeletion: pending, shell: store, focus: FocusBridgeAdapter())
        // 仪表盘使用独立桥接实例；这些桥的回调是单槽，避免覆盖其它 Store 的单槽回调。
        let dashboard = DashboardStore(tasks: TaskBridgeAdapter(), statistics: StatisticsBridgeAdapter(),
                                       settings: SettingsBridgeAdapter(),
                                       actions: actions, shell: store, focus: focus, logicalDay: LogicalDayBridgeAdapter())
        store.onStartOrPause = { [weak focus] in focus?.startOrPauseFromShortcut() }
        store.captureSourceProvider = { [weak focus] in focus?.captureSource }
        store.onNewTask = { [weak store, weak today] in
            store?.select(.today); today?.requestNewTask()
        }
        // 055-P4-3：一个领域一份会话，多个页面容器从环境复用。
        let gaps = GapStore(bridge: KnowledgeGapAdapter(), logicalDay: LogicalDayBridgeAdapter(),
                            shell: store, categories: CategoryBridgeAdapter(), preferences: .standard, tasks: TaskBridgeAdapter())
        let memos = MemoStore(bridge: MemoAdapter(), categories: CategoryBridgeAdapter(), shell: store, preferences: .standard)
        let countdown = CountdownStore(bridge: CountdownAdapter(), logicalDay: LogicalDayBridgeAdapter(), shell: store)
        // 055-P4-4：页面订阅各自的桥接实例，单回调协议不会覆盖其它页面的失效通知。
        let history = HistoryStore(history: FocusHistoryBridgeAdapter(), logicalDay: LogicalDayBridgeAdapter())
        let statistics = StatsStore(statistics: StatisticsBridgeAdapter(), logicalDay: LogicalDayBridgeAdapter(),
                                    tasks: TaskBridgeAdapter(), settings: SettingsBridgeAdapter(),
                                    categories: CategoryBridgeAdapter(), history: FocusHistoryBridgeAdapter(), defaults: .standard)
        // 055-P4-5：设置页独占自己的设置适配器，不覆盖 FocusStore 的回调。
        let trashStore = TrashStore(bridge: TrashBridgeAdapter(), logicalDay: LogicalDayBridgeAdapter())
        let settings = SettingsStore(bridge: SettingsBridgeAdapter())
        let settingsCategories = SettingsCategoryStore(bridge: CategoryBridgeAdapter())
        let settingsRoutines = SettingsRoutineStore(bridge: RoutineBridgeAdapter(), categories: CategoryBridgeAdapter())
        // 055-P4-5：异步文件操作跨设置子页存活，回调不随一次导出注销。
        let settingsSync = SettingsSyncStore(bridge: SyncBridgeAdapter())
        let settingsBackup = SettingsBackupStore(bridge: BackupBridgeAdapter(), files: FileTransferWorkspace(),
            commitPending: { [weak pending] in pending?.commitIfNeeded() ?? false },
            restoreWarning: { sync.restoreWarning() })
        let settingsExport = SettingsExportStore(bridge: ExportBridgeAdapter(), files: FileTransferWorkspace(), logicalDay: LogicalDayBridgeAdapter())
        // 保留同步保存顺序；闭包不保留 Store，页面保存登记由外壳管理，P4 挂入各页编辑会话。
        PTLifecycleBridge.flushHandler = { [weak store] in
            MainActor.assumeIsolated {
                // 先让 UIKit 上屏组合，再同步保存；返回后 C++ 才写出设备同步。
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                store?.flushEdits()
            }
        }
        let search = SearchStore(tasks: TaskBridgeAdapter(), gaps: KnowledgeGapAdapter(), categories: CategoryBridgeAdapter())
        let root = ShellRootView(store: store)
            .environment(search).environment(core).environment(today).environment(dashboard).environment(focus).environment(store)
            .environment(gaps).environment(memos).environment(countdown)
            .environment(history).environment(statistics).environment(settings).environment(settingsCategories).environment(settingsRoutines).environment(settingsSync).environment(settingsBackup).environment(settingsExport).environment(trashStore)
        // 055-R4：调试巡检复用同一套 Store 另开窗口截图；只在带巡检参数启动时登记，平时不保留任何引用。
        if UITour.isRequested {
            UITour.rootView = { AnyView(root) }
            UITour.selectSettingsSection = { [weak settings] in settings?.selectSection($0) }
            UITour.openSearch = { [weak store, weak search] query in search?.query = query; search?.search(); store?.openSearch() }
            UITour.sheets = [
                ("new-task", { [weak store, weak today] in store?.select(.today); today?.requestNewTask() }, { [weak today] in today?.endComposing() }),
                ("gap", { [weak store, weak gaps] in store?.select(.knowledgeGap); gaps?.requestForm(.add) }, { [weak gaps] in gaps?.dismissForm() }),
                ("countdown", { [weak store, weak countdown] in store?.select(.countdown); countdown?.requestAdd() }, { [weak countdown] in countdown?.dismissForm() }),
                ("session", { [weak store, weak timeline] in store?.select(.todayFocus); timeline?.manualAddPresented = true }, { [weak timeline] in timeline?.manualAddPresented = false })]
            UITour.extras[.todayFocus] = [
                ("prev", { [weak timeline] in if let day = timeline?.adjacentDate(days: -1) { timeline?.selectDate(day) } }),
                (nil, { [weak timeline] in if let day = timeline?.adjacentDate(days: 1) { timeline?.selectDate(day) } })]
        }
        // 10-12 测速：各页的只读重读与页内只读切换，只在带测速参数启动时登记。
        if UITour.isRequested && UIPerfProbe.isRequested {
            UIPerfProbe.refreshers = [
                .today: { [weak today] in today?.refresh() }, .dashboard: { [weak dashboard] in dashboard?.refresh() },
                .week: { [weak week] in week?.refresh() }, .todayFocus: { [weak timeline] in timeline?.refresh() },
                .schedule: { [weak schedule] in schedule?.refresh() }, .monthGoal: { [weak history] in history?.refresh() },
                .statistics: { [weak statistics] in statistics?.refresh() }, .countdown: { [weak countdown] in countdown?.refresh() },
                .knowledgeGap: { [weak gaps] in gaps?.refresh() }, .memo: { [weak memos] in memos?.refresh() },
                .trash: { [weak trashStore] in trashStore?.reload() }]
            UIPerfProbe.shellRefresh = { [weak store] in store?.refresh() }
            // 与今日列表共用分组集合；不足两条时不拿第一条冒充第二条，也不从回收过的界面节点猜行数。
            UIPerfProbe.editSecondTodayTask = { [weak today, weak core] in
                guard let today, let core else { return false }
                let rows = today.unfinished
                guard rows.count >= 2 else { return false }
                return core.inlineEditor.begin(id: rows[1].id)
            }
            UIPerfProbe.todayTaskCounts = { [weak today] in
                guard let today else { return nil }
                return (unfinished: today.unfinished.count, finished: today.finished.count)
            }
            // 只读编辑器公开状态；第二条编号同源返回，探针不用辅助功能树推断列表行是否存在。
            UIPerfProbe.todayEditingState = { [weak today, weak core] in
                guard let today, let core else { return nil }
                let editor = core.inlineEditor
                return UIPerfProbe.TodayEditingState(secondTaskID: today.unfinished.dropFirst().first?.id,
                                                    taskID: editor.taskID, focusRequested: editor.focusRequested,
                                                    isEditing: editor.isEditing, isComposing: today.composing)
            }
            UIPerfProbe.extraActions = [
                ("计时跳动·外壳", { [weak store] in store?.refreshTimer() }),
                ("计时跳动·专注页", { [weak focus] in focus?.refreshSnapshot() }),
                ("提示条出现", { [weak store] in store?.showToast("测速提示") }),
                ("提示条收起", { [weak store] in store?.retireToast() })]
            // 选另一条再选回：记下原来选中的那条，测完还原。
            var memoOriginal: Int?
            var gapOriginal: Int?
            let statsOriginal = statistics.range
            UIPerfProbe.interactions = [
                .today: [("展开已完成", { [weak today] in today?.completedExpanded = true }),
                         ("收起已完成", { [weak today] in today?.completedExpanded = false }),
                         ("进入多选", { [weak today] in today?.beginSelection() }),
                         ("退出多选", { [weak today] in today?.endSelection() }),
                         ("行内编辑第一条", { [weak today, weak core] in
                             if let id = today?.unfinished.first?.id { _ = core?.inlineEditor.begin(id: id) } }),
                         ("结束行内编辑", { [weak core] in _ = core?.inlineEditor.finish() }),
                         ("打开第一条详情", { [weak today] in UIPerfProbe.todayDetail?(today?.unfinished.first?.id) }),
                         ("关闭详情", { UIPerfProbe.todayDetail?(nil) }),
                         ("起一行新任务", { [weak today] in today?.requestNewTask() }),
                         ("结束新建", { [weak today] in today?.endComposing() })],
                .week: [("下一周", { [weak week] in week?.shiftWeek(1) }), ("回到原来那周", { [weak week] in week?.shiftWeek(-1) })],
                .todayFocus: [("前一天", { [weak timeline] in if let day = timeline?.adjacentDate(days: -1) { timeline?.selectDate(day) } }),
                              ("后一天", { [weak timeline] in if let day = timeline?.adjacentDate(days: 1) { timeline?.selectDate(day) } })],
                .monthGoal: [("上个月", { [weak history] in history?.moveMonth(-1) }),
                             ("回本月", { [weak history] in history?.returnToCurrentMonth() })],
                .statistics: [("切到周", { [weak statistics] in statistics?.selectRange(.week) }),
                              ("切到月", { [weak statistics] in statistics?.selectRange(.month) }),
                              ("切回原周期", { [weak statistics] in statistics?.selectRange(statsOriginal) })],
                .schedule: [("下一周", { [weak schedule] in if let s = schedule { s.goToWeek(s.weekIndex + 1) } }),
                            ("回本周", { [weak schedule] in schedule?.goToCurrentWeek() })],
                .memo: [("选另一条", { [weak memos] in
                            guard let memos else { return }
                            memoOriginal = memos.selectedID
                            if let other = memos.items.first(where: { $0.id != memos.selectedID }) { _ = memos.presentMemo(other.id) }
                        }),
                        ("选回原来那条", { [weak memos] in
                            if let id = memoOriginal { _ = memos?.presentMemo(id) } else { _ = memos?.dismissMemo() }
                        })],
                .knowledgeGap: [("选另一条", { [weak gaps] in
                                    guard let gaps else { return }
                                    gapOriginal = gaps.selectedID
                                    if let other = gaps.items.first(where: { $0.id != gaps.selectedID }) { gaps.select(other.id) }
                                }),
                                ("选回原来那条", { [weak gaps] in
                                    if let id = gapOriginal { gaps?.select(id) } else { gaps?.closeDetail() }
                                })]]
        }
        UITour.startIfRequested(shell: store)
        let controller = UIHostingController(rootView: root)
        // 10-12 真机测速：弹出表单或浮层时，系统把背后整个界面的 HDR 余量特征（hdrHeadroomUsageLimit）改成「限制」、
        // 着色改成变暗，关掉后再改回来；特征一变 SwiftUI 就把整棵视图的环境刷新一遍、所有文字重新排版，
        // 开、关各让主线程卡约 200 毫秒（iPadOS 27.0.1）。界面里没有 HDR 内容、背后已有系统的暗化遮罩，
        // 所以在根上固定这两项，不再随弹出变化。
        controller.traitOverrides.headroomUsageLimit = .inactive
        controller.view.tintAdjustmentMode = .normal
        return controller
    }
}
