pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import "../../qml/components"
import "../../qml/views"

TestCase {
    id: testCase

    name: "GoalsView"
    when: windowShown
    width: 960
    height: 720

    QtObject {
        id: goalService

        signal goalsChanged
        signal operationFailed(string message)

        property int maxTitleLength: 100
        property int maxTargetPomodoros: 9999
        property var goalsData: []
        property int getCalls: 0
        property int addCalls: 0
        property int deleteCalls: 0
        property bool addSucceeds: true
        property bool deleteSucceeds: true
        property bool failGoalsQuery: false
        property bool failGoalQuery: false
        property int lastDailyYear: 0
        property int lastDailyMonth: 0

        function getGoals() {
            getCalls += 1
            if (failGoalsQuery) {
                operationFailed("目标列表查询失败")
                return []
            }
            return goalsData
        }
        function getGoal(goalId) {
            if (failGoalQuery) {
                operationFailed("目标详情查询失败")
                return ({})
            }
            for (var i = 0; i < goalsData.length; ++i) {
                if (Number(goalsData[i].id) === Number(goalId))
                    return goalsData[i]
            }
            return ({})
        }
        function addGoal(title, categoryId, target, startDate, deadline) {
            addCalls += 1
            if (!addSucceeds)
                operationFailed("数据库写入失败")
            return addSucceeds
        }
        function updateGoal(goalId, title, categoryId, target, startDate, deadline) {
            return true
        }
        function getGoalDailyCounts(goalId, year, month) {
            lastDailyYear = year
            lastDailyMonth = month
            return [{ day: 3, count: 1 }, { day: 8, count: 3 }]
        }
        function deleteGoal(goalId) {
            deleteCalls += 1
            if (!deleteSucceeds) {
                operationFailed("删除目标失败")
                return false
            }
            const remaining = []
            for (let i = 0; i < goalsData.length; ++i) {
                if (Number(goalsData[i].id) !== Number(goalId))
                    remaining.push(goalsData[i])
            }
            goalsData = remaining
            goalsChanged()
            return true
        }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged
        signal operationFailed(string message)

        function getAllCategories() {
            return [{ id: 7, name: "学习", color: "#d4a574" }]
        }
    }

    QtObject {
        id: appSettings

        property string goalViewMode: "list"
        property bool reduceMotion: true
        property int dayStartHour: 4
    }

    Component {
        id: goalsComponent

        GoalsView {
            width: 900
            height: 660
            pageActive: true
            goalServiceRef: goalService
            categoryManagerRef: categoryManager
            settingsRef: appSettings
        }
    }

    Component {
        id: inactiveGoalsComponent

        GoalsView {
            width: 900
            height: 660
            // pageActive 必须在组件创建阶段就是 false，才能覆盖真实的后台页面装配路径。
            pageActive: false
            goalServiceRef: goalService
            categoryManagerRef: categoryManager
            settingsRef: appSettings
        }
    }

    Component {
        id: cardComponent

        GoalCard { width: 600 }
    }

    Component {
        id: grid100Component

        Grid100 { width: 360 }
    }

    function activeGoal() {
        return {
            id: 1,
            title: "完成课程",
            categoryId: 7,
            targetPomodoros: 100,
            doneCount: 62,
            percent: 62,
            achieved: false,
            forecastDays: 21
        }
    }

    function achievedGoal() {
        return {
            id: 2,
            title: "读完经典",
            categoryId: 7,
            targetPomodoros: 40,
            doneCount: 40,
            percent: 100,
            achieved: true,
            achievedAt: new Date(2026, 6, 20, 12, 0, 0),
            forecastDays: 0
        }
    }

    function init() {
        goalService.goalsData = []
        goalService.getCalls = 0
        goalService.addCalls = 0
        goalService.deleteCalls = 0
        goalService.addSucceeds = true
        goalService.deleteSucceeds = true
        goalService.failGoalsQuery = false
        goalService.failGoalQuery = false
        goalService.lastDailyYear = 0
        goalService.lastDailyMonth = 0
        appSettings.goalViewMode = "list"
        appSettings.dayStartHour = 4
    }

    function test_default_filter_keeps_only_active_goals() {
        goalService.goalsData = [activeGoal(), achievedGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)

        tryCompare(view, "goalsCount", 1)
        compare(view.filterMode, "active")
        compare(Number(view.filteredGoals[0].id), 1)

        view.setFilterIndex(1)
        tryCompare(view, "goalsCount", 1)
        compare(Number(view.filteredGoals[0].id), 2)

        view.setFilterIndex(2)
        tryCompare(view, "goalsCount", 2)
    }

    function test_view_mode_writes_settings_and_round_trips() {
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        compare(view.viewMode, "list")

        view.setViewMode("grid")
        tryCompare(appSettings, "goalViewMode", "grid")
        tryCompare(view, "viewMode", "grid")

        view.setViewMode("invalid")
        tryCompare(appSettings, "goalViewMode", "list")
    }

    function test_card_secondary_text_uses_forecast_and_achievement_date() {
        var card = createTemporaryObject(cardComponent, testCase, { goal: activeGoal() })
        verify(card !== null)
        compare(card.secondaryText, "62 / 100 番茄 · 照此速度还需 21 天")

        card.goal = achievedGoal()
        tryCompare(card, "secondaryText", "已达成 · 7月20日")
    }

    function test_service_signal_refreshes_only_active_page() {
        goalService.goalsData = [activeGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        tryVerify(function() { return goalService.getCalls > 0 })
        var initialCalls = goalService.getCalls

        goalService.goalsData = [activeGoal(), achievedGoal()]
        goalService.goalsChanged()
        tryVerify(function() { return goalService.getCalls > initialCalls })

        view.pageActive = false
        initialCalls = goalService.getCalls
        goalService.goalsChanged()
        wait(0)
        compare(goalService.getCalls, initialCalls)
    }

    function test_inactive_page_does_not_query_on_construction() {
        var view = createTemporaryObject(inactiveGoalsComponent, testCase)
        verify(view !== null)
        wait(0)
        compare(goalService.getCalls, 0)

        view.pageActive = true
        tryCompare(goalService, "getCalls", 1)
    }

    function test_failed_list_refresh_preserves_data_and_suppresses_empty_state() {
        goalService.goalsData = [activeGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        tryCompare(view, "goalsCount", 1)

        goalService.failGoalsQuery = true
        view.refresh()

        tryCompare(view, "errorText", "目标列表查询失败")
        compare(view.goalsCount, 1)
        const emptyState = findChild(view, "goalsEmptyState")
        verify(emptyState !== null)
        compare(emptyState.shouldShow, false)
    }

    function test_failed_detail_refresh_keeps_open_goal() {
        goalService.goalsData = [activeGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        compare(view.openGoal(1), true)

        goalService.failGoalQuery = true
        view.refreshDetail()

        tryCompare(view, "errorText", "目标详情查询失败")
        compare(view.openGoalId, 1)
        compare(Number(view.detailGoal.id), 1)
    }

    function test_missing_goal_still_closes_detail_after_query_recovers() {
        goalService.goalsData = [activeGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        compare(view.openGoal(1), true)

        // 先经过失败分支，再模拟服务恢复后目标确实被删；两种空 map 不能混为一谈。
        goalService.failGoalQuery = true
        view.refreshDetail()
        compare(view.openGoalId, 1)

        goalService.failGoalQuery = false
        goalService.goalsData = []
        view.refreshDetail()
        compare(view.openGoalId, -1)
    }

    function test_failed_submit_keeps_error_for_correction() {
        goalService.addSucceeds = false
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        var dialog = findChild(view, "goalFormDialog")
        verify(dialog !== null)

        dialog.openForAdd()
        findChild(dialog, "goalTitleField").text = "新的长期目标"
        findChild(dialog, "goalTargetField").text = "20"
        findChild(dialog, "goalStartDateField").text = "2026-07-26"

        compare(dialog.submit(), false)
        compare(goalService.addCalls, 1)
        tryCompare(dialog, "errorText", "数据库写入失败")
        compare(dialog.editingGoalId, -1)
    }

    function test_open_goal_and_return_use_page_substate() {
        goalService.goalsData = [activeGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)

        compare(view.openGoal(1), true)
        tryCompare(view, "openGoalId", 1)
        compare(Number(view.detailGoal.id), 1)

        view.closeGoal()
        tryCompare(view, "openGoalId", -1)
        compare(Number(view.detailGoal.id || -1), -1)
    }

    function test_delete_success_ignores_synchronous_refresh_and_clears_error() {
        goalService.goalsData = [activeGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        compare(view.openGoal(1), true)

        view.requestDeleteDetail()
        compare(view.confirmDeleteDetail(), true)
        compare(view.openGoalId, -1)
        compare(view.errorText, "")
        compare(view.goals.length, 0)
        compare(goalService.deleteCalls, 1)
    }

    function test_delete_failure_is_visible_inside_confirmation() {
        goalService.goalsData = [activeGoal()]
        goalService.deleteSucceeds = false
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        compare(view.openGoal(1), true)

        view.requestDeleteDetail()
        compare(view.confirmDeleteDetail(), false)
        tryCompare(view, "deleteErrorText", "删除目标失败")
        compare(findChild(view, "goalDeleteError").text, "删除目标失败")
        compare(view.openGoalId, 1)
    }

    function test_detail_month_and_today_follow_logical_day() {
        goalService.goalsData = [activeGoal()]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        view.currentDateOverride = new Date(2026, 7, 1, 2, 0, 0)

        compare(view.openGoal(1), true)
        compare(view.detailYear, 2026)
        compare(view.detailMonth, 7)
        compare(view.detailToday.getDate(), 31)
        compare(goalService.lastDailyYear, 2026)
        compare(goalService.lastDailyMonth, 7)
    }

    function test_day_start_zero_is_not_replaced_by_default_four() {
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        view.currentDateOverride = new Date(2026, 7, 1, 2, 0, 0)
        var dialog = findChild(view, "goalFormDialog")
        verify(dialog !== null)

        appSettings.dayStartHour = 0
        compare(dialog.todayIso(), "2026-08-01")
        appSettings.dayStartHour = 4
        compare(dialog.todayIso(), "2026-07-31")
    }

    function test_longTermCheckStaysInSyncAfterUserToggle() {
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        const dialog = findChild(view, "goalFormDialog")
        const longTermCheck = findChild(dialog, "goalLongTermCheck")
        const deadlineField = findChild(dialog, "goalDeadlineField")
        verify(dialog !== null)
        verify(longTermCheck !== null)
        verify(deadlineField !== null)

        dialog.openForAdd()
        tryCompare(dialog, "opened", true)
        compare(longTermCheck.checked, true)
        mouseClick(longTermCheck, longTermCheck.width / 2, longTermCheck.height / 2)
        tryCompare(longTermCheck, "checked", false)
        dialog.close()
        tryCompare(dialog, "opened", false)

        // 点击后残留的 false 与下一个长期目标的 true 相反，才能真正暴露绑定被摧毁。
        const goalWithoutDeadline = activeGoal()
        goalWithoutDeadline.startDate = new Date(2026, 6, 26, 12, 0, 0)
        goalWithoutDeadline.deadline = undefined
        dialog.openForEdit(goalWithoutDeadline)
        tryCompare(dialog, "opened", true)
        compare(longTermCheck.checked, true)
        compare(dialog.longTerm, true)
        compare(deadlineField.enabled, false)
    }

    function test_grid100_normalizes_large_target_with_partial_cell() {
        var grid = createTemporaryObject(grid100Component, testCase,
                                         { doneCount: 25, targetCount: 300 })
        verify(grid !== null)
        tryCompare(grid, "fullCells", 8)
        verify(Math.abs(grid.partialFill - 1 / 3) < 0.001)

        var partialCell = findChild(grid, "grid100Cell-8")
        verify(partialCell !== null)
        verify(Math.abs(partialCell.fillRatio - 1 / 3) < 0.001)
    }

    function test_grid100_marks_only_milestone_cells_when_empty() {
        var grid = createTemporaryObject(grid100Component, testCase,
                                         { doneCount: 0, targetCount: 100 })
        verify(grid !== null)
        var milestones = [24, 49, 74, 99]
        for (var i = 0; i < milestones.length; ++i) {
            var milestoneCell = findChild(grid, "grid100Cell-" + milestones[i])
            verify(milestoneCell !== null)
            verify(milestoneCell.border.width > 0)
        }
        compare(findChild(grid, "grid100Cell-23").border.width, 0)
        compare(findChild(grid, "grid100Cell-25").border.width, 0)
    }

    function test_unknown_forecast_has_no_remaining_days_copy() {
        var goal = activeGoal()
        goal.forecastDays = -1
        goalService.goalsData = [goal]
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)

        compare(view.openGoal(1), true)
        tryCompare(view, "detailForecastText", "")
        verify(view.detailForecastText.indexOf("还需") < 0)
    }
}
