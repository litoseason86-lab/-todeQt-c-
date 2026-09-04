import QtQuick
import QtTest
import "../../qml/ScheduleWeeks.js" as ScheduleWeeks

// 课表的日期 ↔ 周次换算与重叠排布。这层是纯函数，不需要拉起视图，
// 因此单独成一条用例：它跑得快，坏掉时指向也最明确。
TestCase {
    id: testCase
    name: "ScheduleWeeks"

    function test_mondayOfSnapsBackToWeekStart() {
        // 2026-09-02 是周三，回退到 2026-08-31（周一）。
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.mondayOf(new Date(2026, 8, 2))),
                "2026-08-31")
        // 周一自身不动。
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.mondayOf(new Date(2026, 7, 31))),
                "2026-08-31")
        // 周日必须回退 6 天到本周周一，而不是前进到下周一。
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.mondayOf(new Date(2026, 8, 6))),
                "2026-08-31")
    }

    function test_parseSemesterStartNormalizesToMonday() {
        // 填周三也要对齐到该周周一，否则同一周内会被算成两个周次。
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.parseSemesterStart("2026-09-02")),
                "2026-08-31")
    }

    function test_parseSemesterStartRejectsBadInput() {
        compare(ScheduleWeeks.parseSemesterStart(""), null)
        compare(ScheduleWeeks.parseSemesterStart("   "), null)
        // 残缺串不能被 Date 猜成某个真实日期。
        compare(ScheduleWeeks.parseSemesterStart("2026-9"), null)
        compare(ScheduleWeeks.parseSemesterStart("2026/09/02"), null)
        // 2 月没有 31 号，Date 会静默进位到 3 月，必须挡住。
        compare(ScheduleWeeks.parseSemesterStart("2026-02-31"), null)
        compare(ScheduleWeeks.parseSemesterStart("not-a-date"), null)
    }

    function test_weekIndexCountsWholeWeeks() {
        var start = "2026-08-31"
        // 起始周内的任何一天都是第 1 周。
        compare(ScheduleWeeks.weekIndexForDate(start, new Date(2026, 7, 31)), 1)
        compare(ScheduleWeeks.weekIndexForDate(start, new Date(2026, 8, 6)), 1)
        // 跨过周一进入第 2 周。
        compare(ScheduleWeeks.weekIndexForDate(start, new Date(2026, 8, 7)), 2)
        compare(ScheduleWeeks.weekIndexForDate(start, new Date(2026, 8, 13)), 2)
        compare(ScheduleWeeks.weekIndexForDate(start, new Date(2026, 8, 14)), 3)
    }

    function test_weekIndexIsZeroWithoutAnchor() {
        // 算不出周次时返回 0，页面据此引导用户先设置学期起始日。
        compare(ScheduleWeeks.weekIndexForDate("", new Date(2026, 8, 2)), 0)
        compare(ScheduleWeeks.weekIndexForDate("坏值", new Date(2026, 8, 2)), 0)
    }

    function test_weekIndexBeforeSemesterIsNotPositive() {
        // 学期开始之前往前翻是正常操作，周次会 ≤ 0，由服务层返回空课表。
        verify(ScheduleWeeks.weekIndexForDate("2026-08-31", new Date(2026, 7, 24)) <= 0)
    }

    function test_mondayOfWeekAndDateOfWeekday() {
        var start = "2026-08-31"
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.mondayOfWeek(start, 1)), "2026-08-31")
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.mondayOfWeek(start, 3)), "2026-09-14")
        // weekday 1..7 = 周一..周日。
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.dateOfWeekday(start, 1, 3)), "2026-09-02")
        compare(ScheduleWeeks.isoDate(ScheduleWeeks.dateOfWeekday(start, 1, 7)), "2026-09-06")
        compare(ScheduleWeeks.mondayOfWeek("", 1), null)
    }

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
        verify(!ScheduleWeeks.overlaps(480, 525, 525, 570))
        verify(!ScheduleWeeks.overlaps(525, 570, 480, 525))
        // 完全不挨着。
        verify(!ScheduleWeeks.overlaps(480, 525, 600, 645))
        // 只差一分钟也算相交。
        verify(ScheduleWeeks.overlaps(480, 526, 525, 570))
        // 包含关系两个方向都算相交。
        verify(ScheduleWeeks.overlaps(480, 700, 540, 570))
        verify(ScheduleWeeks.overlaps(540, 570, 480, 700))
        // 完全重合。
        verify(ScheduleWeeks.overlaps(480, 525, 480, 525))
        // 字符串入参也要按数字比，绑定里传进来的常常是未转换的模型值。
        verify(ScheduleWeeks.overlaps("480", "600", "540", "570"))
    }
}
