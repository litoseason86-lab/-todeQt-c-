import IPadCore
import SwiftUI

struct StatisticsView: View {
    @Environment(StatsStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(spacing: 20) {
                    Picker("时间范围", selection: Binding(get: { store.range }, set: { store.selectRange($0) })) {
                        ForEach(StatisticsRange.allCases, id: \.self) { range in Text(range.title).tag(range) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: wide ? 360 : .infinity).frame(maxWidth: .infinity)
                    HStack {
                        Button { store.movePeriod(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("上一周期").disabled(!store.hasLoaded)
                        Spacer()
                        Button(store.periodTitle) { store.returnToCurrentPeriod() }.font(.headline).frame(minHeight: 44)
                            .accessibilityHint("返回当前周期")
                        Spacer()
                        Button { store.movePeriod(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("下一周期").disabled(!store.snapshot.period.canAdvance)
                    }
                    if !store.errorMessage.isEmpty {
                        HStack(alignment: .top) {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Spacer(); Button("重试") { store.refresh() }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: wide ? 3 : 1), spacing: 16) {
                        ForEach(store.snapshot.cards) { card in StatisticsCardView(card: card) }
                    }
                    if store.isEmpty { Text("本周期还没有专注记录").foregroundStyle(ThemeColors.inkSoft) }
                    StatisticsBarChart(bars: store.snapshot.bars, title: store.snapshot.range == .month ? "月内专注趋势" : "所在周专注趋势")
                    if wide && store.showReview {
                        HStack(alignment: .top, spacing: 20) {
                            WeeklyReviewCard(review: store.snapshot.review, errorMessage: store.reviewErrorMessage).frame(maxWidth: .infinity)
                            StatisticsPieChart(categories: store.snapshot.categories.categories).frame(maxWidth: .infinity)
                        }
                    } else {
                        if store.showReview { WeeklyReviewCard(review: store.snapshot.review, errorMessage: store.reviewErrorMessage) }
                        StatisticsPieChart(categories: store.snapshot.categories.categories)
                    }
                }.padding(20)
            }
        }
        .foregroundStyle(ThemeColors.ink)
        .navigationTitle("数据统计")
        .onAppear { store.setActive(true) }
        .onDisappear { store.setActive(false) }
    }
}
private struct StatisticsCardView: View {
    let card: StatisticsCard
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.title).font(.headline).foregroundStyle(ThemeColors.inkSoft)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(card.value).font(.largeTitle.bold()).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                    Text(card.unit).foregroundStyle(ThemeColors.inkSoft)
                }
                Text(card.subtitle).font(.caption).foregroundStyle(ThemeColors.inkSoft)
                // 比较为空仍预留一行，当前周隐藏比较时不会推动图表跳动。
                Text(card.comparison.isEmpty ? " " : card.comparison)
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(card.trend > 0 ? ThemeColors.success : card.trend < 0 ? ThemeColors.danger : ThemeColors.inkSoft)
                    .frame(minHeight: 20, alignment: .leading).accessibilityHidden(card.comparison.isEmpty)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
}
