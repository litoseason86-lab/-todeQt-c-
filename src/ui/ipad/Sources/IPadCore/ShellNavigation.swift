import Foundation

public enum ShellWindowSize: Sendable {
    case compact
    case regular
}

public enum ShellNavigationTarget: Equatable, Sendable {
    case page(PageID)
    case more(path: [PageID])
}

public enum PageID: String, CaseIterable, Hashable, Sendable, Codable {
    case today, focus, week, dashboard, todayFocus, schedule
    case knowledgeGap = "knowledgeGaps"
    case monthGoal = "month"
    case statistics = "stats"
    case countdown, memo, trash, settings

    public func tabTitle(size: ShellWindowSize) -> String {
        switch self {
        case .focus: "专注"
        case .week: "本周"
        case .todayFocus where size == .compact: "记录"
        default: title
        }
    }

    public var title: String {
        switch self {
        case .today: "今日任务"
        case .focus: "专注计时"
        case .week: "本周计划"
        case .dashboard: "仪表盘"
        case .knowledgeGap: "知识缺口"
        case .todayFocus: "今日专注"
        case .schedule: "课表"
        case .monthGoal: "专注历史"
        case .statistics: "数据统计"
        case .countdown: "目标倒计时"
        case .memo: "备忘录"
        case .trash: "废纸篓"
        case .settings: "设置"
        }
    }

    // 宽窗侧栏收起后顶部只放这三页，按此顺序（10-12 用户定）；侧栏展开时它们也常驻列表，
    // 专注因此和摘要块里的「专注计时」并存——收起、展开都不再切换任何标签的可见性。
    public static let collapsedBarTabs: [Self] = [.dashboard, .focus, .todayFocus]
    // 只从侧栏摘要块进入的页：侧栏列表和收起后的顶部都不放。
    public static let tileOnlyTabs: [Self] = [.today, .week]
    public static let regularTabs: [Self] = collapsedBarTabs + tileOnlyTabs
    public static let primary: [Self] = [.today, .focus, .todayFocus, .dashboard]
    public static let summary: [Self] = [.today, .focus, .week, .countdown]
    public static let fixed: [Self] = [.trash, .settings]
    public static let defaultOrder: [Self] = [
        .dashboard, .today, .todayFocus, .focus, .schedule, .week,
        .monthGoal, .statistics, .countdown, .knowledgeGap, .memo
    ]

    // 存量设置可能遗漏或含未知页名；只整理展示顺序，固定入口永远排在最后。
    public static func ordered(_ ids: [String]) -> [Self] {
        var result: [Self] = []
        for id in ids {
            if let page = Self(rawValue: id), !fixed.contains(page), !result.contains(page) {
                result.append(page)
            }
        }
        result += defaultOrder.filter { !result.contains($0) }
        return result + fixed
    }
}
