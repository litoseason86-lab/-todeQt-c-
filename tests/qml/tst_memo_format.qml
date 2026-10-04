import QtQuick
import QtTest
import "../../qml/views/MemoFormat.js" as MemoFormat

TestCase {
    name: "MemoFormat"
    // 产品保证：UTC 输入按本地自然日分档，午夜不是“距离上次编辑不足 24 小时”。
    function test_naturalDays_data() {
        var now = new Date(2026, 9, 3, 0, 1);
        return [
            {
                tag: "今天",
                value: new Date(2026, 9, 3, 0, 0).toISOString(),
                now: now,
                expected: "今天 00:00"
            },
            {
                tag: "午夜前",
                value: new Date(2026, 9, 2, 23, 59).toISOString(),
                now: now,
                expected: "昨天"
            },
            {
                tag: "2天",
                value: new Date(2026, 9, 1, 23, 59).toISOString(),
                now: now,
                expected: "2 天前"
            },
            {
                tag: "6天",
                value: new Date(2026, 8, 27, 1).toISOString(),
                now: now,
                expected: "6 天前"
            },
            {
                tag: "7天",
                value: new Date(2026, 8, 26, 23, 59).toISOString(),
                now: now,
                expected: "9月26日"
            },
            {
                tag: "跨年昨天",
                value: new Date(2025, 11, 31, 23, 59).toISOString(),
                now: new Date(2026, 0, 1, 0, 1),
                expected: "昨天"
            },
            {
                tag: "往年",
                value: new Date(2025, 11, 20, 12).toISOString(),
                now: new Date(2026, 0, 1),
                expected: "2025年12月20日"
            },
            {
                tag: "无效输入",
                value: "bad",
                now: now,
                expected: ""
            }
        ];
    }
    function test_naturalDays(data) {
        compare(MemoFormat.formatUpdatedAt(data.value, data.now), data.expected);
    }
}
