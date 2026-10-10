import IPadCore
import SwiftUI

struct WeeklyReviewCard: View {
    let review: WeeklyReview?
    let errorMessage: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(review?.periodState == "current" ? "本周概览" : "所选周复盘").font(.headline)
                if review?.periodState == "current" {
                    Text("进行中").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(ThemeColors.accentInk).background(ThemeColors.accentSoft, in: Capsule())
                }
            }
            if !errorMessage.isEmpty {
                Text("周统计加载失败").font(.headline).foregroundStyle(ThemeColors.danger)
                Text(errorMessage).foregroundStyle(ThemeColors.inkSoft)
            } else if let review {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { today(review); goal(review); planned(review) }
                    VStack(alignment: .leading, spacing: 16) { today(review); goal(review); planned(review) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    @ViewBuilder private func today(_ review: WeeklyReview) -> some View {
        if let today = review.todayGoal, today.goalMinutes > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("今日进度").font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                Text(StatisticsFormat.reviewSeconds(Double(today.actualSeconds)) + " / "
                     + StatisticsFormat.reviewMinutes(Double(today.goalMinutes))).font(.headline).monospacedDigit()
                // 进度直接来自服务，系统进度条处理超过目标的显示范围，不在 Swift 重算比例。
                ProgressView(value: today.progressPercent, total: 100).tint(ThemeColors.accentFill)
            }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private func goal(_ review: WeeklyReview) -> some View {
        if let goal = review.goal, goal.goalDays > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("目标达成").font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                Text("\(goal.metDays) / \(goal.goalDays) 天").font(.headline).monospacedDigit()
            }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private func planned(_ review: WeeklyReview) -> some View {
        if let planned = review.plannedTasks, !planned.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("预计用时任务").font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                Text("预计 " + StatisticsFormat.reviewMinutes(Double(planned.totalPlannedMinutes))
                     + " · 实际 " + StatisticsFormat.reviewSeconds(Double(planned.totalActualSeconds))).font(.headline)
            }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
        }
    }
}
