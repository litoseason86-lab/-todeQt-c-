import QtQuick
import QtTest
import "../../qml/GoalForecast.js" as GoalForecast

// 目标页新增的「按这个速度来不来得及」。此前界面只给 forecastDays 和 deadline
// 两个数，让用户自己心算；现在列表和网格共用这一份判断，所以它必须是纯函数且被钉死。
//
// forecastDays 的口径来自 GoalService::forecastDaysFor：
//   0=已完成、-1=还没有数据推算不了、>0=按当前速度还需的天数。
TestCase {
    id: testCase
    name: "GoalForecast"

    readonly property var today: new Date(2026, 7, 10)   // 2026-08-10

    function goalWith(props) {
        var g = { id: 1, title: "目标", doneCount: 50, targetPomodoros: 100,
                  percent: 50, achieved: false, forecastDays: 30 }
        for (var k in props) g[k] = props[k]
        return g
    }

    function test_achieved_wins_over_everything() {
        // 已达成就不该再谈快慢，哪怕截止日早就过了。
        var v = GoalForecast.verdict(
                    goalWith({ achieved: true, deadline: new Date(2026, 0, 1),
                               forecastDays: 0 }), testCase.today)
        compare(v.text, "已达成")
        compare(v.tone, "good")
    }

    function test_no_deadline_is_a_normal_configuration_not_a_warning() {
        // 不设截止日是「长期投入」这种正常配置，不是缺数据，不能报警。
        var v = GoalForecast.verdict(goalWith({ deadline: undefined }), testCase.today)
        compare(v.text, "长期")
        compare(v.tone, "muted")
    }

    function test_on_track_when_forecast_fits_before_deadline() {
        // 还需 30 天，距截止 40 天 → 来得及。
        var v = GoalForecast.verdict(
                    goalWith({ forecastDays: 30, deadline: new Date(2026, 8, 19) }),
                    testCase.today)
        compare(v.text, "来得及")
        compare(v.tone, "good")
    }

    function test_edge_of_exactly_meeting_the_deadline_counts_as_on_track() {
        // 还需 40 天，距截止正好 40 天：卡点完成也算来得及，不能判成偏慢。
        var v = GoalForecast.verdict(
                    goalWith({ forecastDays: 40, deadline: new Date(2026, 8, 19) }),
                    testCase.today)
        compare(v.text, "来得及")
    }

    function test_behind_reports_how_many_days_short() {
        // 还需 60 天，距截止 40 天 → 偏慢 20 天。差多少必须说出来，
        // 只说「偏慢」用户不知道要加多少量。
        var v = GoalForecast.verdict(
                    goalWith({ forecastDays: 60, deadline: new Date(2026, 8, 19) }),
                    testCase.today)
        compare(v.text, "偏慢 20 天")
        compare(v.tone, "warn")
    }

    function test_no_pace_data_says_so_instead_of_inventing_a_number() {
        // forecastDays 为 -1 表示还没有任何有效番茄。这时不能编一个天数，
        // 也不能因为「算不出来」就报警。
        var v = GoalForecast.verdict(
                    goalWith({ forecastDays: -1, doneCount: 0,
                               deadline: new Date(2026, 8, 19) }), testCase.today)
        compare(v.text, "暂无预测")
        compare(v.tone, "muted")
    }

    function test_past_deadline_reports_overdue_days() {
        var v = GoalForecast.verdict(
                    goalWith({ deadline: new Date(2026, 6, 31) }), testCase.today)
        compare(v.text, "已超期 10 天")
        compare(v.tone, "warn")
    }

    function test_detail_states_facts_without_judging() {
        var d = GoalForecast.detail(
                    goalWith({ forecastDays: 21, deadline: new Date(2026, 11, 19) }),
                    testCase.today)
        compare(d, "照此速度 21 天完成 · 距截止 131 天")

        compare(GoalForecast.detail(goalWith({ forecastDays: 68, deadline: undefined }),
                                    testCase.today),
                "照此速度 68 天完成 · 未设截止日")

        compare(GoalForecast.detail(goalWith({ forecastDays: -1, deadline: undefined }),
                                    testCase.today),
                "还没有专注记录，暂时无法预测 · 未设截止日")

        compare(GoalForecast.detail(goalWith({ achieved: true,
                                               achievedAt: new Date(2026, 7, 1) }),
                                    testCase.today),
                "已达成 · 8 月 1 日")
    }

    function test_day_difference_ignores_time_of_day() {
        // 逻辑日基准带时分秒时不能把「同一天」算成差一天。
        var noon = new Date(2026, 7, 10, 13, 45, 0)
        compare(GoalForecast.daysBetween(noon, new Date(2026, 7, 11, 1, 0, 0)), 1)
        compare(GoalForecast.daysBetween(noon, new Date(2026, 7, 10, 23, 59, 0)), 0)
    }
}
