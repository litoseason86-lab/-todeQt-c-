import IPadCore
import SwiftUI

// P4 各计划只替换归属页面的分支，外壳不随页面功能增加而重新分发。
@MainActor enum PageRegistry {
    @ViewBuilder static func view(for page: PageID, core: CoreBridges, shell: ShellStore) -> some View {
        switch page {
        case .today: TodayView()
        case .focus: FocusView()
        case .week: WeekView(store: core.weekStore, actions: core.taskActions, core: core, shell: shell)
        case .dashboard: DashboardView()
        case .knowledgeGap: KnowledgeGapPage()
        case .todayFocus: TodayFocusView(store: core.timelineStore, shell: shell)
        case .schedule: ScheduleView(store: core.scheduleStore, categories: core.categories)
        case .monthGoal: HistoryView()
        case .statistics: StatisticsView()
        case .countdown: CountdownPage()
        case .memo: MemoPage()
        case .trash: TrashPage()
        case .settings: SettingsPage()
        }
    }
    private static func placeholder(_ page: PageID) -> some View {
        ContentUnavailableView(page.title, systemImage: page.symbol)
            .navigationTitle(page.title)
    }
}

extension PageID {
    var symbol: String {
        switch self {
        case .today: "checklist"
        case .focus: "timer"
        case .week: "calendar"
        case .dashboard: "square.grid.2x2"
        case .knowledgeGap: "pencil.and.list.clipboard"
        case .todayFocus: "clock"
        case .schedule: "tablecells"
        case .monthGoal: "calendar.badge.clock"
        case .statistics: "chart.bar"
        case .countdown: "flag"
        case .memo: "note.text"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }
}
