import QtQuick
import QtTest
import "../../qml/LogicalDay.js" as LogicalDay

TestCase {
    name: "LogicalDay"

    function test_todayDateBoundaries() {
        compare(LogicalDay.todayDate(4, new Date(2026, 6, 8, 3, 59)).getTime(),
                new Date(2026, 6, 7).getTime())
        compare(LogicalDay.todayDate(4, new Date(2026, 6, 8, 4, 0)).getTime(),
                new Date(2026, 6, 8).getTime())
        compare(LogicalDay.todayDate(0, new Date(2026, 6, 8, 0, 30)).getTime(),
                new Date(2026, 6, 8).getTime())
        compare(LogicalDay.todayDate(4, new Date(2026, 6, 8, 15, 42)).getHours(), 0)
    }

    function test_todayIsoBoundaries() {
        compare(LogicalDay.todayIso(4, new Date(2026, 6, 8, 1, 0)), "2026-07-07")
        compare(LogicalDay.todayIso(4, new Date(2026, 6, 8, 12, 0)), "2026-07-08")
        compare(LogicalDay.todayIso(4, new Date(2026, 0, 1, 2, 0)), "2025-12-31")
        compare(LogicalDay.todayIso(4, new Date(2026, 2, 5, 12, 0)), "2026-03-05")
    }
}
