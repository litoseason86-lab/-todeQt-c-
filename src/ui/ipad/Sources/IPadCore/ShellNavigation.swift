import Foundation
import Observation

public enum PageID: String, CaseIterable, Hashable, Sendable, Codable {
    case today, focus, week, dashboard, todayFocus, schedule
    case knowledgeGap = "knowledgeGaps"
    case monthGoal = "month"
    case statistics = "stats"
    case countdown, memo, trash, settings

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

    public static let primary: [Self] = [.today, .focus, .week, .dashboard]
    public static let summary: [Self] = [.today, .focus, .week, .knowledgeGap]
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

@MainActor @Observable
public final class ShellNavigation {
    public var selection: PageID
    public init(selection: PageID = .dashboard) { self.selection = selection }
}
