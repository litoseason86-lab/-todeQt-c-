import IPadCore
import SwiftUI

// 网格仅自绘几何，点击和长按使用系统手势，竖滑由 ScrollView 接管。
@MainActor struct WeekGrid: View {
    let store: ScheduleStore
    let weekdays: [Int]
    let add: (Int, Int) -> Void
    let edit: (ScheduleEntry) -> Void
    let delete: (ScheduleEntry) -> Void
    @ScaledMetric(relativeTo: .body) private var minuteHeight = 1.1
    @ScaledMetric(relativeTo: .body) private var rowHeight = 72.0
    var body: some View {
        GeometryReader { geometry in
            let gutter = 52.0
            let width = max(1, (geometry.size.width - gutter) / Double(weekdays.count))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutter, height: 48)
                    ForEach(weekdays, id: \.self) { day in
                        let today = store.weekIndex == store.currentWeekIndex && store.todayWeekday == day
                        VStack(spacing: 2) {
                            Text("周" + ScheduleView.weekdayName(day)).font(.headline)
                            if let date = ScheduleFormat.displayDate(store.dateForWeekday(day)) {
                                Text(date, format: .dateTime.month(.defaultDigits).day()).font(.caption)
                            }
                        }.frame(width: width, height: 48)
                            .foregroundStyle(today ? ThemeColors.accentInk : ThemeColors.ink)
                            .background(today ? ThemeColors.accentSoft : ThemeColors.surface)
                            .accessibilityLabel("周" + ScheduleView.weekdayName(day) + (today ? "，今天" : ""))
                    }
                }
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        axis.frame(width: gutter)
                        ForEach(weekdays, id: \.self) { day in
                            dayColumn(day, width: width).frame(width: width, height: contentHeight)
                        }
                    }.padding(.top, 8).padding(.bottom, 8)
                }.background(ThemeColors.surface)
            }
        }
    }
    private var contentHeight: Double {
        if store.displayMode == .period { return max(rowHeight, Double(store.periods.count) * (rowHeight + 4) - 4) }
        let axisHeight = Double(store.axisEndMinutes - store.axisStartMinutes) * minuteHeight
        let ends = weekdays.flatMap { store.layout(weekday: $0, pixelsPerMinute: minuteHeight, periodRowHeight: rowHeight) }
            .map { $0.top + $0.height }
        return max(axisHeight, ends.max() ?? 0)
    }
    @ViewBuilder private var axis: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(height: contentHeight)
            if store.displayMode == .time {
                ForEach(Array(stride(from: store.axisStartMinutes, through: store.axisEndMinutes, by: 60)), id: \.self) { minute in
                    Text(ScheduleFormat.formatMinutes(Double(minute))).font(.caption2).monospacedDigit()
                        .foregroundStyle(ThemeColors.inkSoft).padding(.trailing, 6)
                        .offset(y: Double(minute - store.axisStartMinutes) * minuteHeight)
                }
            } else {
                ForEach(Array(store.periods.enumerated()), id: \.offset) { index, period in
                    VStack {
                        Text("\(period.index)")
                        Text(ScheduleFormat.formatMinutes(Double(period.startMinutes)))
                    }.font(.caption2).monospacedDigit().foregroundStyle(ThemeColors.inkSoft).padding(.trailing, 6)
                        .offset(y: Double(index) * (rowHeight + 4))
                }
            }
        }
    }
    private func dayColumn(_ day: Int, width: Double) -> some View {
        let placements = store.layout(weekday: day, pixelsPerMinute: minuteHeight, periodRowHeight: rowHeight)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(store.weekIndex == store.currentWeekIndex && store.todayWeekday == day ? ThemeColors.accentSoft : ThemeColors.surface).overlay(alignment: .leading) { Rectangle().fill(ThemeColors.borderSubtle).frame(width: 1) }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    add(day, store.minutesAtOffset(location.y, pixelsPerMinute: minuteHeight, periodRowHeight: rowHeight))
                }.accessibilityLabel("周" + ScheduleView.weekdayName(day) + "，添加课程")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { add(day, 480) }
            ForEach(placements, id: \.entry.id) { item in
                let laneWidth = width / Double(max(1, item.laneCount))
                Button { edit(item.entry) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.entry.title).font(.callout).fontWeight(.semibold).lineLimit(2)
                        if !item.entry.location.isEmpty { Text(item.entry.location).font(.caption).lineLimit(2) }
                        Text(ScheduleFormat.formatMinutes(Double(item.entry.startMinutes)) + "–" + ScheduleFormat.formatMinutes(Double(item.entry.endMinutes)))
                            .font(.caption2).monospacedDigit().lineLimit(1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                        .foregroundStyle(ThemeColors.ink).background(TaskCategoryColor.value(item.entry.categoryColor).opacity(0.16))
                        .overlay(alignment: .leading) { Rectangle().fill(TaskCategoryColor.value(item.entry.categoryColor)).frame(width: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                    .frame(width: max(1, laneWidth - 4), height: item.height)
                    .offset(x: Double(item.lane) * laneWidth + 2, y: item.top)
                    .accessibilityLabel(item.entry.title + "，" + item.entry.location + "，" + ScheduleFormat.formatMinutes(Double(item.entry.startMinutes)))
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { edit(item.entry) }
                        Button("删除", systemImage: "trash", role: .destructive) { delete(item.entry) }
                    }
            }
            if store.weekIndex == store.currentWeekIndex && store.todayWeekday == day {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    // 本地时钟仅画当前时间线，不决定课程或逻辑今日；不另建业务定时器。
                    let components = Calendar.current.dateComponents([.hour, .minute], from: context.date)
                    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                    if let top = store.currentTimeTop(minutes: minute, pixelsPerMinute: minuteHeight, periodRowHeight: rowHeight) {
                        Rectangle().fill(ThemeColors.danger).frame(height: 2).offset(y: top)
                            .accessibilityLabel("当前时间，" + ScheduleFormat.formatMinutes(Double(minute)))
                    }
                }.allowsHitTesting(false)
            }
        }
    }
}
