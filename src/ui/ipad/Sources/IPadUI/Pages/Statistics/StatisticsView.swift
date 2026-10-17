import IPadCore
import SwiftUI

struct StatisticsView: View {
    @Environment(StatsStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    // 副标题写「本周 · 10月6日 – 12日」（定稿）；周期起止与是否当前期都来自服务，这里只换成中文日期。
    private var subtitle: String {
        guard store.hasLoaded else { return "" }
        let period = store.snapshot.period
        guard !period.start.isEmpty else { return store.periodSubtitle }
        let dates = period.start == period.end ? WeekView.monthDay(period.start)
            : WeekView.monthDay(period.start) + " – " + (period.start.prefix(7) == period.end.prefix(7) ? WeekView.day(period.end) + "日" : WeekView.monthDay(period.end))
        return period.current ? store.snapshot.range.title + " · " + dates : dates
    }
    private var rangePicker: some View {
        Picker("时间范围", selection: Binding(get: { store.range }, set: { store.selectRange($0) })) {
            ForEach(StatisticsRange.allCases, id: \.self) { range in Text(range.segmentTitle).tag(range) }
        }
        .pickerStyle(.segmented)
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 定稿：标题在左，「日 | 周 | 月」胶囊分段在页面正中（沿用居中定案）。
                    ZStack(alignment: .top) {
                        PageHeader(title: "数据统计", subtitle: subtitle)
                        if wide { rangePicker.frame(width: 190).padding(.top, 8) }
                    }
                    if !wide { rangePicker.frame(maxWidth: .infinity) }
                    if !store.errorMessage.isEmpty {
                        HStack(alignment: .top) {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Spacer(); Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle())
                        }
                    }
                    // 三张卡等高：比较行留白时也不让卡片高低不齐。辅助字号下一行三张会把数字和比较截断，改为一张一行。
                    let cardLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 8))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: wide ? 16 : 8))
                    cardLayout {
                        ForEach(store.snapshot.cards) { card in StatisticsCardView(card: card, compact: !wide).frame(maxHeight: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
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
                .padding(.top, 4).padding(.bottom, 24)
            }
            .safeAreaPadding(.horizontal, wide ? Design.pageMargin(geometry: geometry, compact: false, maxWidth: 1150) : 16)
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
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
    // 定稿数字卡：标题 15、数字 30 粗配 15 的单位；副标题与比较各一行，比较为空也留行高。
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(card.title).scaledSystemFont(size: compact ? 13 : 15).foregroundStyle(ThemeColors.inkSoft)
                .lineLimit(2).frame(alignment: .topLeading)
            // 数字宁可缩小也不截断：最大辅助字号下 0.6 仍会截成「4.2…」。
            MixedNumberText(parts: valueParts, numberSize: compact ? 22 : 30, unitSize: compact ? 12 : 15)
                .lineLimit(1).minimumScaleFactor(0.3)
            if !card.subtitle.isEmpty {
                Text(card.subtitle).scaledSystemFont(size: 13).foregroundStyle(ThemeColors.inkSoft).lineLimit(2)
            }
            // 比较为空仍预留位置，当前周期与结束周期切换不推动下面图表跳动。
            Text(card.comparison.isEmpty ? " " : card.comparison)
                .scaledSystemFont(size: 13).lineLimit(2).foregroundStyle(card.trend > 0 ? ThemeColors.successInk : card.trend < 0 ? ThemeColors.danger : ThemeColors.inkSoft)
                .accessibilityHidden(card.comparison.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: compact ? 12 : 18, leading: compact ? 12 : 20, bottom: compact ? 12 : 16, trailing: compact ? 10 : 16))
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    // 服务给的值已带格式（「12.9」「2 / 7」「16」），单位另给；数值里的「小时」「分」等字也按小号排。
    private var valueParts: [(text: String, isNumber: Bool)] {
        let parts = card.value.contains(" / ")
            ? [(String(card.value.split(separator: "/").first ?? "").trimmingCharacters(in: .whitespaces), true), (" / " + (card.value.split(separator: "/").last.map(String.init) ?? "").trimmingCharacters(in: .whitespaces), false)]
            : MixedNumberText.split(card.value)
        return card.unit.isEmpty ? parts : parts + [(card.unit, false)]
    }
}
