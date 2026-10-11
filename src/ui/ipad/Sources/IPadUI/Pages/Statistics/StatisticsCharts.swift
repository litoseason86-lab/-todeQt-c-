import Charts
import IPadCore
import SwiftUI

struct StatisticsBarChart: View {
    let store: StatsStore
    var body: some View {
        let bars = store.snapshot.bars
        let maxSeconds = bars.map(\.seconds).max() ?? 0
        // 纵轴写整小时（定稿 1h 2h 3h），刻度按最大值取 1、2、3… 小时一格，最多约四格。
        let stepHours = max(1, Int((Double(maxSeconds) / 3600 / 4).rounded(.up)))
        let ticks = Array(stride(from: 0, through: max(maxSeconds, stepHours * 3600), by: stepHours * 3600))
        VStack(alignment: .leading, spacing: 16) {
            Text("每日专注").font(.system(size: 16, weight: .semibold)).foregroundStyle(ThemeColors.inkStrong)
            Chart(bars) { bar in
                // 定稿：今天的柱子用焦糖强调色，其余浅焦糖；柱宽与圆角取系统默认。
                BarMark(x: .value("日期", bar.label), y: .value("专注时长（秒）", bar.seconds), width: .ratio(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(bar.today ? ThemeColors.accentInk : ThemeColors.accentStrong.opacity(0.55))
                    .accessibilityLabel(bar.date)
                    .accessibilityValue(StatisticsFormat.formatDuration(Double(bar.seconds)))
            }
            .chartXSelection(value: Binding(get: { store.selectedBarLabel }, set: { store.selectBar($0) }))
            // ChartProxy（系统图表坐标代理）负责命中轴值，Swift 不按秒数重排或计算统计总量。
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { value in proxy.selectXValue(at: value.location.x) }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine().foregroundStyle(ThemeColors.borderSubtle)
                    AxisValueLabel {
                        if let seconds = value.as(Int.self), seconds > 0 { Text("\(seconds / 3600)h").font(.system(size: 11)).foregroundStyle(ThemeColors.inkSoft) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            let today = bars.first(where: { $0.label == label })?.today == true
                            Text(label).font(.system(size: 12, weight: today ? .bold : .regular))
                                .foregroundStyle(today ? ThemeColors.accentInk : ThemeColors.inkSoft)
                        }
                    }
                }
            }
            .frame(height: 230).accessibilityLabel("每日专注")
            if let label = store.selectedBarLabel, let selected = bars.first(where: { $0.label == label }) {
                Text(selected.date + " · " + StatisticsFormat.formatDuration(Double(selected.seconds))).font(.subheadline)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }
}
struct StatisticsPieChart: View {
    let store: StatsStore
    private let palette = [ThemeColors.chartColors0, ThemeColors.chartColors1, ThemeColors.chartColors2,
                           ThemeColors.chartColors3, ThemeColors.chartColors4, ThemeColors.chartColors5]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("科目分配").font(.system(size: 16, weight: .semibold)).foregroundStyle(ThemeColors.inkStrong)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { ring; legend }
                VStack(alignment: .leading, spacing: 16) { ring.frame(maxWidth: .infinity); legend }
            }
            if let index = store.selectedCategoryIndex, store.snapshot.categories.categories.indices.contains(index) {
                let category = store.snapshot.categories.categories[index]
                Text(category.name + " · " + readout(category)).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }
    private var ring: some View {
        Chart(Array(store.snapshot.categories.categories.enumerated()), id: \.offset) { item in
            SectorMark(angle: .value("专注时长（秒）", item.element.duration), innerRadius: .ratio(0.65), angularInset: 2)
                .foregroundStyle(palette[item.offset % palette.count])
                .opacity(store.selectedCategoryIndex == nil || store.selectedCategoryIndex == item.offset ? 1 : 0.5)
                .annotation(position: .overlay) {
                    // 系统扇区标注提供点击目标，不累加角度区间；读数统一交 Store 保存。
                    Button { store.selectCategory(item.offset) } label: {
                        Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(item.element.name).accessibilityValue(readout(item.element))
                }
                .accessibilityLabel(item.element.name).accessibilityValue(readout(item.element))
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 3) {
                Text(StatisticsFormat.formatDuration(Double(store.snapshot.categories.totalDuration)))
                    .font(.system(size: 17, weight: .bold)).monospacedDigit().multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.7)
                Text("合计").font(.caption2).foregroundStyle(ThemeColors.inkMuted)
            }.frame(width: 80).allowsHitTesting(false)
        }
        .frame(width: 130, height: 130).accessibilityLabel("科目专注分配")
    }
    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(store.snapshot.categories.categories.enumerated()), id: \.offset) { item in
                Button { store.selectCategory(item.offset) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "circle.fill").font(.caption2)
                            .foregroundStyle(palette[item.offset % palette.count]).accessibilityHidden(true)
                        Text(item.element.name + " " + StatisticsFormat.percent(item.element.percentage))
                            .font(.subheadline).foregroundStyle(ThemeColors.ink)
                    }.frame(minHeight: 44, alignment: .center)
                }
                .buttonStyle(.plain).accessibilityLabel(item.element.name).accessibilityValue(readout(item.element))
                .accessibilityAddTraits(store.selectedCategoryIndex == item.offset ? .isSelected : [])
            }
        }.frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
    }
    private func readout(_ category: CategoryStatisticsRow) -> String {
        StatisticsFormat.formatDuration(Double(category.duration)) + " · " + StatisticsFormat.percent(category.percentage)
    }
}
