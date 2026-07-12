import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 今日任务页专注目标卡：设置/快捷沿用/失败提示/逻辑日归属都在本页验证。
TestCase {
    id: testCase
    name: "TodayGoalCard"
    when: windowShown
    width: 900
    height: 640

    QtObject {
        id: taskManager

        signal tasksChanged

        function getTodayTasks() {
            return []
        }

        function getOverdueUncompletedTasks() {
            return []
        }

        function setTaskCompleted(id, completed) {
            return true
        }

        function updateTask(id, title, categoryId, date) {
            return true
        }

        function moveTasksToToday(ids) {
            return true
        }
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return { totalDuration: 3600, completedTasks: 0, totalTasks: 0, completionRate: 0 }
        }
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)

        property int phase: 0
        property bool hasActiveSession: false
        property int elapsedSeconds: 0
    }

    QtObject {
        id: routineManager

        signal routinesChanged

        function materializeToday() {
        }
    }

    QtObject {
        id: logicalDayService

        signal changed
    }

    QtObject {
        id: appSettings

        signal dailyFocusGoalChanged

        property int dayStartHour: 4
        property bool reduceMotion: true
        property string rolloverIgnoredDate: ""
        property string focusGoalDate: ""
        property int focusGoalMinutes: 0
        property bool focusGoalSaveSucceeds: true

        function dailyFocusGoalMinutesForDate(isoDate) {
            return isoDate === focusGoalDate ? focusGoalMinutes : 0
        }

        function setDailyFocusGoal(isoDate, minutes) {
            if (!focusGoalSaveSucceeds)
                return false
            focusGoalDate = isoDate
            focusGoalMinutes = minutes
            dailyFocusGoalChanged()
            return true
        }
    }

    Component {
        id: todayViewComponent

        TodayTaskView {
            width: 860
            height: 600
            settingsRef: appSettings
        }
    }

    function init() {
        appSettings.focusGoalDate = ""
        appSettings.focusGoalMinutes = 0
        appSettings.focusGoalSaveSucceeds = true
        focusTimer.phase = 0
        focusTimer.hasActiveSession = false
        focusTimer.elapsedSeconds = 0
    }

    function test_card_is_editable_and_starts_unset() {
        var view = createTemporaryObject(todayViewComponent, testCase)
        verify(view)

        var card = findChild(view, "todayGoalCard")
        verify(card)
        compare(card.editable, true)
        compare(card.hasGoal, false)
        compare(view.dailyFocusGoalMinutes, 0)

        // 只读引导链接是仪表盘实例的东西，本页不出现。
        card.beginEditing()
        compare(card.editing, true)
    }

    function test_save_binds_to_logical_today() {
        var view = createTemporaryObject(todayViewComponent, testCase)
        verify(view)

        var card = findChild(view, "todayGoalCard")
        verify(card)
        card.goalSubmitted(150)

        compare(appSettings.focusGoalDate, view.todayIsoDate())
        compare(appSettings.focusGoalMinutes, 150)
        // 保存成功后经 dailyFocusGoalChanged 信号回读，展示与存储一致。
        compare(view.dailyFocusGoalMinutes, 150)
        compare(card.hasGoal, true)
        compare(card.saveError, "")
    }

    function test_save_failure_shows_error_and_keeps_unset() {
        appSettings.focusGoalSaveSucceeds = false
        var view = createTemporaryObject(todayViewComponent, testCase)
        verify(view)

        var card = findChild(view, "todayGoalCard")
        verify(card)
        card.goalSubmitted(150)

        verify(card.saveError.length > 0)
        compare(view.dailyFocusGoalMinutes, 0)
    }

    function test_quick_fill_uses_yesterday_goal() {
        var view = createTemporaryObject(todayViewComponent, testCase)
        verify(view)

        // 跨日后的单键快照日期 == 昨天，正是快捷 chip 的数据源。
        appSettings.focusGoalDate = view.yesterdayIsoDate()
        appSettings.focusGoalMinutes = 300
        view.loadDailyFocusGoal()

        var card = findChild(view, "todayGoalCard")
        verify(card)
        compare(view.dailyFocusGoalMinutes, 0)
        compare(card.quickFillMinutes, 300)
        compare(card.quickFillFromYesterday, true)
        compare(card.quickFillValue, 300)

        // 点快捷 chip 等价于提交昨天的值：落到今天。
        card.goalSubmitted(card.quickFillValue)
        compare(appSettings.focusGoalDate, view.todayIsoDate())
        compare(appSettings.focusGoalMinutes, 300)
        compare(view.dailyFocusGoalMinutes, 300)
    }

    function test_quick_fill_falls_back_to_recommendation() {
        var view = createTemporaryObject(todayViewComponent, testCase)
        verify(view)

        var card = findChild(view, "todayGoalCard")
        verify(card)
        // 昨天也没有目标：chip 回落推荐 4 小时。
        compare(card.quickFillFromYesterday, false)
        compare(card.quickFillValue, 240)
    }

    function test_live_seconds_follow_shared_source() {
        var view = createTemporaryObject(todayViewComponent, testCase)
        verify(view)

        var card = findChild(view, "todayGoalCard")
        verify(card)
        // 落库 3600 秒（统计桩），无进行中会话。
        compare(card.totalSeconds, 3600)

        focusTimer.phase = 1
        focusTimer.elapsedSeconds = 120
        compare(card.totalSeconds, 3720)

        // 休息阶段不累计。
        focusTimer.phase = 2
        compare(card.totalSeconds, 3600)
    }
}
