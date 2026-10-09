import QtQuick
import QtTest
import "../../qml/LogicalDay.js" as LogicalDay
import "../../qml/RoutineWeekdays.js" as Weekdays
import "CaliberFixtures.js" as Fixtures

TestCase {
    name: "CaliberShared"

    // 日界前后、零点、闰年和跨年必须与服务的逻辑日口径一致。
    function test_logicalDayFixtures() {
        var rows = Fixtures.load("logical-day")
        for (var i = 0; i < rows.length; ++i) {
            var input = rows[i].input
            var now = Fixtures.date(input.timestamp)
            compare(LogicalDay.todayIso(input.dayStartHour, now), rows[i].expected, rows[i].reason)
            compare(LogicalDay.isoOf(LogicalDay.todayDate(input.dayStartHour, now)), rows[i].expected, rows[i].reason)
        }
    }

    // 例行星期位序与中文文案必须覆盖全部合法组合，切换某日不改变其它日。
    function test_routineWeekdayFixtures() {
        var rows = Fixtures.load("routine-weekdays")
        for (var i = 0; i < rows.length; ++i) {
            var input = rows[i].input, expected = rows[i].expected
            var bit = input.dayOfWeek >= 1 && input.dayOfWeek <= 7 ? Weekdays.DAYS[input.dayOfWeek - 1].bit : 0
            compare(bit, expected.bit, rows[i].reason)
            compare((input.mask & bit) !== 0, expected.matches, rows[i].reason)
            compare(Weekdays.text(input.mask), expected.text, rows[i].reason)
            compare(Weekdays.normalize(input.mask), expected.normalized, rows[i].reason)
            compare(Weekdays.toggle(input.mask, bit), expected.toggled, rows[i].reason)
        }
    }
}
