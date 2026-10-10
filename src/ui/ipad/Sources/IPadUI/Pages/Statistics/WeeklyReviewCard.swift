import IPadCore
import SwiftUI

struct WeeklyReviewCard: View {
    let review: WeeklyReview?
    let errorMessage: String
    var body: some View {
        GroupBox(review?.periodState == "current" ? "本周概览" : "所选周复盘") {
            VStack(alignment: .leading, spacing: 16) {
                if !errorMessage.isEmpty {
                    Text("周统计加载失败").font(.headline).foregroundStyle(ThemeColors.danger)
                    Text(errorMessage).foregroundStyle(ThemeColors.inkSoft)
                } else if let review {
                    Text(review.weekStart + " 至 " + review.weekEnd).font(.caption).foregroundStyle(ThemeColors.inkSoft)
                    if let goal = review.goal, goal.goalDays > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("目标达成").font(.headline)
                            Text("\(goal.metDays) / \(goal.goalDays) 天").font(.title2.bold()).monospacedDigit()
                            Text("目标 " + StatisticsFormat.reviewMinutes(Double(goal.goalMinutesTotal))
                                 + " · 实际 " + StatisticsFormat.reviewSeconds(Double(goal.actualSecondsTotal)))
                                .foregroundStyle(ThemeColors.inkSoft)
                        }.accessibilityElement(children: .combine)
                    }
                    if let goal = review.todayGoal, goal.goalMinutes > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("今日进度").font(.headline)
                            Text(StatisticsFormat.percent(goal.progressPercent)).font(.title2.bold()).monospacedDigit()
                            Text("目标 " + StatisticsFormat.reviewMinutes(Double(goal.goalMinutes))
                                 + " · 实际 " + StatisticsFormat.reviewSeconds(Double(goal.actualSeconds)))
                                .foregroundStyle(ThemeColors.inkSoft)
                        }.accessibilityElement(children: .combine)
                    }
                    if let planned = review.plannedTasks, !planned.rows.isEmpty {
                        Divider()
                        HStack { Text("预计用时任务").font(.headline)
                            if planned.inProgress { Text("进行中").font(.caption).foregroundStyle(ThemeColors.inkSoft) }
                        }
                        Text(StatisticsFormat.reviewMinutes(Double(planned.totalActualDisplayMinutes)) + " / "
                             + StatisticsFormat.reviewMinutes(Double(planned.totalPlannedMinutes)))
                        if let ratio = planned.totalInvestmentRatioPercent { Text(StatisticsFormat.percent(ratio)).foregroundStyle(ThemeColors.accentInk) }
                        ForEach(Array(planned.rows.enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.element.subject).font(.headline)
                                Text(StatisticsFormat.reviewMinutes(Double(item.element.actualDisplayMinutes)) + " / "
                                     + StatisticsFormat.reviewMinutes(Double(item.element.plannedMinutes)))
                                Text(StatisticsFormat.signedMinutes(item.element.differenceDisplayMinutes) + " · "
                                     + StatisticsFormat.percent(item.element.investmentRatioPercent)).foregroundStyle(ThemeColors.inkSoft)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    // 事实选择和阈值留在 C++；只按登记类型排句子，未知类型得到空串而隐藏。
                    ForEach(Array(review.facts.enumerated()), id: \.offset) { item in
                        let text = StatisticsFormat.factText(item.element)
                        if !text.isEmpty { Text(text) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
