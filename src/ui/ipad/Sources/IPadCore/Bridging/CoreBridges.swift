import Observation
// 原生根持有唯一装配；P4 从环境读取共用桥接和动作，不在页面重复创建服务连接。
@MainActor @Observable public final class CoreBridges {
    public let tasks: any TaskBridgeProtocol
    public let interactions: any InteractionBridgeProtocol
    public let categories: any CategoryBridgeProtocol
    public let logicalDay: any LogicalDayBridgeProtocol
    public let settings: any SettingsBridgeProtocol
    public let statistics: any StatisticsBridgeProtocol
    public let focusHistory: any FocusHistoryBridgeProtocol
    public let pendingDeletion: PendingDeletionStore
    public let taskActions: TaskActions
    public init(tasks: any TaskBridgeProtocol, interactions: any InteractionBridgeProtocol,
                categories: any CategoryBridgeProtocol, logicalDay: any LogicalDayBridgeProtocol,
                settings: any SettingsBridgeProtocol, statistics: any StatisticsBridgeProtocol,
                focusHistory: any FocusHistoryBridgeProtocol, pendingDeletion: PendingDeletionStore,
                taskActions: TaskActions) {
        self.tasks = tasks; self.interactions = interactions; self.categories = categories
        self.logicalDay = logicalDay; self.settings = settings; self.statistics = statistics
        self.focusHistory = focusHistory; self.pendingDeletion = pendingDeletion; self.taskActions = taskActions
    }
}
