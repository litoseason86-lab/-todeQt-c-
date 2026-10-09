import IPadCore
import SwiftUI

// P4 各计划只替换归属页面的分支，外壳不随页面功能增加而重新分发。
@MainActor enum PageRegistry {
    @ViewBuilder static func view(for page: PageID) -> some View {
        switch page {
        case .today: placeholder(.today)
        case .focus: placeholder(.focus)
        case .week: placeholder(.week)
        case .dashboard: placeholder(.dashboard)
        case .knowledgeGap: placeholder(.knowledgeGap)
        case .todayFocus: placeholder(.todayFocus)
        case .schedule: placeholder(.schedule)
        case .monthGoal: HistoryView()
        case .statistics: placeholder(.statistics)
        case .countdown: placeholder(.countdown)
        case .memo: placeholder(.memo)
        case .trash: placeholder(.trash)
        case .settings: placeholder(.settings)
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
