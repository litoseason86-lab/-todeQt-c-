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
