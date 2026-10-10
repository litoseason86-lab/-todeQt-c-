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
        // 055-P3B：各页复用一份动作与撤销槽；领域桥接的回调仅有一个 Store 作为接收者。
        let tasks = TaskBridgeAdapter()
        let pending = PendingDeletionStore(bridge: PendingDeletionBridgeAdapter(), tasks: tasks, shell: store)
        let actions = TaskActions(tasks: tasks, pendingDeletion: pending, shell: store)
        store.taskActions = actions
        let core = CoreBridges(tasks: tasks, interactions: InteractionBridgeAdapter(),
                               categories: CategoryBridgeAdapter(), logicalDay: LogicalDayBridgeAdapter(),
                               settings: SettingsBridgeAdapter(), statistics: StatisticsBridgeAdapter(),
                               focusHistory: FocusHistoryBridgeAdapter(), pendingDeletion: pending,
                               taskActions: actions)
        let focus = FocusStore(focus: FocusBridgeAdapter(), settings: core.settings, tasks: core.tasks,
                               pendingDeletion: pending, shell: store)
        focus.start()
        actions.focusHook = focus
        // 055-P4-1：今日任务页的 Store 在根上装配一份，⌘N 经外壳现有回调切页并请求新建输入。
        // 回调槽只有一个，今日页监听信号用的是自己的一份适配器，不占用 CoreBridges 里共享的那份。
        let today = TodayStore(tasks: TaskBridgeAdapter(), interactions: InteractionBridgeAdapter(),
                               logicalDay: LogicalDayBridgeAdapter(), settings: SettingsBridgeAdapter(),
                               statistics: StatisticsBridgeAdapter(), gaps: GapReminderBridgeAdapter(),
                               pendingDeletion: pending, shell: store, focus: FocusBridgeAdapter())
        // 仪表盘使用独立桥接实例；这些桥的回调是单槽，不能覆盖 FocusStore 使用的共享任务与设置桥。
        let dashboard = DashboardStore(tasks: TaskBridgeAdapter(), statistics: StatisticsBridgeAdapter(),
                                       settings: SettingsBridgeAdapter(),
                                       actions: actions, shell: store, focus: focus)
        store.onStartOrPause = { [weak focus] in focus?.startOrPauseFromShortcut() }
        store.captureSourceProvider = { [weak focus] in focus?.captureSource }
        store.onNewTask = { [weak store, weak today] in
            store?.select(.today); today?.requestNewTask()
        }
        // 保留同步保存顺序；闭包不保留 Store，页面保存登记由外壳管理，P4 挂入各页编辑会话。
        PTLifecycleBridge.flushHandler = { [weak store] in
            MainActor.assumeIsolated { store?.flushEdits() }
        }
        return UIHostingController(rootView: ShellRootView(store: store)
            .environment(core).environment(today).environment(dashboard).environment(focus).environment(store))
    }
}
