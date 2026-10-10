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
        let logicalDay = LogicalDayBridgeAdapter()
        let statistics = StatisticsBridgeAdapter()
        let focusHistory = FocusHistoryBridgeAdapter()
        let settings = SettingsBridgeAdapter()
        let categories = CategoryBridgeAdapter()
        let scheduleBridge = ScheduleBridgeAdapter()
        let interactions = InteractionBridgeAdapter()
        let week = WeekStore(tasks: tasks, logicalDay: logicalDay, pendingDeletion: pending, interactions: interactions,
                             weekStart: "", weekDates: { start in
                                 try statistics.weekStats(startDate: start).map(\.date)
                             }, weekStartProvider: { try statistics.currentWeeklyReview().weekStart })
        let timeline = TimelineStore(history: focusHistory, statistics: statistics, pendingDeletion: pending,
                                     logicalDay: logicalDay, date: logicalDay.today)
        let schedule = ScheduleStore(bridge: scheduleBridge, settingsBridge: settings, logicalDay: logicalDay)
        let core = CoreBridges(tasks: tasks, interactions: interactions,
                               categories: categories, logicalDay: logicalDay,
                               settings: settings, statistics: statistics,
                               focusHistory: focusHistory, pendingDeletion: pending,
                               taskActions: actions, weekStore: week, timelineStore: timeline, scheduleStore: schedule)
        // 保留同步保存顺序；闭包不保留 Store，页面保存登记由外壳管理，P4 挂入各页编辑会话。
        PTLifecycleBridge.flushHandler = { [weak store] in
            MainActor.assumeIsolated { store?.flushEdits() }
        }
        return UIHostingController(rootView: ShellRootView(store: store).environment(core))
    }
}
