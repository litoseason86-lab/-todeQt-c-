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
                    Text(weekday).scaledSystemFont(size: 12).foregroundStyle(ThemeColors.inkSoft).frame(maxWidth: .infinity)
                }
            }.accessibilityHidden(true)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.cells) { cell in
                    if let date = cell.date {
                        HistoryDateCell(cell: cell, date: date, compact: compact,
                                        selected: store.isSelected(cell), store: store).equatable()
                    } else { Color.clear.frame(minHeight: compact ? 58 : 88).accessibilityHidden(true) }
                }
            }
        }
        // 横向滑动只在月历上识别；竖向交给整页 ScrollView，窄窗摘要可继续向下滚动。
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 50 else { return }
            store.moveMonth(value.translation.width < 0 ? 1 : -1)
        })
    }
}

// 日期格的数值、选中态没有变化时不重建文字和 ViewThatFits（按可用宽度选择单行或两行）。
// 日期选择只影响旧、新两格；颜色、字号等环境仍由 SwiftUI 向下传播，不缓存绘制结果。
private struct HistoryDateCell: View, Equatable {
    let cell: HistoryDay
    let date: String
    let compact: Bool
    let selected: Bool
    let store: HistoryStore
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cell == rhs.cell && lhs.compact == rhs.compact && lhs.selected == rhs.selected && lhs.store === rhs.store
    }
    var body: some View {
        let duration = cell.future ? "" : store.durationText(cell.seconds)
        return Button { store.select(date) } label: {
            // 定稿格子：左上日期，底部一条投入条；选中日浅焦糖底，今天焦糖描边与焦糖日期，二者独立。
            VStack(alignment: .leading, spacing: 0) {
                Text("\(cell.day)").scaledSystemFont(size: 15, weight: cell.today || selected ? .semibold : .regular)
                    .foregroundStyle(cell.today ? ThemeColors.accentInk : (cell.future ? ThemeColors.inkMuted : ThemeColors.inkStrong))
                if !compact && !cell.future && cell.seconds >= 60 { dayTotal(duration) }
                Spacer(minLength: 8)
                // 只绘制投入条；未来与空轨道分开，选中态不覆盖档位颜色。没有自定义动画。
                if !cell.future { Capsule().fill(bandColor(cell.band)).frame(height: 6) }
                else { Color.clear.frame(height: 6).accessibilityHidden(true) }
            }
            .padding(compact ? 6 : 10).frame(maxWidth: .infinity, minHeight: compact ? 58 : 88, alignment: .topLeading)
            .background(selected ? ThemeColors.accentFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // 今天描边与选中底色是独立状态，选历史日不能把今天标记搬过去。
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cell.today ? ThemeColors.accentInk : .clear, lineWidth: 1.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(cell.future)
        .accessibilityLabel(date + (cell.today ? "，今天" : ""))
        .accessibilityValue(cell.future ? "未来日期" : duration)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    // 当天总专注（10-12 用户要求，只在宽窗显示：窄窗格子约 45 点宽放不下）。文字取服务的时长写法，
    // 格子够宽时一行「2小时5分」；侧栏展开时格子约 62 点宽放不下，在「小时」后折成两行，不缩字号。
    private func dayTotal(_ text: String) -> some View {
        let split = text.range(of: "小时").map { (String(text[..<$0.upperBound]), String(text[$0.upperBound...])) }
        return ViewThatFits(in: .horizontal) {
            Text(text).lineLimit(1)
            if let split, !split.1.isEmpty {
                VStack(alignment: .leading, spacing: 0) { Text(split.0); Text(split.1) }
            }
        }
        .scaledSystemFont(size: 12).monospacedDigit().foregroundStyle(ThemeColors.inkSoft)
        .padding(.top, 2)
        .accessibilityHidden(true)
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
