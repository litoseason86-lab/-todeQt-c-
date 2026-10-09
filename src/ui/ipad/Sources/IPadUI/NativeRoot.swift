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
        // 055-P4-4：页面订阅各自的桥接实例，单回调协议不会覆盖其它页面的失效通知。
        let history = HistoryStore(history: FocusHistoryBridgeAdapter(), logicalDay: LogicalDayBridgeAdapter())
        // 保留同步保存顺序；闭包不保留 Store，页面保存登记由外壳管理，P4 挂入各页编辑会话。
        PTLifecycleBridge.flushHandler = { [weak store] in
            MainActor.assumeIsolated { store?.flushEdits() }
        }
        return UIHostingController(rootView: ShellRootView(store: store).environment(core).environment(store).environment(history))
    }
}
