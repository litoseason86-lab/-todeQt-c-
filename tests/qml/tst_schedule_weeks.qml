import QtQuick
import QtTest
import "../../qml/ScheduleWeeks.js" as ScheduleWeeks
import "CaliberFixtures.js" as Fixtures

// 课表的日期 ↔ 周次换算与重叠排布。这层是纯函数，不需要拉起视图，
// 因此单独成一条用例：它跑得快，坏掉时指向也最明确。
TestCase {
    id: testCase
    name: "ScheduleWeeks"

    function test_formatAndParseMinutesRoundTrip() {
        compare(ScheduleWeeks.formatMinutes(0), "00:00")
        compare(ScheduleWeeks.formatMinutes(8 * 60), "08:00")
        compare(ScheduleWeeks.formatMinutes(9 * 60 + 40), "09:40")
        compare(ScheduleWeeks.formatMinutes(24 * 60), "24:00")

        compare(ScheduleWeeks.parseMinutes("08:00"), 480)
        compare(ScheduleWeeks.parseMinutes("9:40"), 580)
        compare(ScheduleWeeks.parseMinutes(" 14:05 "), 845)
        // 允许 24:00 表示一天末尾，但不许越界。
        compare(ScheduleWeeks.parseMinutes("24:00"), 1440)
        compare(ScheduleWeeks.parseMinutes("24:30"), -1)
        compare(ScheduleWeeks.parseMinutes("25:00"), -1)
        compare(ScheduleWeeks.parseMinutes("08:60"), -1)
        compare(ScheduleWeeks.parseMinutes("0800"), -1)
        compare(ScheduleWeeks.parseMinutes(""), -1)
    }

    function test_weekRangeLabelOmitsNoiseForFullSemester() {
        // 覆盖整学期且每周都上的课不需要这句话。
        compare(ScheduleWeeks.weekRangeLabel(1, 20, 0, 20), "")
        compare(ScheduleWeeks.weekRangeLabel(1, 20, 1, 20), "单周")
        compare(ScheduleWeeks.weekRangeLabel(1, 8, 0, 20), "第 1-8 周")
        compare(ScheduleWeeks.weekRangeLabel(3, 3, 0, 20), "第 3 周")
        compare(ScheduleWeeks.weekRangeLabel(1, 8, 2, 20), "第 1-8 周 · 双周")
    }

    function test_layoutKeepsNonOverlappingEntriesFullWidth() {
        var entries = [
            { id: 1, startMinutes: 480, endMinutes: 540 },
            { id: 2, startMinutes: 600, endMinutes: 660 }
        ]
        var laid = ScheduleWeeks.layoutDayEntries(entries)
        compare(laid.length, 2)
        for (var i = 0; i < laid.length; ++i) {
            compare(laid[i].lane, 0)
            compare(laid[i].laneCount, 1)
        }
    }

    function test_layoutSplitsOverlappingEntriesIntoLanes() {
        var entries = [
            { id: 1, startMinutes: 480, endMinutes: 600 },
            { id: 2, startMinutes: 540, endMinutes: 660 }
        ]
        var laid = ScheduleWeeks.layoutDayEntries(entries)
        compare(laid.length, 2)
        // 两块重叠必须并排，否则后画的那块会把前一块完全盖死。
        compare(laid[0].laneCount, 2)
        compare(laid[1].laneCount, 2)
        verify(laid[0].lane !== laid[1].lane)
    }

    function test_layoutTreatsTouchingEntriesAsSeparate() {
        // 09:40 结束接 09:40 开始是连堂，不算重叠，不该被压成半宽。
        var laid = ScheduleWeeks.layoutDayEntries([
            { id: 1, startMinutes: 480, endMinutes: 580 },
            { id: 2, startMinutes: 580, endMinutes: 680 }
        ])
        compare(laid[0].laneCount, 1)
        compare(laid[1].laneCount, 1)
    }

    function test_layoutKeepsClustersIndependent() {
        // 上午两门重叠，不该把下午那门无关的课也压成半宽。
        var laid = ScheduleWeeks.layoutDayEntries([
            { id: 1, startMinutes: 480, endMinutes: 600 },
            { id: 2, startMinutes: 540, endMinutes: 660 },
            { id: 3, startMinutes: 840, endMinutes: 900 }
        ])
        compare(laid.length, 3)
        var afternoon = null
        for (var i = 0; i < laid.length; ++i) {
            if (laid[i].entry.id === 3) {
                afternoon = laid[i]
            }
        }
        verify(afternoon !== null)
        compare(afternoon.laneCount, 1)
        compare(afternoon.lane, 0)
    }

    function test_layoutReusesFreedLane() {
        // 第三门在第一门结束后开始，应该回收第一门的泳道而不是再开一条。
        var laid = ScheduleWeeks.layoutDayEntries([
            { id: 1, startMinutes: 480, endMinutes: 540 },
            { id: 2, startMinutes: 500, endMinutes: 700 },
            { id: 3, startMinutes: 560, endMinutes: 620 }
        ])
        compare(laid.length, 3)
        for (var i = 0; i < laid.length; ++i) {
            compare(laid[i].laneCount, 2)
        }
    }

    function test_layoutHandlesEmptyInput() {
        compare(ScheduleWeeks.layoutDayEntries([]).length, 0)
        compare(ScheduleWeeks.layoutDayEntries(null).length, 0)
    }

    function test_visualLayoutUsesFinalDrawnIntervals() {
        var laid = ScheduleWeeks.layoutVisualEntries([
            { entry: { id: 1 }, top: 0, height: 24, layoutStart: 0, layoutEnd: 24 },
            { entry: { id: 2 }, top: 9, height: 24, layoutStart: 9, layoutEnd: 33 }
        ])
        compare(laid.length, 2)
        compare(laid[0].laneCount, 2)
        compare(laid[1].laneCount, 2)
        verify(laid[0].lane !== laid[1].lane)
        compare(laid[0].top, 0)
        compare(laid[1].height, 24)
    }

    // overlaps 是课表里唯一的相交判据（课程块落在哪几节、哪些项一节都落不进、
    // 节次表自身能不能重叠都用它）。它只有一行，出错也只会在边界上现形：
    // 把 < 写成 <= 的话，08:00–08:45 与 08:45–09:30 这对紧邻的节次会被判成重叠，
    // 而中间那些明显相交的用例照样通过。所以边界必须单独钉住。
    function test_overlapsIsHalfOpen() {
        // 紧邻不算相交，两个方向都要成立。
        verify(!scheduleCalibers.overlaps(480, 525, 525, 570))
        verify(!scheduleCalibers.overlaps(525, 570, 480, 525))
        // 完全不挨着。
        verify(!scheduleCalibers.overlaps(480, 525, 600, 645))
        // 只差一分钟也算相交。
        verify(scheduleCalibers.overlaps(480, 526, 525, 570))
        // 包含关系两个方向都算相交。
        verify(scheduleCalibers.overlaps(480, 700, 540, 570))
        verify(scheduleCalibers.overlaps(540, 570, 480, 700))
        // 完全重合。
        verify(scheduleCalibers.overlaps(480, 525, 480, 525))
        // 字符串入参也要按数字比，绑定里传进来的常常是未转换的模型值。
        verify(scheduleCalibers.overlaps("480", "600", "540", "570"))
    }
    // 周次、自然星期和紧邻时段的现有口径必须与跨端对照表一致。
    function test_fixtureWeeks() {
        var rows = Fixtures.load("schedule-weeks")
        for (var i = 0; i < rows.length; ++i) {
            var input = rows[i].input
            var result
            switch (input.op) {
            case "mondayOf": result = scheduleCalibers.mondayOf(input.date); break
            case "parseSemesterStart": result = scheduleCalibers.parseSemesterStart(input.start); break
            case "weekIndexForDate": result = scheduleCalibers.weekIndexForDate(input.start, input.date); break
            case "mondayOfWeek": result = scheduleCalibers.mondayOfWeek(input.start, input.week); break
            case "dateOfWeekday": result = scheduleCalibers.dateOfWeekday(input.start, input.week, input.weekday); break
            case "overlaps": result = scheduleCalibers.overlaps(input.aStart, input.aEnd, input.bStart, input.bEnd); break
            default: fail("未知操作 " + input.op)
            }
            if (result === "") result = null
            compare(result, rows[i].expected, rows[i].reason)
        }
    }
}
