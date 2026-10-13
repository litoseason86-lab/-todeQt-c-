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
    // 055-R4 定稿：整张网格是一张白卡片；表头「周一 6」，今天那天日期是焦糖实心圆；整点细线、两小时一个刻度字。
    var body: some View {
        // 同一轮布局只给每一天排一次泳道（重叠课程的横向位置）；原来求整张网格高度时，
        // 轴、背景和七列各自又排了整周。高度和课程块共用本轮结果，不跨设置或字号变化缓存。
        let placements = Dictionary(uniqueKeysWithValues: weekdays.map { day in
            (day, store.layout(weekday: day, pixelsPerMinute: minuteHeight, periodRowHeight: rowHeight))
        })
        let axisStart = store.axisStartMinutes, axisEnd = store.axisEndMinutes
        let contentHeight = store.displayMode == .period
            ? max(rowHeight, Double(store.periods.count) * (rowHeight + 4) - 4)
            : max(Double(axisEnd - axisStart) * minuteHeight,
                  placements.values.flatMap { $0 }.map { $0.top + $0.height }.max() ?? 0)
        return GeometryReader { geometry in
            let gutter = 52.0
            let width = max(1, (geometry.size.width - gutter) / Double(weekdays.count))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutter, height: 44)
                    ForEach(weekdays, id: \.self) { day in
                        let today = store.weekIndex == store.currentWeekIndex && store.todayWeekday == day
                        HStack(spacing: 6) {
                            Text("周" + ScheduleView.weekdayName(day))
                            let number = Text(WeekView.day(store.dateForWeekday(day))).monospacedDigit()
                            if today {
                                number.font(.system(size: 13, weight: .bold)).foregroundStyle(ThemeColors.surface)
                                    .frame(width: 26, height: 26).background(ThemeColors.accentInk, in: Circle())
                            } else { number }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(today ? ThemeColors.accentInk : ThemeColors.ink)
                        .frame(width: width, height: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("周" + ScheduleView.weekdayName(day) + (today ? "，今天" : ""))
                    }
                }
                CardDivider()
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        axis(height: contentHeight, start: axisStart, end: axisEnd).frame(width: gutter)
                        ForEach(weekdays, id: \.self) { day in
                            dayColumn(day, width: width, placements: placements[day] ?? []).frame(width: width, height: contentHeight)
                        }
                    }
                    .background(alignment: .topLeading) { hourLines(height: contentHeight, start: axisStart, end: axisEnd).padding(.leading, gutter) }
                    .padding(.top, 8).padding(.bottom, 12)
                }
            }
            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        }
    }
    // 时间模式下每个整点一条细线，节次模式下每节一条。
    @ViewBuilder private func hourLines(height: Double, start: Int, end: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: height)
            if store.displayMode == .time {
                ForEach(Array(stride(from: start, through: end, by: 60)), id: \.self) { minute in
                    Rectangle().fill(ThemeColors.borderSubtle).frame(height: 1)
                        .offset(y: Double(minute - start) * minuteHeight)
                }
            } else {
                ForEach(0...store.periods.count, id: \.self) { index in
                    Rectangle().fill(ThemeColors.borderSubtle).frame(height: 1).offset(y: Double(index) * (rowHeight + 4) - 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
    @ViewBuilder private func axis(height: Double, start: Int, end: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(height: height)
            if store.displayMode == .time {
                ForEach(Array(stride(from: start, through: end, by: 120)), id: \.self) { minute in
                    Text(ScheduleFormat.formatMinutes(Double(minute))).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(ThemeColors.inkSoft).padding(.trailing, 6)
                        .offset(y: Double(minute - start) * minuteHeight - 7)
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
    private func dayColumn(_ day: Int, width: Double, placements: [SchedulePlacement<ScheduleEntry>]) -> some View {
        return ZStack(alignment: .topLeading) {
            // 今天那列浅焦糖底；列间一条细竖线。
            Rectangle().fill(store.weekIndex == store.currentWeekIndex && store.todayWeekday == day ? ThemeColors.accentFill.opacity(0.35) : Color.clear)
                .overlay(alignment: .leading) { Rectangle().fill(ThemeColors.borderSubtle).frame(width: 1) }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    add(day, store.minutesAtOffset(location.y, pixelsPerMinute: minuteHeight, periodRowHeight: rowHeight))
                }.accessibilityLabel("周" + ScheduleView.weekdayName(day) + "，添加课程")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { add(day, 480) }
            ForEach(placements, id: \.entry.id) { item in
                let laneWidth = width / Double(max(1, item.laneCount))
                Button { edit(item.entry) } label: {
                    // 定稿课程块：科目色浅底、左边 3 宽科目色条，课名 13 粗、地点与时间 11。
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        if !item.entry.location.isEmpty { Text(item.entry.location).font(.system(size: 11)).lineLimit(2) }
                        Text(ScheduleFormat.formatMinutes(Double(item.entry.startMinutes)) + "–" + ScheduleFormat.formatMinutes(Double(item.entry.endMinutes)))
                            .font(.system(size: 11)).monospacedDigit().lineLimit(1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 8).padding(.vertical, 6)
                        .foregroundStyle(ThemeColors.inkStrong)
                        .background(TaskCategoryColor.value(item.entry.categoryColor).opacity(0.18))
                        .overlay(alignment: .leading) { Rectangle().fill(TaskCategoryColor.value(item.entry.categoryColor)).frame(width: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        HStack(spacing: 0) {
                            Circle().fill(ThemeColors.danger).frame(width: 8, height: 8)
                            Rectangle().fill(ThemeColors.danger).frame(height: 2)
                        }
                        .offset(x: -4, y: top - 4)
                        .accessibilityLabel("当前时间，" + ScheduleFormat.formatMinutes(Double(minute)))
                    }
                }.allowsHitTesting(false)
            }
        }
    }
}
