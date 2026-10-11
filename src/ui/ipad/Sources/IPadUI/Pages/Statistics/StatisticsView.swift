import IPadCore
import SwiftUI

struct StatisticsView: View {
    @Environment(StatsStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("数据统计").font(.largeTitle.bold())
                        Text(store.periodSubtitle).font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                    }
                    Picker("时间范围", selection: Binding(get: { store.range }, set: { store.selectRange($0) })) {
                        ForEach(StatisticsRange.allCases, id: \.self) { range in Text(range.segmentTitle).tag(range) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: wide ? 300 : .infinity).frame(maxWidth: .infinity)
                    if !store.errorMessage.isEmpty {
                        HStack(alignment: .top) {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Spacer(); Button("重试") { store.refresh() }
                        }
                    }
                    HStack(alignment: .top, spacing: wide ? 16 : 8) {
                        ForEach(store.snapshot.cards) { card in StatisticsCardView(card: card, compact: !wide) }
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            StatisticsBarChart(store: store).frame(width: (geometry.size.width - 84) * 2 / 3)
                            StatisticsPieChart(store: store).frame(maxWidth: .infinity)
                        }
                    } else {
                        StatisticsBarChart(store: store)
                        StatisticsPieChart(store: store)
                    }
                    if store.showReview {
                        WeeklyReviewCard(review: store.snapshot.review, errorMessage: store.reviewErrorMessage)
                    }
                }
                .padding(.horizontal, wide ? 32 : 16).padding(.vertical, 16)
            }
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("上一周期", systemImage: "chevron.left") { store.movePeriod(-1) }
                    .labelStyle(.iconOnly).disabled(!store.hasLoaded)
                Button("下一周期", systemImage: "chevron.right") { store.movePeriod(1) }
                    .labelStyle(.iconOnly).disabled(!store.snapshot.period.canAdvance)
            }
        }
        .onAppear { store.setActive(true) }.onDisappear { store.setActive(false) }
    }
}
private struct StatisticsCardView: View {
    let card: StatisticsCard
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title).font(compact ? .caption : .subheadline).foregroundStyle(ThemeColors.inkMuted)
                .lineLimit(2).frame(minHeight: compact ? 28 : 20, alignment: .topLeading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(card.value).font(compact ? .title2.bold() : .largeTitle.bold()).monospacedDigit()
                Text(card.unit).font(compact ? .caption : .subheadline).foregroundStyle(ThemeColors.inkSoft)
            }.lineLimit(1).minimumScaleFactor(0.6)
            if !card.subtitle.isEmpty {
                Text(card.subtitle).font(.caption).foregroundStyle(ThemeColors.inkSoft).lineLimit(2)
            }
            // 比较为空仍预留位置，当前周期与结束周期切换不推动下面图表跳动。
            Text(card.comparison.isEmpty ? " " : card.comparison)
                .font(.caption).lineLimit(2).foregroundStyle(card.trend > 0 ? ThemeColors.success : card.trend < 0 ? ThemeColors.danger : ThemeColors.inkSoft)
                .frame(minHeight: 32, alignment: .topLeading).accessibilityHidden(card.comparison.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 12 : 20)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}
