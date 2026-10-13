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
    public let trash: any TrashBridgeProtocol
    public let sync: any SyncBridgeProtocol
    public let backup: any BackupBridgeProtocol
    public let export: any ExportBridgeProtocol
    public let routines: any RoutineBridgeProtocol
    public let pendingDeletion: PendingDeletionStore
    public let taskActions: TaskActions
    // 任务行的行内编辑全应用只有一行在编辑，各页共用这一份。
    public let inlineEditor: InlineTaskEditor
    public let weekStore: WeekStore
    public let timelineStore: TimelineStore
    public let scheduleStore: ScheduleStore
    public init(tasks: any TaskBridgeProtocol, interactions: any InteractionBridgeProtocol,
                categories: any CategoryBridgeProtocol, logicalDay: any LogicalDayBridgeProtocol,
                settings: any SettingsBridgeProtocol, statistics: any StatisticsBridgeProtocol,
                focusHistory: any FocusHistoryBridgeProtocol, pendingDeletion: PendingDeletionStore,
                taskActions: TaskActions, inlineEditor: InlineTaskEditor, weekStore: WeekStore, timelineStore: TimelineStore,
                scheduleStore: ScheduleStore, trash: any TrashBridgeProtocol,
                sync: any SyncBridgeProtocol, backup: any BackupBridgeProtocol,
                export: any ExportBridgeProtocol, routines: any RoutineBridgeProtocol) {
        self.tasks = tasks; self.interactions = interactions; self.categories = categories
        self.logicalDay = logicalDay; self.settings = settings; self.statistics = statistics
        self.focusHistory = focusHistory; self.pendingDeletion = pendingDeletion; self.taskActions = taskActions
        self.inlineEditor = inlineEditor
        self.weekStore = weekStore; self.timelineStore = timelineStore; self.scheduleStore = scheduleStore
        self.trash = trash; self.sync = sync; self.backup = backup; self.export = export; self.routines = routines
    }
}
