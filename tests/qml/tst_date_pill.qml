import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"

// 日期胶囊：显示文案、清除、快捷日期、月历点选与键盘操作。
// 重点守住两件事：日期一律按传入的逻辑今天算；月历格子用年、月、日三个整数拼日期，
// 不经过 Date 的时区换算。
TestCase {
    id: testCase
    name: "DatePill"
    when: windowShown
    width: 480
    height: 560
    visible: true

    property var selections: []

    DatePill {
        id: pill

        x: 20
        y: 20
        // 2026-09-16 是周三。
        todayIso: "2026-09-16"
        onDateSelected: function (iso) {
            var next = testCase.selections.slice()
            next.push(iso)
            testCase.selections = next
        }
    }

    function init() {
        pill.closeCalendar()
        pill.dateIso = ""
        pill.todayIso = "2026-09-16"
        testCase.selections = []
        tryCompare(pill, "calendarOpened", false)
    }

    function popupChild(name) {
        return findChild(pill.popup.contentItem, name)
    }

    function openCalendar() {
        pill.openCalendar()
        tryCompare(pill, "calendarOpened", true)
        // opened 为真只说明弹层开始显示，内容这时还没排好版：
        // 立刻发鼠标事件会落在格子的旧坐标上，点不中。
        tryVerify(function () { return pill.popup.contentItem.width > 0 })
        wait(100)
    }

    function test_emptyDateShowsPlaceholder() {
        compare(pill.hasDate, false)
        compare(pill.labelText, "未排期")
    }

    function test_labelDescribesDatesAgainstLogicalToday() {
        pill.dateIso = "2026-09-16"
        compare(pill.labelText, "今天")
        pill.dateIso = "2026-09-17"
        compare(pill.labelText, "明天")
        pill.dateIso = "2026-09-20"
        compare(pill.labelText, "9月20日 周日")
        // 跨年才带年份。
        pill.dateIso = "2027-01-03"
        compare(pill.labelText, "2027年1月3日 周日")
        // 「今天」认的是传进来的逻辑今天，不是本机日期。
        pill.todayIso = "2026-09-19"
        pill.dateIso = "2026-09-20"
        compare(pill.labelText, "明天")
    }

    function test_clearButtonEmitsEmptyDateWithoutWritingBack() {
        pill.dateIso = "2026-09-20"
        var clearButton = findChild(pill, "datePillClearButton")
        verify(clearButton)
        clearButton.clicked()
        compare(testCase.selections.length, 1)
        compare(testCase.selections[0], "")
        // 受控组件：自己不改 dateIso，写不写回由调用方决定。
        compare(pill.dateIso, "2026-09-20")
    }

    function test_calendarOpensOnSelectedMonthOrToday() {
        pill.dateIso = "2026-12-05"
        testCase.openCalendar()
        compare(pill.shownYear, 2026)
        compare(pill.shownMonth, 11)
        pill.closeCalendar()
        tryCompare(pill, "calendarOpened", false)

        pill.dateIso = ""
        testCase.openCalendar()
        compare(pill.shownYear, 2026)
        compare(pill.shownMonth, 8)
        compare(pill.cursorIso, "2026-09-16")
    }

    function test_quickChipsUseLogicalToday() {
        testCase.openCalendar()
        popupChild("datePillTomorrowChip").clicked()
        compare(testCase.selections[0], "2026-09-17")
        tryCompare(pill, "calendarOpened", false)

        testCase.openCalendar()
        popupChild("datePillNextMondayChip").clicked()
        compare(testCase.selections[1], "2026-09-21")
        tryCompare(pill, "calendarOpened", false)

        // 今天就是周一时，「下周一」是下一个周一，不是今天。
        pill.todayIso = "2026-09-14"
        testCase.openCalendar()
        popupChild("datePillNextMondayChip").clicked()
        compare(testCase.selections[2], "2026-09-21")
        tryCompare(pill, "calendarOpened", false)

        testCase.openCalendar()
        popupChild("datePillClearChip").clicked()
        compare(testCase.selections[3], "")
    }

    // 弹层刚打开时格子还没排好版，位置会在下一帧才定下来；等它出现并有尺寸再点，
    // 否则点击落在旧坐标上，整条用例时好时坏。
    function dayCell(iso) {
        var cell = null
        tryVerify(function () {
            cell = testCase.popupChild("datePillDay-" + iso)
            return cell !== null && cell.width > 0 && cell.height > 0
        }, 2000)
        return cell
    }

    function test_clickingDayUsesGridYearMonthDay() {
        testCase.openCalendar()
        var day = testCase.dayCell("2026-09-25")
        verify(day)
        mouseClick(day, day.width / 2, day.height / 2)
        tryVerify(function () { return testCase.selections.length === 1 })
        compare(testCase.selections[0], "2026-09-25")
        tryCompare(pill, "calendarOpened", false)

        // 2026 年 9 月 1 日是周二，周一开头的月历第一格属于上个月。
        testCase.openCalendar()
        var leading = testCase.dayCell("2026-08-31")
        verify(leading)
        mouseClick(leading, leading.width / 2, leading.height / 2)
        tryVerify(function () { return testCase.selections.length === 2 })
        compare(testCase.selections[1], "2026-08-31")
    }

    function test_monthButtonsCrossYearBoundary() {
        pill.dateIso = "2026-12-10"
        testCase.openCalendar()
        popupChild("datePillNextMonthButton").clicked()
        compare(pill.shownYear, 2027)
        compare(pill.shownMonth, 0)
        compare(popupChild("datePillMonthTitle").text, "2027 年 1 月")
        popupChild("datePillPreviousMonthButton").clicked()
        compare(pill.shownYear, 2026)
        compare(pill.shownMonth, 11)
    }

    function test_keyboardMovesCursorAndPicks() {
        pill.dateIso = "2026-09-20"
        testCase.openCalendar()
        tryVerify(function () { return pill.popup.contentItem.activeFocus })
        compare(pill.cursorIso, "2026-09-20")
        keyClick(Qt.Key_Right)
        compare(pill.cursorIso, "2026-09-21")
        keyClick(Qt.Key_Down)
        compare(pill.cursorIso, "2026-09-28")
        keyClick(Qt.Key_Down)
        // 跨月时月历跟着翻页，光标不会落到看不见的地方。
        compare(pill.cursorIso, "2026-10-05")
        compare(pill.shownMonth, 9)
        keyClick(Qt.Key_Return)
        compare(testCase.selections.length, 1)
        compare(testCase.selections[0], "2026-10-05")
        tryCompare(pill, "calendarOpened", false)
    }

    function test_mouseMonthFlipCarriesCursorIntoShownMonth() {
        pill.dateIso = "2026-09-20"
        testCase.openCalendar()
        tryVerify(function () { return pill.popup.contentItem.activeFocus })
        compare(pill.cursorIso, "2026-09-20")

        popupChild("datePillNextMonthButton").clicked()
        compare(pill.shownMonth, 9)
        // 光标必须跟着翻到 10 月。停在 9 月的话，回车提交的是屏幕上根本看不见的那天，
        // 按方向键又会把月历弹回 9 月。
        compare(pill.cursorIso, "2026-10-20")

        keyClick(Qt.Key_Return)
        compare(testCase.selections.length, 1)
        compare(testCase.selections[0], "2026-10-20")
        tryCompare(pill, "calendarOpened", false)
    }

    function test_monthFlipClampsCursorToShorterMonth() {
        pill.dateIso = "2026-01-31"
        testCase.openCalendar()
        tryVerify(function () { return pill.popup.contentItem.activeFocus })
        compare(pill.cursorIso, "2026-01-31")

        popupChild("datePillNextMonthButton").clicked()
        // 2026 年 2 月没有 31 日：夹到月末，不能溢出成 3 月 3 日。
        compare(pill.shownMonth, 1)
        compare(pill.cursorIso, "2026-02-28")

        // 夹过之后方向键从新位置继续走，不会跳回原来那个月。
        keyClick(Qt.Key_Right)
        compare(pill.cursorIso, "2026-03-01")
        compare(pill.shownMonth, 2)
    }

    function test_outOfRangeDatesAreIgnored() {
        // 与服务端同一口径：2000–2100 年之外的日期不外发。
        pill.pick("1999-12-31")
        pill.pick("2101-01-01")
        pill.pick("2026-02-31")
        compare(testCase.selections.length, 0)
    }
}
