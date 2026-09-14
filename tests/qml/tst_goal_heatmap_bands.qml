import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"
import "../../qml/HeatmapBands.js" as HeatmapBands

// 目标详情页的月历热力（2026-09-14 定稿，规则见 docs/业务规则.md「热力取档与专注历史月历的投入条」）。
//
// 规则：正投入按绝对分钟数分四档，与专注历史月历共用 HeatmapBands.bandForMinutes；
// 不再相对当月最大值取强度，也不再叠 opacity。零值、今日、未来逐格按逻辑今日判：
// 过去零投入 = 零值底色「无投入」；今日零投入 = 零值底色 + 今日标记「今日暂无投入」；
// 未来 = 不填色 + Theme.border 1px 实描边「尚未到来」；本月之外 = 什么都没有。
//
// 服务层 dailyCounts 的 count 字段是**分钟**（GoalService 按 SUM(duration)/60 汇总），
// 不是番茄数。
TestCase {
    id: testCase
    name: "GoalHeatmapBands"
    when: windowShown
    // 像素断言要真的渲染出来；TestCase 默认不可见时 grabImage 是一张空图。
    visible: true
    width: 480
    height: 360

    GoalHeatmap {
        id: heatmap
        width: 420
        year: 2026
        month: 7
        today: new Date(2026, 6, 18)
        dailyCounts: []
    }

    function init() {
        Theme.activeThemeId = "warm"
        heatmap.year = 2026
        heatmap.month = 7
        heatmap.today = new Date(2026, 6, 18)
        heatmap.dailyCounts = []
    }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
    }

    function cell(day) {
        var found = findChild(heatmap, "goalHeatmapDay-" + day)
        verify(found !== null, "找不到 " + day + " 日的格子")
        return found
    }

    function dateText(day) {
        var found = findChild(heatmap, "goalHeatmapDayText-" + day)
        verify(found !== null, "找不到 " + day + " 日的日期文字")
        return found
    }

    function sameColor(actual, expected, message) {
        verify(Qt.colorEqual(actual, expected), message + "：实际 " + actual + "，预期 " + expected)
    }

    function test_positiveMinutesUseTheSignedOffBandFillAndInk() {
        heatmap.dailyCounts = [{ day: 1, count: 30 }, { day: 2, count: 90 },
                               { day: 3, count: 200 }, { day: 6, count: 400 }]
        var days = [1, 2, 3, 6]
        for (var i = 0; i < days.length; ++i) {
            var c = cell(days[i])
            compare(c.heatBand, i)
            sameColor(c.color, Theme.heatmapBandColors[i], days[i] + " 日底色")
            sameColor(dateText(days[i]).color, Theme.heatmapBandInkColors[i], days[i] + " 日字色")
            compare(c.border.width, 0)
        }
    }

    function test_bandBoundariesMatchTheSharedMapping() {
        // 同一个分钟数在哪一页都落进同一档：直接拿共用函数当预期，不在这里再写一份阈值。
        var minutes = [1, 59, 60, 149, 150, 299, 300, 1440]
        var list = []
        for (var i = 0; i < minutes.length; ++i)
            list.push({ day: i + 1, count: minutes[i] })
        heatmap.dailyCounts = list
        var expectedBands = [0, 0, 1, 1, 2, 2, 3, 3]
        for (var j = 0; j < minutes.length; ++j) {
            compare(HeatmapBands.bandForMinutes(minutes[j]), expectedBands[j])
            compare(cell(j + 1).heatBand, expectedBands[j], minutes[j] + " 分钟")
            sameColor(cell(j + 1).color, Theme.heatmapBandColors[expectedBands[j]],
                      minutes[j] + " 分钟的底色")
        }
    }

    function test_lowMonthIsNotStretchedToTheDarkestBand() {
        // 旧实现按当月最大值取强度：整月都只学 30 分钟时，最多那天被染成最深。
        heatmap.dailyCounts = [{ day: 5, count: 30 }, { day: 9, count: 20 }]
        compare(cell(5).heatBand, 0)
        compare(cell(9).heatBand, 0)
        sameColor(cell(5).color, Theme.heatmapBandColors[0], "整月最高的 30 分钟")
    }

    function test_fillIsTheBandColorItselfWithoutOpacityOverlay() {
        // 定稿色值是不透明纯色，屏幕上那个色必须就是规格色——不能再叠一层半透明 accent。
        heatmap.dailyCounts = [{ day: 6, count: 400 }, { day: 13, count: 0 }]
        waitForRendering(heatmap)
        var image = grabImage(heatmap)
        var busy = cell(6), idle = cell(13)
        var busyPoint = busy.mapToItem(heatmap, 6, busy.height / 2)
        var idlePoint = idle.mapToItem(heatmap, 6, idle.height / 2)
        sameColor(image.pixel(busyPoint.x, busyPoint.y), Theme.heatmapBandColors[3], "第 4 档像素")
        sameColor(image.pixel(idlePoint.x, idlePoint.y), Theme.surfaceSunken, "零投入像素")
    }

    function test_pastZeroIsQuietZeroFill() {
        heatmap.dailyCounts = [{ day: 12, count: 45 }]
        var c = cell(13)
        compare(c.heatBand, HeatmapBands.NONE)
        compare(c.futureCell, false)
        sameColor(c.color, Theme.surfaceSunken, "过去零投入底色")
        compare(c.border.width, 0)
        sameColor(dateText(13).color, Theme.ink, "过去零投入日期")
        verify(c.Accessible.name.indexOf("无投入") >= 0, c.Accessible.name)
        verify(c.tooltipText.indexOf("无投入") >= 0, c.tooltipText)
    }

    function test_todayZeroIsZeroFillWithTodayMarker() {
        var c = cell(18)
        compare(c.isToday, true)
        compare(c.futureCell, false)
        sameColor(c.color, Theme.surfaceSunken, "今日零投入底色")
        sameColor(c.border.color, Theme.accent, "今日标记")
        compare(c.border.width, 2)
        verify(c.Accessible.name.indexOf("今日暂无投入") >= 0, c.Accessible.name)
        verify(c.tooltipText.indexOf("今日暂无投入") >= 0, c.tooltipText)
    }

    function test_todayWithInvestmentKeepsBandAndTodayMarker() {
        heatmap.dailyCounts = [{ day: 18, count: 275 }]
        var c = cell(18)
        compare(c.heatBand, 2)
        sameColor(c.color, Theme.heatmapBandColors[2], "今日有投入底色")
        sameColor(c.border.color, Theme.accent, "今日标记")
        compare(c.border.width, 2)
        verify(c.Accessible.name.indexOf("今天") >= 0, c.Accessible.name)
        verify(c.Accessible.name.indexOf("4 小时 35 分") >= 0, c.Accessible.name)
    }

    function test_futureIsUnfilledWithSolidOutline() {
        var c = cell(19)
        compare(c.futureCell, true)
        compare(c.heatBand, HeatmapBands.NONE)
        compare(Qt.color(c.color).a, 0)
        sameColor(c.border.color, Theme.border, "未来描边")
        compare(c.border.width, 1)
        sameColor(dateText(19).color, Theme.ink, "未来日期保留 ink")
        verify(c.Accessible.name.indexOf("尚未到来") >= 0, c.Accessible.name)
        // 未来不能被播成「没学」。
        verify(c.Accessible.name.indexOf("无投入") < 0, c.Accessible.name)
        verify(c.tooltipText.indexOf("尚未到来") >= 0, c.tooltipText)
    }

    function test_futureIsJudgedByTheLogicalTodayPassedIn() {
        // 目标页在凌晨 3:59 传进来的逻辑今日是前一天（GoalsView.logicalToday）；
        // 格子只认传入的 today，不自己拿 new Date() 比。
        heatmap.today = new Date(2026, 6, 13)
        compare(cell(13).isToday, true)
        compare(cell(13).futureCell, false)
        compare(cell(14).futureCell, true)
        compare(cell(14).border.width, 1)
    }

    function test_wholeFutureMonthIsAllFuture() {
        heatmap.month = 8
        for (var day = 1; day <= 31; ++day) {
            compare(cell(day).futureCell, true, "8 月 " + day + " 日")
            compare(cell(day).isToday, false)
        }
    }

    function test_wholePastMonthHasNoFutureOrToday() {
        heatmap.month = 6
        for (var day = 1; day <= 30; ++day) {
            compare(cell(day).futureCell, false, "6 月 " + day + " 日")
            compare(cell(day).isToday, false)
            sameColor(cell(day).color, Theme.surfaceSunken, "6 月 " + day + " 日零值底色")
        }
    }

    function test_outOfMonthOffsetsStayBlank() {
        // 2026 年 7 月 1 日是周三，首列周一，前面有两个空位。
        compare(heatmap.firstOffset, 2)
        var offset = findChild(heatmap, "goalHeatmapOffset-0")
        verify(offset !== null)
        compare(Qt.color(offset.color).a, 0)
        compare(offset.border.width, 0)
        compare(offset.futureCell, false)
    }

    function test_investedNamesSayMinutesNotPomodoros() {
        // count 是分钟。旧文案「90 个番茄」把单位整整报错了一个量级。
        heatmap.dailyCounts = [{ day: 9, count: 90 }]
        var c = cell(9)
        verify(c.Accessible.name.indexOf("1 小时 30 分") >= 0, c.Accessible.name)
        verify(c.Accessible.name.indexOf("番茄") < 0, c.Accessible.name)
        verify(c.tooltipText.indexOf("1 小时 30 分") >= 0, c.tooltipText)
        verify(c.tooltipText.indexOf("番茄") < 0, c.tooltipText)
    }

    function test_darkThemeFollowsTheDarkPalette() {
        heatmap.dailyCounts = [{ day: 3, count: 200 }, { day: 13, count: 0 }]
        Theme.activeThemeId = "starry"
        verify(Theme.darkMode)
        sameColor(cell(3).color, "#d09459", "夜间第 3 档底色")
        sameColor(dateText(3).color, "#2a241c", "夜间第 3 档字色")
        sameColor(cell(13).color, "#211c15", "夜间零值底色")
        sameColor(cell(19).border.color, Theme.border, "夜间未来描边")
    }
}
