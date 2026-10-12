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
        let store = ShellStore(bridge: ShellBridgeAdapter())
        // 055-P3B：各页复用一份动作与撤销槽；每个 Store 独占自己的信号适配器，独立的 Qt 连接仍读取同一 C++ 服务。
        let tasks = TaskBridgeAdapter()
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeAdapter(), tasks: tasks, shell: store)
        let actions = TaskActions(tasks: tasks, pendingDeletion: pending, shell: store)
        store.taskActions = actions
        let logicalDay = LogicalDayBridgeAdapter()
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
                               taskActions: actions, weekStore: week, timelineStore: timeline, scheduleStore: schedule,
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
                ("new-task", { [weak store, weak today] in store?.select(.today); today?.requestNewTask() }, { [weak today] in today?.newTaskPresented = false }),
                ("gap", { [weak store, weak gaps] in store?.select(.knowledgeGap); gaps?.requestForm(.add) }, { [weak gaps] in gaps?.dismissForm() }),
                ("countdown", { [weak store, weak countdown] in store?.select(.countdown); countdown?.requestAdd() }, { [weak countdown] in countdown?.dismissForm() }),
                ("session", { [weak store, weak timeline] in store?.select(.todayFocus); timeline?.manualAddPresented = true }, { [weak timeline] in timeline?.manualAddPresented = false })]
            UITour.extras[.todayFocus] = [
                ("prev", { [weak timeline] in if let day = timeline?.adjacentDate(days: -1) { timeline?.selectDate(day) } }),
                (nil, { [weak timeline] in if let day = timeline?.adjacentDate(days: 1) { timeline?.selectDate(day) } })]
        }
        UITour.startIfRequested(shell: store)
        return UIHostingController(rootView: root)
    }
}
