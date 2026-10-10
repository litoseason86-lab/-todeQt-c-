import Charts
import IPadCore
import SwiftUI

struct StatisticsBarChart: View {
    let bars: [StatisticsBar]
    let title: String
    @State private var selectedLabel: String?
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                if bars.isEmpty { Text("暂无趋势数据").foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity, minHeight: 180) }
                else {
                    Chart(bars) { bar in
                        BarMark(x: .value("日期", bar.label), y: .value("专注时长（秒）", bar.seconds))
                            .foregroundStyle(ThemeColors.accent)
                            .annotation(position: .top) {
                                Button { selectedLabel = bar.label } label: { Text(StatisticsFormat.formatDuration(Double(bar.seconds))).font(.caption2) }
                                    .buttonStyle(.plain).foregroundStyle(ThemeColors.ink)
                            }
                            .accessibilityLabel(bar.label)
                            .accessibilityValue(StatisticsFormat.formatDuration(Double(bar.seconds)))
                    }
                    .chartXSelection(value: $selectedLabel)
                    // ChartProxy（系统图表坐标代理）负责命中轴值，Swift 不按秒数重排或计算统计总量。
                    .chartGesture { proxy in
                        SpatialTapGesture().onEnded { value in proxy.selectXValue(at: value.location.x) }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let seconds = value.as(Int.self) { Text(StatisticsFormat.formatDuration(Double(seconds))).foregroundStyle(ThemeColors.inkSoft) }
                            }
                        }
                    }
                    .frame(height: 230)
                    .accessibilityLabel(title)
                    if let selectedLabel, let selected = bars.first(where: { $0.label == selectedLabel }) {
                        Text(selected.label + " · " + StatisticsFormat.formatDuration(Double(selected.seconds))).font(.headline)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: bars) { selectedLabel = nil }
    }
}
struct StatisticsPieChart: View {
    let categories: [CategoryStatisticsRow]
    @State private var selectedIndex: Int?
    private let palette = [ThemeColors.chartColors0, ThemeColors.chartColors1, ThemeColors.chartColors2,
                           ThemeColors.chartColors3, ThemeColors.chartColors4, ThemeColors.chartColors5]
    var body: some View {
        GroupBox("科目分配") {
            VStack(alignment: .leading, spacing: 12) {
                if categories.isEmpty { Text("暂无分布数据").foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity, minHeight: 180) }
                else {
                    Chart(Array(categories.enumerated()), id: \.offset) { item in
                        SectorMark(angle: .value("专注时长（秒）", item.element.duration), innerRadius: .ratio(0.55), angularInset: 2)
                            .foregroundStyle(palette[item.offset % palette.count])
                            .opacity(selectedIndex == nil || selectedIndex == item.offset ? 1 : 0.5)
                            .annotation(position: .overlay) {
                                // 点系统扇区上的标注或下方图例选择读数，不在 Swift 累加角度区间与统计总量。
                                Button { selectedIndex = item.offset } label: {
                                    Text(item.element.name).font(.caption2).lineLimit(1).padding(4)
                                        .foregroundStyle(ThemeColors.ink).background(ThemeColors.surfaceRaised, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                            .accessibilityLabel(item.element.name)
                            .accessibilityValue(readout(item.element))
                    }
                    .frame(height: 230).chartLegend(.hidden).accessibilityLabel("科目专注分配")
                    if let index = selectedIndex, categories.indices.contains(index) {
                        Text(categories[index].name + " · " + readout(categories[index])).font(.headline)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    ForEach(Array(categories.enumerated()), id: \.offset) { item in
                        Button { selectedIndex = item.offset } label: {
                            HStack(alignment: .top) {
                                Image(systemName: "circle.fill").foregroundStyle(palette[item.offset % palette.count]).accessibilityHidden(true)
                                Text(item.element.name)
                                Spacer()
                                Text(readout(item.element)).monospacedDigit()
                            }.frame(minHeight: 44, alignment: .center).foregroundStyle(ThemeColors.ink)
                        }
                        .buttonStyle(.plain).accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selectedIndex == item.offset ? .isSelected : [])
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: categories) { selectedIndex = nil }
    }
    private func readout(_ category: CategoryStatisticsRow) -> String {
        StatisticsFormat.formatDuration(Double(category.duration)) + " · " + StatisticsFormat.percent(category.percentage)
    }
}
