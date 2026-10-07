import QtQuick
import QtTest
import "../../qml/views/TrashFormat.js" as TrashFormat

TestCase {
    name: "TrashFormat"

    readonly property string today: "2026-10-07"

    function item(kind, details, category) {
        return { kind: kind, details: details, categoryName: category === undefined ? "" : category,
                 restorable: true, blockedReason: "" }
    }

    function test_groupLabel_data() {
        return [
            { tag: "今天", date: "2026-10-07", expected: "今天" },
            { tag: "昨天", date: "2026-10-06", expected: "昨天" },
            // 昨天要跨月、跨年算对：只在字符串上减 1 会得到 2026-09-00 / 2025-12-32 这类东西。
            { tag: "本年更早", date: "2026-09-12", expected: "9月12日" },
            { tag: "跨年", date: "2025-12-31", expected: "2025年12月31日" },
            { tag: "未来年份", date: "2027-01-02", expected: "2027年1月2日" },
            { tag: "空", date: "", expected: "删除时间不详" },
            { tag: "坏格式", date: "abc", expected: "删除时间不详" }
        ]
    }

    function test_groupLabel(data) {
        // 产品保证：分组标签只拿服务给的 today 去比；不是今年的带年份，没有删除日期写「删除时间不详」。
        compare(TrashFormat.groupLabel(data.date, today), data.expected)
    }

    function test_yesterdayCrossesMonthAndYear() {
        // 产品保证：「昨天」在月初、年初也算对。
        compare(TrashFormat.groupLabel("2026-02-28", "2026-03-01"), "昨天")
        compare(TrashFormat.groupLabel("2025-12-31", "2026-01-01"), "昨天")
        compare(TrashFormat.groupLabel("2026-03-01", "2026-03-01"), "今天")
        // 2026-03-01 的前一天不是 2026-02-29（2026 年不是闰年）。
        compare(TrashFormat.groupLabel("2026-02-29", "2026-03-01"), "2月29日")
    }

    function test_groupItemsKeepsServiceOrderAndTakesRemainingFromFirstItem() {
        // 产品保证：分组保持服务给的顺序；组头「还剩 N 天」取组里第一项的 remainingDays，
        // 没有删除日期的组不写剩余天数。数据：同一天的两项剩余天数故意不一致（取第一项），
        // 日期顺序故意不是按日期文本排的。
        var groups = TrashFormat.groupItems([
            { id: 1, deletedDate: "2026-10-06", remainingDays: 29 },
            { id: 2, deletedDate: "2026-10-06", remainingDays: 7 },
            { id: 3, deletedDate: "2026-10-07", remainingDays: 30 },
            { id: 4, deletedDate: "", remainingDays: 30 }
        ], today)
        compare(groups.length, 3)
        compare(groups[0].label, "昨天")
        compare(groups[0].items.length, 2)
        compare(groups[0].remaining, "还剩 29 天")
        compare(TrashFormat.groupHeading(groups[0]), "昨天 · 2")
        compare(groups[1].label, "今天")
        compare(groups[2].label, "删除时间不详")
        compare(groups[2].remaining, "")
        compare(TrashFormat.groupHeading(groups[2]), "删除时间不详 · 1")
    }

    function test_metaTextForEveryKind_data() {
        return [
            { tag: "任务", expected: "任务 · 10月6日 · 政治",
              item: item("task", { date: "2026-10-06" }, "政治") },
            { tag: "任务无科目", expected: "任务 · 10月6日",
              item: item("task", { date: "2026-10-06" }) },
            { tag: "任务跨年", expected: "任务 · 2025年12月31日 · 政治",
              item: item("task", { date: "2025-12-31" }, "政治") },
            { tag: "专注", expected: "专注记录 · 10月6日 14:05–14:50 · 45 分钟 · 数学",
              item: item("focus_session", { startTime: "2026-10-06T14:05:00.000",
                                            endTime: "2026-10-06T14:50:00.000", durationSeconds: 2700 }, "数学") },
            { tag: "专注零时长无科目", expected: "专注记录 · 10月6日 14:05–14:05 · 0 分钟",
              item: item("focus_session", { startTime: "2026-10-06T14:05:00.000",
                                            endTime: "2026-10-06T14:05:00.000", durationSeconds: 0 }) },
            { tag: "专注超过一小时", expected: "专注记录 · 10月6日 14:05–15:10 · 1 小时 5 分",
              item: item("focus_session", { startTime: "2026-10-06T14:05:00.000",
                                            endTime: "2026-10-06T15:10:00.000", durationSeconds: 3900 }) },
            { tag: "专注缺结束时间", expected: "专注记录 · 10月6日 14:05 · 5 分钟",
              item: item("focus_session", { startTime: "2026-10-06T14:05:00.000", endTime: "",
                                            durationSeconds: 300 }) },
            { tag: "休息", expected: "休息记录 · 10月2日 21:10–21:25 · 15 分钟",
              item: item("rest_session", { startTime: "2026-10-02T21:10:00.000",
                                           endTime: "2026-10-02T21:25:00.000", durationSeconds: 900 }) },
            { tag: "备忘录", expected: "备忘录 · 英语", item: item("memo", {}, "英语") },
            { tag: "备忘录无科目", expected: "备忘录", item: item("memo", {}) },
            { tag: "缺口", expected: "知识缺口 · 数学 · 计划 10月8日",
              item: item("knowledge_gap", { dueDate: "2026-10-08" }, "数学") },
            { tag: "缺口无科目无计划", expected: "知识缺口",
              item: item("knowledge_gap", { dueDate: "" }) },
            { tag: "缺口只缺计划", expected: "知识缺口 · 数学",
              item: item("knowledge_gap", { dueDate: "" }, "数学") },
            { tag: "例行每天", expected: "每日例行 · 英语 · 每天",
              item: item("routine", { weekdays: 127 }, "英语") },
            { tag: "例行工作日无科目", expected: "每日例行 · 工作日",
              item: item("routine", { weekdays: 31 }) },
            { tag: "课表", expected: "课表 · 周四 14:00–15:40 · 第 1–16 周 · 教三 204",
              item: item("schedule_entry", { weekday: 4, startMinutes: 840, endMinutes: 940, weekStart: 1,
                                             weekEnd: 16, weekParity: 0, location: "教三 204" }) },
            { tag: "课表单周无地点", expected: "课表 · 周一 08:00–09:40 · 第 1–8 周 · 单周",
              item: item("schedule_entry", { weekday: 1, startMinutes: 480, endMinutes: 580, weekStart: 1,
                                             weekEnd: 8, weekParity: 1, location: "" }) },
            { tag: "课表双周单周次", expected: "课表 · 周日 10:00–11:40 · 第 3 周 · 双周 · A101",
              item: item("schedule_entry", { weekday: 7, startMinutes: 600, endMinutes: 700, weekStart: 3,
                                             weekEnd: 3, weekParity: 2, location: "A101" }) },
            { tag: "倒计时", expected: "倒计时 · 2026年12月19日",
              item: item("countdown_goal", { targetDate: "2026-12-19" }) }
        ]
    }

    function test_metaTextForEveryKind(data) {
        // 产品保证：八类内容的第二行都是「类型 · 要点」，缺的部分整段省略、不留「 · 」空位；
        // 时长走 Duration.js，重复日与单双周复用现成函数。
        compare(TrashFormat.metaText(data.item, today), data.expected)
    }

    function test_blockedItemsExplainWhy() {
        // 产品保证：不能恢复的项要点写原因；认得类型时前面加类型名，不认得就只写原因。
        var corrupted = item("task", {}, "政治")
        corrupted.restorable = false
        corrupted.blockedReason = "corrupted"
        compare(TrashFormat.metaText(corrupted, today), "任务 · 内容已损坏，无法恢复")
        var newer = item("future_kind", {})
        newer.restorable = false
        newer.blockedReason = "needsUpdate"
        compare(TrashFormat.metaText(newer, today), "需要更新应用后才能恢复")
        var knownNewer = item("memo", {})
        knownNewer.restorable = false
        knownNewer.blockedReason = "needsUpdate"
        compare(TrashFormat.metaText(knownNewer, today), "备忘录 · 需要更新应用后才能恢复")
    }

    function test_restoreFailureTextAddsTheSessionSpanOnlyForConflicts() {
        // 产品保证：专注 / 休息撞时间时，提示在原因前写出这一项的时间段；其它失败只写原因。
        var focus = { title: "线性代数 第 4 讲", details: { startTime: "2026-10-06T14:05:00.000",
                                                           endTime: "2026-10-06T14:50:00.000" } }
        compare(TrashFormat.restoreFailureText(focus, { error: "这段时间已有别的专注记录", conflict: "focus" }, today),
                "没能恢复「线性代数 第 4 讲」：10月6日 14:05–14:50 这段时间已有别的专注记录")
        compare(TrashFormat.restoreFailureText(focus, { error: "这一项的内容已损坏，无法恢复", conflict: "" }, today),
                "没能恢复「线性代数 第 4 讲」：这一项的内容已损坏，无法恢复")
    }
}
