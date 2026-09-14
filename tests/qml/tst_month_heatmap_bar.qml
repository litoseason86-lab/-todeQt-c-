import QtQuick
import QtTest
import "../../qml"
import "../../qml/views"
import "../../qml/HeatmapBands.js" as HeatmapBands

// 专注历史月历的投入条（2026-09-14 定稿的 B 方案，规则见 docs/业务规则.md「热力取档与专注历史月历的投入条」）。
//
// 规则：底色继续归选中 / 悬停 / 今日状态，投入强度只由格底色条表达。
// 有投入 = 按档着色；零投入 = 空轨道；未来 = 不画条；本月之外 = 什么都没有。
// 未来按逻辑今日逐格判断。
//
// 不断言 visible === true（本项目离屏测试里父链可见性不可靠），
// 改断言格子上显式暴露的 heatBand / showsInvestmentBar 与条的颜色。
TestCase {
    id: testCase
    name: "MonthHeatmapBar"
    when: windowShown
    width: 1200
    height: 860

    property var fakeNow: new Date(2026, 6, 18, 10, 0)
    // 日期 → 秒。用例按需覆盖。
    property var secondsByDate: ({})

    QtObject {
        id: appSettings
        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService
        signal changed()
    }

    QtObject {
        id: history

        function getMonthSessions(year, month) {
            var prefix = year + "-" + (month < 10 ? "0" : "") + month + "-"
            var list = []
            for (var key in testCase.secondsByDate) {
                if (key.indexOf(prefix) === 0)
                    list.push({ date: key, durationSeconds: testCase.secondsByDate[key] })
            }
            return list
        }
        function lastError() { return "" }
        function invalidSessionCount() { return 0 }
    }

    MonthGoalView {
        id: view
        width: 1200
        height: 860
        focusHistoryServiceRef: history
        logicalDayServiceRef: logicalDayService
        settingsRef: appSettings
        logicalNowProvider: function() { return testCase.fakeNow }
    }

    function julyIso(day) {
        return "2026-07-" + (day < 10 ? "0" : "") + day
    }

    function cell(day) {
        var found = findChild(view, "monthDayCell-" + day)
        verify(found !== null, "找不到 " + day + " 日的格子")
        return found
    }

    function bar(day) {
        var found = findChild(view, "monthDayBar-" + day)
        verify(found !== null, "找不到 " + day + " 日的投入条")
        return found
    }

    function reload(now, year, month, selected) {
        testCase.fakeNow = now
        view.logicalToday = view.computeLogicalToday()
        view.setMonth(year, month, selected)
        view.refresh()
        wait(20)
    }

    function init() {
        Theme.activeThemeId = "warm"
        testCase.secondsByDate = ({})
        reload(new Date(2026, 6, 18, 10, 0), 2026, 7, 18)
    }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
    }

    function test_pastDayWithInvestmentGetsItsBandColor() {
        var data = {}
        data[julyIso(3)] = 45 * 60
        data[julyIso(4)] = 90 * 60
        data[julyIso(5)] = 200 * 60
        data[julyIso(6)] = 390 * 60
        testCase.secondsByDate = data
        reload(testCase.fakeNow, 2026, 7, 18)

        var expected = [[3, 0], [4, 1], [5, 2], [6, 3]]
        for (var i = 0; i < expected.length; ++i) {
            var day = expected[i][0], band = expected[i][1]
            compare(cell(day).heatBand, band, day + " 日档位")
            compare(cell(day).showsInvestmentBar, true, day + " 日应画条")
            verify(Qt.colorEqual(bar(day).color, Theme.heatmapBandColors[band]), day + " 日条色不对")
        }
    }

    function test_pastZeroDayShowsEmptyTrack() {
        compare(cell(13).heatBand, HeatmapBands.NONE)
        compare(cell(13).showsInvestmentBar, true)
        verify(Qt.colorEqual(bar(13).color, Theme.heatmapEmptyTrack))
    }

    function test_todayWithoutInvestmentIsNotTreatedAsFuture() {
        // 今日零投入是「今日暂无投入」，画空轨道；它不是「尚未到来」。
        compare(cell(18).todayCell, true)
        compare(cell(18).futureCell, false)
        compare(cell(18).showsInvestmentBar, true)
        verify(Qt.colorEqual(bar(18).color, Theme.heatmapEmptyTrack))
    }

    function test_futureDayDrawsNoBar() {
        compare(cell(19).futureCell, true)
        compare(cell(19).showsInvestmentBar, false)
        compare(cell(31).showsInvestmentBar, false)
    }

    function test_outOfMonthCellsDrawNoBar() {
        // 2026 年 7 月 1 日是周三，前两格属于上月。
        var pad = findChild(view, "monthDayCell-empty-0")
        verify(pad !== null)
        compare(pad.showsInvestmentBar, false)
    }

    function test_subMinuteInvestmentIsNotZero() {
        // 传 seconds / 60 不取整。30 秒取整成 0 分钟会画成空轨道，同一格的时长文字却显示有记录。
        var data = {}
        data[julyIso(2)] = 30
        data[julyIso(7)] = 3599
        data[julyIso(8)] = 3600
        testCase.secondsByDate = data
        reload(testCase.fakeNow, 2026, 7, 18)

        compare(cell(2).heatBand, 0)
        compare(cell(7).heatBand, 0)
        compare(cell(8).heatBand, 1)
    }

    function test_selectionChangesBackgroundButKeepsTheBar() {
        // 整格铺色方案的致命问题就是这里：选中态 accentSoft 把 4 档那天盖成全月最浅的一格。
        var data = {}
        data[julyIso(9)] = 390 * 60
        testCase.secondsByDate = data
        reload(testCase.fakeNow, 2026, 7, 9)

        compare(view.selectedDay, 9)
        // 底色带 160ms 颜色过渡，等它落定再比，不读动画中间值。
        tryVerify(function() { return Qt.colorEqual(cell(9).color, Theme.accentSoft) }, 1000,
                  "选中格底色应仍是 accentSoft")
        verify(Qt.colorEqual(bar(9).color, Theme.heatmapBandColors[3]), "选中后投入条不能被改色")
    }

    function test_selectedZeroDayAndSelectedFutureDayStayDistinct() {
        reload(testCase.fakeNow, 2026, 7, 14)
        compare(cell(14).showsInvestmentBar, true)
        verify(Qt.colorEqual(bar(14).color, Theme.heatmapEmptyTrack))

        reload(testCase.fakeNow, 2026, 7, 25)
        compare(cell(25).showsInvestmentBar, false)
    }

    function test_futureUsesLogicalTodayNotWallClock() {
        // 3:59、日界 4 点：逻辑今日仍是 17 日，日历上的 18 日尚未到来。
        reload(new Date(2026, 6, 18, 3, 59), 2026, 7, 17)
        compare(cell(17).todayCell, true)
        compare(cell(18).futureCell, true)
        compare(cell(18).showsInvestmentBar, false)
    }

    function test_crossingDayBoundaryTurnsTheNextDayIntoToday() {
        reload(new Date(2026, 6, 18, 3, 59), 2026, 7, 17)
        compare(cell(18).showsInvestmentBar, false)

        testCase.fakeNow = new Date(2026, 6, 18, 4, 0)
        logicalDayService.changed()

        compare(cell(18).futureCell, false)
        compare(cell(18).showsInvestmentBar, true)
    }

    function test_wholeFutureMonthAndWholePastMonth() {
        reload(testCase.fakeNow, 2026, 8, 1)
        compare(cell(1).showsInvestmentBar, false)
        compare(cell(31).showsInvestmentBar, false)

        reload(testCase.fakeNow, 2026, 6, 30)
        compare(cell(1).showsInvestmentBar, true)
        compare(cell(30).showsInvestmentBar, true)
    }

    function test_barFollowsThemeSwitch() {
        var data = {}
        data[julyIso(5)] = 200 * 60
        testCase.secondsByDate = data
        reload(testCase.fakeNow, 2026, 7, 18)

        Theme.activeThemeId = "starry"
        verify(Qt.colorEqual(bar(5).color, Theme.heatmapBandColors[2]))
        verify(Qt.colorEqual(bar(13).color, Theme.heatmapEmptyTrack))
    }

    function test_durationTextDoesNotTouchTheBar() {
        // 格内文字铺满整格时，ColumnLayout 会把两行纵向摊开，时长那行被推到格底贴住投入条。
        // 在卡片允许的最矮高度下也要留出间隙。
        var data = {}
        data[julyIso(10)] = 330 * 60
        testCase.secondsByDate = data
        view.height = 560
        reload(testCase.fakeNow, 2026, 7, 18)
        wait(50)

        var text = findChild(view, "monthDayText-10")
        verify(text !== null)
        var textBottom = text.y + text.height
        var barTop = bar(10).y
        verify(textBottom + Theme.hairline <= barTop,
               "时长文字底 " + textBottom + " 贴住或压住了投入条顶 " + barTop
               + "（格高 " + cell(10).height + "）")
        view.height = 860
    }
}
