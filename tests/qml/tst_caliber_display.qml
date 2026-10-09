import QtQuick
import QtTest
import "CaliberFixtures.js" as Fixtures
import "../../qml/Duration.js" as Format0
import "../../qml/views/DashboardFormat.js" as Format1
import "../../qml/views/MemoFormat.js" as Format2
import "../../qml/views/MonthGoalFormat.js" as Format3
import "../../qml/views/StatisticsFormat.js" as Format4
import "../../qml/views/TrashFormat.js" as Format5
import "../../qml/ScheduleWeeks.js" as Format6
import "../../qml/ScheduleWeeks.js" as Format7
import "../../qml/LogicalDay.js" as Format8

TestCase {
    name: "CaliberDisplay"

    function checkTable(name, module) {
        var rows = Fixtures.load(name)
        for (var i = 0; i < rows.length; ++i) {
            var input = rows[i].input
            var args = input.args.map(Fixtures.value)
            var method = module[input.op]
            verify(typeof method === "function", "未知格式函数：" + input.op)
            var actual = method.apply(module, args)
            if (actual instanceof Date) {
                // 日期函数返回本地午夜，只比较日历字段，同时确认时分归零。
                compare(actual.getHours(), 0, rows[i].reason)
                compare(actual.getMinutes(), 0, rows[i].reason)
                actual = actual.getFullYear() + "-" + (actual.getMonth() < 9 ? "0" : "") + (actual.getMonth() + 1)
                    + "-" + (actual.getDate() < 10 ? "0" : "") + actual.getDate()
            } else if (actual && typeof actual === "object") {
                // 布局返回未定义的 top/height；JSON 不表达 undefined，统一省略这些非视觉字段。
                actual = JSON.parse(JSON.stringify(actual))
            }
            compare(actual, Fixtures.value(rows[i].expected), name + " #" + (i + 1) + " " + input.op + "：" + rows[i].reason)
        }
    }

    // duration 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_duration() { checkTable("duration", Format0) }

    // dashboard-format 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_dashboard_format() { checkTable("dashboard-format", Format1) }

    // memo-format 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_memo_format() { checkTable("memo-format", Format2) }

    // month-goal-format 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_month_goal_format() { checkTable("month-goal-format", Format3) }

    // statistics-format 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_statistics_format() { checkTable("statistics-format", Format4) }

    // trash-format 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_trash_format() { checkTable("trash-format", Format5) }

    // schedule-format 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_schedule_format() { checkTable("schedule-format", Format6) }

    // schedule-layout 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_schedule_layout() { checkTable("schedule-layout", Format7) }

    // logical-date-format 的现有显示口径必须与 Swift 后续共用的输入输出表一致。
    function test_logical_date_format() { checkTable("logical-date-format", Format8) }
}
