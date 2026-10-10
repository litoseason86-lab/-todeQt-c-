import IPadCore
import SwiftUI

struct MonthGrid: View {
    let store: HistoryStore
    let compact: Bool
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(minimum: 0), spacing: compact ? 2 : 6), count: 7) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                    Text(weekday).font(.subheadline).foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity)
                }
            }.accessibilityHidden(true)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.cells) { cell in
                    if let date = cell.date {
                        Button { store.select(date) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(cell.day)").fontWeight(cell.today ? .bold : .regular)
                                if !compact && cell.seconds > 0 {
                                    Text(store.durationText(cell.seconds)).font(.caption).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                // 只绘制投入条；未来与空轨道分开，选中态不覆盖档位颜色。没有自定义动画。
                                if !cell.future { RoundedRectangle(cornerRadius: 3).fill(bandColor(cell.band)).frame(height: 8) }
                                else { Color.clear.frame(height: 8).accessibilityHidden(true) }
                            }
                            .padding(compact ? 6 : 8).frame(maxWidth: .infinity, minHeight: compact ? 64 : 84, alignment: .topLeading)
                            .foregroundStyle(ThemeColors.ink)
                            .background(store.isSelected(cell) ? ThemeColors.accentSoft : ThemeColors.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: 10))
                            // 今天描边与选中底色是独立状态，选历史日不能把今天标记搬过去。
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(cell.today ? ThemeColors.accentInk : .clear, lineWidth: 1.5) }
                        }
                        .buttonStyle(.plain).disabled(cell.future)
                        .accessibilityLabel(date + (cell.today ? "，今天" : ""))
                        .accessibilityValue(cell.future ? "未来日期" : store.durationText(cell.seconds))
                        .accessibilityAddTraits(store.isSelected(cell) ? .isSelected : [])
                    } else { Color.clear.frame(minHeight: compact ? 64 : 84).accessibilityHidden(true) }
                }
            }
        }
        // 横向滑动只在月历上识别；竖向交给整页 ScrollView，窄窗摘要可继续向下滚动。
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 50 else { return }
            store.moveMonth(value.translation.width < 0 ? 1 : -1)
        })
    }
    private func bandColor(_ band: Int) -> Color {
        switch band {
        case 0: ThemeColors.heatmapBandColors0
        case 1: ThemeColors.heatmapBandColors1
        case 2: ThemeColors.heatmapBandColors2
        case 3: ThemeColors.heatmapBandColors3
        default: ThemeColors.heatmapEmptyTrack
        }
    }
}
