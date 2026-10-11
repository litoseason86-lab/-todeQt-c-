import IPadCore
import SwiftUI

struct WeeklyReviewCard: View {
    let review: WeeklyReview?
    let errorMessage: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(review?.periodState == "current" ? "本周概览" : "所选周复盘").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ThemeColors.inkStrong)
                if review?.periodState == "current" {
                    Text("进行中").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(ThemeColors.accentFillInk).background(ThemeColors.accentFill, in: Capsule())
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
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }
    @ViewBuilder private func today(_ review: WeeklyReview) -> some View {
        if let today = review.todayGoal, today.goalMinutes > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("今日进度").font(.system(size: 14)).foregroundStyle(ThemeColors.inkSoft)
                Text(StatisticsFormat.reviewSeconds(Double(today.actualSeconds)) + " / "
                     + StatisticsFormat.reviewMinutes(Double(today.goalMinutes))).font(.headline).monospacedDigit()
                // 进度直接来自服务，系统进度条处理超过目标的显示范围，不在 Swift 重算比例。
                ProgressBar(percent: today.progressPercent)
            }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private func goal(_ review: WeeklyReview) -> some View {
        if let goal = review.goal, goal.goalDays > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("目标达成").font(.system(size: 14)).foregroundStyle(ThemeColors.inkSoft)
                Text("\(goal.metDays) / \(goal.goalDays) 天").font(.headline).monospacedDigit()
            }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private func planned(_ review: WeeklyReview) -> some View {
        if let planned = review.plannedTasks, !planned.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("预计用时任务").font(.system(size: 14)).foregroundStyle(ThemeColors.inkSoft)
                Text("预计 " + StatisticsFormat.reviewMinutes(Double(planned.totalPlannedMinutes))
                     + " · 实际 " + StatisticsFormat.reviewSeconds(Double(planned.totalActualSeconds))).font(.headline)
            }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
        }
    }
}
