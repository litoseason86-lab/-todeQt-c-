import Foundation
public enum GapFormat {
    // 只拼服务提供的到期事实，不比较日期；逾期天数不能被转任务清零。
    public static func meta(_ gap: GapValue) -> String {
        var parts = [gap.overdue ? "已逾期 \(gap.overdueDays) 天" : gap.dueToday ? "今天到期" : gap.scheduled ? gap.dueDate : "未排期"]
        if gap.priority == 2 { parts.append("高优先级") }
        if !gap.categoryName.isEmpty { parts.append(gap.categoryName) }
        if !gap.sourceTaskTitle.isEmpty { parts.append("来自：\(gap.sourceTaskTitle)") }
        return parts.joined(separator: " · ")
    }
}
