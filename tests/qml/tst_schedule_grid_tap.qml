import QtQuick
import QtTest
import "../../qml/components"

// 课表网格的点击归属。这条用例守的是一个只在真机点击时才暴露、
// 纯属性断言完全看不见的问题：嵌套的 TapHandler 默认取的是「被动抓取」，
// 外层和内层会同时收到同一次点击。表现是点一块课，编辑弹窗刚打开就被
// 「新增」重新初始化成空白——编辑入口等于不存在。
TestCase {
    id: testCase
    name: "ScheduleGridTap"
    when: windowShown
    width: 700
    height: 520
    visible: true

    property var received: []

    ScheduleGrid {
        id: grid

        anchors.fill: parent
        semesterStartDate: "2026-08-31"
        weekIndex: 1
        showWeekend: true
        periods: []
        entries: [{
            id: 42, title: "测试课", location: "A101", weekday: 1,
            startMinutes: 480, endMinutes: 600, durationMinutes: 120,
            weekStart: 1, weekEnd: 16, weekParity: 0,
            categoryId: undefined, categoryName: "", categoryColor: ""
        }]

        onAddRequested: function (weekday, startMinutes) {
            testCase.received.push("add:" + weekday)
        }
        onEditRequested: function (entryId) {
            testCase.received.push("edit:" + entryId)
        }
        onDeleteRequested: function (entryId, title) {
            testCase.received.push("delete:" + entryId)
        }
    }

    function blockForEntry(weekday, entryId) {
        var column = findChild(grid, "scheduleDayColumn-" + weekday)
        verify(column !== null, "找不到星期 " + weekday + " 那一列")
        for (var i = 0; i < column.children.length; ++i) {
            var child = column.children[i]
            if (child.entryId !== undefined && child.entryId === entryId) {
                return child
            }
        }
        return null
    }

    function init() {
        testCase.received = []
        wait(120)
    }

    function test_tapping_a_block_only_edits() {
        var block = blockForEntry(1, 42)
        verify(block !== null, "找不到课程块")

        var point = block.mapToItem(grid, block.width / 2, block.height / 2)
        mouseClick(grid, point.x, point.y)
        wait(120)

        // 关键断言是「只有一个」。外层列的新增处理器一起响应时，
        // 这里会同时收到 edit 和 add，而界面上看到的就是一个空白的新增弹窗。
        compare(testCase.received.length, 1,
                "点课程块应只触发一个信号，实际：" + JSON.stringify(testCase.received))
        compare(testCase.received[0], "edit:42")
    }

    // 块右上角那颗 × 是「块的 TapHandler 里再套一个 TapHandler」，
    // 结构与上面那条守的完全一样。目前行为是对的（内层独占抓取赢了外层），
    // 但这条正确性只由 gesturePolicy 一个属性维持，删掉它不会有任何编译或断言报错——
    // 表现只是「点 × 弹出编辑窗」。所以要有一条用例守住。
    function test_tapping_delete_badge_does_not_also_edit() {
        var block = blockForEntry(1, 42)
        verify(block !== null, "找不到课程块")

        // × 只在悬停时出现，先把指针移到块上。
        var center = block.mapToItem(grid, block.width / 2, block.height / 2)
        mouseMove(grid, center.x, center.y)
        wait(120)

        var badge = findChild(grid, "scheduleEntryDelete-42")
        verify(badge !== null, "找不到删除按钮")
        var point = badge.mapToItem(grid, badge.width / 2, badge.height / 2)
        mouseClick(grid, point.x, point.y)
        wait(120)

        compare(testCase.received.length, 1,
                "点删除按钮应只触发一个信号，实际：" + JSON.stringify(testCase.received))
        compare(testCase.received[0], "delete:42")
    }

    // 键盘通路。悬停出现的 × 对只用键盘的人不存在，所以聚焦后的按键是唯一入口。
    //
    // 两颗键都要验：Keys.onDeletePressed 只认 Qt.Key_Delete，而 Mac 主键盘上
    // 那颗写着 delete 的键发的是 Qt.Key_Backspace。同时这里也在验
    // 通用的 Keys.onPressed 没有把 Delete 一起吞掉——它只该接管 Backspace。
    function test_keyboard_delete_works_with_both_keys() {
        var block = blockForEntry(1, 42)
        verify(block !== null, "找不到课程块")
        block.forceActiveFocus()
        wait(60)

        keyClick(Qt.Key_Backspace)
        wait(60)
        compare(testCase.received.length, 1, "Backspace 应触发删除，实际："
                + JSON.stringify(testCase.received))
        compare(testCase.received[0], "delete:42")

        testCase.received = []
        keyClick(Qt.Key_Delete)
        wait(60)
        compare(testCase.received.length, 1, "Delete 应仍然触发删除，实际："
                + JSON.stringify(testCase.received))
        compare(testCase.received[0], "delete:42")

        // 回车走的是编辑，不能被上面两个处理器抢掉。
        testCase.received = []
        keyClick(Qt.Key_Return)
        wait(60)
        compare(testCase.received.length, 1)
        compare(testCase.received[0], "edit:42")
    }

    function test_tapping_empty_space_only_adds() {
        var column = findChild(grid, "scheduleDayColumn-3")
        verify(column !== null)

        var point = column.mapToItem(grid, column.width / 2, 40)
        mouseClick(grid, point.x, point.y)
        wait(120)

        compare(testCase.received.length, 1,
                "点空白应只触发一个信号，实际：" + JSON.stringify(testCase.received))
        verify(testCase.received[0].indexOf("add:3") === 0)
    }
}
