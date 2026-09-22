import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"
import "../../qml/RoutineWeekdays.js" as Weekdays

TestCase {
    id: testCase
    name: "RoutineWeekdayDialogUi"
    when: windowShown
    visible: true
    width: 600
    height: 500

    property int saveCalls: 0
    property int savedRoutineId: -1
    property int savedWeekdays: -1
    property bool saveResult: true

    QtObject {
        id: fakeRoutineManager

        signal routinesChanged()

        function setRoutineWeekdays(id, weekdays) {
            testCase.saveCalls += 1
            testCase.savedRoutineId = id
            testCase.savedWeekdays = weekdays
            if (!testCase.saveResult) {
                return false
            }
            routinesChanged()
            return true
        }
    }

    RoutineWeekdayDialog {
        id: dialog
        routineManagerRef: fakeRoutineManager
    }

    function init() {
        testCase.saveCalls = 0
        testCase.savedRoutineId = -1
        testCase.savedWeekdays = -1
        testCase.saveResult = true
        dialog.routineManagerRef = fakeRoutineManager
        dialog.close()
        tryCompare(dialog, "opened", false, 3000)
    }

    // 圆点由 Repeater 生成，从 Popup 根 findChild 找不到；先拿到它们所在的那一行。
    function chip(index) {
        var row = findChild(dialog, "routineWeekdayDialogRow")
        verify(row !== null)
        return findChild(row, "routineWeekdayChip" + index)
    }

    function preset(mask) {
        var row = findChild(dialog, "routineWeekdayPresetRow")
        verify(row !== null)
        return findChild(row, "routineWeekdayPreset" + mask)
    }

    function openFor(id, title, weekdays) {
        dialog.openFor({ id: id, title: title, weekdays: weekdays })
        tryCompare(dialog, "opened", true, 3000)
    }

    function test_openForLoadsRoutineAndItsWeekdays() {
        testCase.openFor(42, "计算机网络", 0x15)
        compare(dialog.routineId, 42)
        compare(dialog.routineTitle, "计算机网络")
        compare(dialog.selectedWeekdays, 0x15)
        compare(findChild(dialog, "routineWeekdayDialogSummary").text, "周一三五")
        dialog.close()
    }

    function test_openForFallsBackToEveryDayOnBadMask() {
        // 旧库升级上来的例行、或被外部改坏的行，取不到合法掩码时按「每天」回落，
        // 与数据库迁移给旧例行补的默认值一致；不能让弹窗停在「一天都没选」。
        testCase.openFor(7, "旧例行", 0)
        compare(dialog.selectedWeekdays, Weekdays.EVERY_DAY)
        dialog.close()
    }

    function test_chipOrderMatchesIsoNumbering() {
        testCase.openFor(1, "例行", Weekdays.EVERY_DAY)

        // 七个圆点的顺序就是位的顺序：第 i 个必须正好管第 i 位（0 = 周一）。
        // 不钉这层对应关系，整排按钮写反（比如周日打头）也能全绿，
        // 用户却会发现选了「一」任务落在周日。
        var labels = ["一", "二", "三", "四", "五", "六", "日"]
        for (var i = 0; i < labels.length; ++i) {
            var dayChip = testCase.chip(i)
            verify(dayChip !== null)
            compare(dayChip.text, labels[i])

            dialog.selectedWeekdays = Weekdays.EVERY_DAY
            mouseClick(dayChip)
            compare(dialog.selectedWeekdays, Weekdays.EVERY_DAY & ~(1 << i))
        }
        dialog.close()
    }

    function test_selectedChipIsSolidAccent() {
        testCase.openFor(1, "例行", 0x01)
        var monday = testCase.chip(0)
        var tuesday = testCase.chip(1)
        verify(monday !== null)
        verify(tuesday !== null)

        // 选中必须是实心强调色。早前用浅填充时，七个圆点看下来分不出选了哪几天——
        // 这条断言就是防止再退回那种「选中和没选中长得差不多」的配色。
        compare(monday.daySelected, true)
        verify(Qt.colorEqual(monday.background.color, Theme.accent))
        compare(tuesday.daySelected, false)
        verify(!Qt.colorEqual(tuesday.background.color, Theme.accent))
        dialog.close()
    }

    function test_saveWritesOnlyOnConfirm() {
        testCase.openFor(42, "计算机网络", Weekdays.EVERY_DAY)

        mouseClick(testCase.chip(5))
        mouseClick(testCase.chip(6))
        compare(dialog.selectedWeekdays, Weekdays.MON_TO_FRI)
        // 改动是草稿：没点保存之前不能写库。
        compare(testCase.saveCalls, 0)

        mouseClick(findChild(dialog, "routineWeekdaySaveButton"))
        compare(testCase.saveCalls, 1)
        compare(testCase.savedRoutineId, 42)
        compare(testCase.savedWeekdays, Weekdays.MON_TO_FRI)
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_cancelDiscardsChanges() {
        testCase.openFor(42, "计算机网络", 0x15)
        mouseClick(testCase.chip(1))
        compare(dialog.selectedWeekdays, 0x17)

        mouseClick(findChild(dialog, "routineWeekdayCancelButton"))
        compare(testCase.saveCalls, 0)
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_presetsSetCommonCombinations() {
        testCase.openFor(42, "计算机网络", 0x15)

        mouseClick(testCase.preset(Weekdays.MON_TO_FRI))
        compare(dialog.selectedWeekdays, Weekdays.MON_TO_FRI)
        compare(findChild(dialog, "routineWeekdayDialogSummary").text, "工作日")

        mouseClick(testCase.preset(Weekdays.WEEKEND))
        compare(dialog.selectedWeekdays, Weekdays.WEEKEND)
        compare(findChild(dialog, "routineWeekdayDialogSummary").text, "周末")

        mouseClick(testCase.preset(Weekdays.EVERY_DAY))
        compare(dialog.selectedWeekdays, Weekdays.EVERY_DAY)
        compare(findChild(dialog, "routineWeekdayDialogSummary").text, "每天")
        dialog.close()
    }

    function test_noDaySelectedBlocksSaveWithReason() {
        testCase.openFor(42, "计算机网络", Weekdays.EVERY_DAY)
        for (var bit = 0x01; bit <= 0x40; bit *= 2) {
            dialog.toggleWeekday(bit)
        }
        compare(dialog.selectedWeekdays, 0)

        mouseClick(findChild(dialog, "routineWeekdaySaveButton"))
        // 一天都不选的例行永远不会生成任务：当场说清原因，不写库也不关窗。
        compare(testCase.saveCalls, 0)
        compare(findChild(dialog, "routineWeekdayDialogError").text, "至少选择一个重复的星期")
        compare(dialog.opened, true)
        dialog.close()
    }

    function test_saveFailureKeepsDialogOpenForRetry() {
        testCase.saveResult = false
        testCase.openFor(42, "计算机网络", 0x15)
        mouseClick(testCase.chip(1))

        mouseClick(findChild(dialog, "routineWeekdaySaveButton"))
        compare(testCase.saveCalls, 1)
        compare(dialog.opened, true)
        compare(findChild(dialog, "routineWeekdayDialogError").text, "重复日保存失败，请重试")
        // 失败后草稿要留着，用户才能重试，而不是被打回原值。
        compare(dialog.selectedWeekdays, 0x17)
        dialog.close()
    }

    function test_serviceUnavailableShowsReason() {
        dialog.routineManagerRef = null
        testCase.openFor(42, "计算机网络", 0x15)
        mouseClick(findChild(dialog, "routineWeekdaySaveButton"))
        compare(findChild(dialog, "routineWeekdayDialogError").text, "每日例行服务不可用")
        dialog.close()
    }

    function test_summaryTextCoversCommonCombinations() {
        compare(Weekdays.text(Weekdays.EVERY_DAY), "每天")
        compare(Weekdays.text(Weekdays.MON_TO_FRI), "工作日")
        compare(Weekdays.text(Weekdays.WEEKEND), "周末")
        compare(Weekdays.text(0x15), "周一三五")
        // 四天起就不能再带顿号：文案要塞进列表行上固定宽度的药丸，带顿号到四天就超宽。
        compare(Weekdays.text(0x2B), "周一二四六")
        // 正好缺一天时报「除周X」，比罗列六天短得多，也更好懂。
        compare(Weekdays.text(0x5F), "除周六")
        compare(Weekdays.text(0x3F), "除周日")
        compare(Weekdays.text(0x40), "周日")
        // 坏数据显示成「未设置」而不是空白，免得看起来像这一处漏渲染了。
        compare(Weekdays.text(0), "未设置")
        compare(Weekdays.text(undefined), "未设置")
    }
}
