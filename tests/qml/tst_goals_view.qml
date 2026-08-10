pragma ComponentBehavior: Bound

import QtQuick
import QtTest
// 断言选中态用的是哪个语义令牌，需要直接引用 Theme。
import "../../qml"
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
        property int updateCalls: 0
        property int lastUpdatedCategoryId: -1
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
            updateCalls += 1
            lastUpdatedCategoryId = categoryId
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

        property var categoriesData: [{ id: 7, name: "学习", color: "#d4a574" }]

        function getAllCategories() {
            return categoriesData
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

    Component {
        id: heatmapComponent

        GoalHeatmap { width: 360 }
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
        goalService.updateCalls = 0
        goalService.lastUpdatedCategoryId = -1
        goalService.deleteCalls = 0
        goalService.addSucceeds = true
        goalService.deleteSucceeds = true
        goalService.failGoalsQuery = false
        goalService.failGoalQuery = false
        goalService.lastDailyYear = 0
        goalService.lastDailyMonth = 0
        categoryManager.categoriesData = [{ id: 7, name: "学习", color: "#d4a574" }]
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

    function test_card_states_the_pace_facts_and_the_verdict() {
        // 原来这些信息挤在一行副文案里；现在事实归 detailText、判断归 verdict，
        // 两者都要跟着 goal 换。
        var goal = activeGoal()
        goal.deadline = new Date(2026, 11, 19)
        var card = createTemporaryObject(cardComponent, testCase,
                                         { goal: goal, today: new Date(2026, 7, 10) })
        verify(card !== null)
        verify(card.detailText.indexOf("照此速度 21 天完成") >= 0,
               "实际为：" + card.detailText)
        verify(card.detailText.indexOf("距截止 131 天") >= 0)
        compare(card.forecastVerdict.text, "来得及")

        card.goal = achievedGoal()
        tryCompare(card, "detailText", "已达成 · 7 月 20 日")
        compare(card.forecastVerdict.text, "已达成")
    }

    // ListView/GridView 会复用卡片实例。切换到另一个目标时，进度和数字必须在同一帧
    // 使用新目标的数据，不能让进度条继续展示上一个目标的进度。
    // 2026-08-10 列表卡的环形换成横贯进度条，这条随之改测进度条宽度。
    function test_reused_card_updates_progress_immediately() {
        const firstGoal = activeGoal()
        firstGoal.percent = 20
        const card = createTemporaryObject(cardComponent, testCase,
                                           { goal: firstGoal, width: 400 })
        verify(!!card, "Component exists")

        const track = findChild(card, "goalCardProgressTrack")
        const fill = findChild(card, "goalCardProgressFill")
        verify(!!track, "Object exists")
        verify(!!fill, "Object exists")
        verify(track.width > 0)
        compare(Math.round(fill.width), Math.round(track.width * 0.2))

        const nextGoal = activeGoal()
        nextGoal.id = 2
        nextGoal.percent = 80
        card.goal = nextGoal

        compare(card.percent, 80)
        // 同一帧就要是新值：这里刻意用精确比较而不是 tryVerify，
        // 一旦有人给宽度加上过渡动画，这条会立刻转红。
        compare(Math.round(fill.width), Math.round(track.width * 0.8))
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

    function test_edit_losing_category_requires_explicit_reselection() {
        var view = createTemporaryObject(goalsComponent, testCase)
        verify(view !== null)
        var dialog = findChild(view, "goalFormDialog")
        verify(dialog !== null)
        var categoryCombo = findChild(dialog, "goalCategoryCombo")
        var missingHint = findChild(dialog, "goalCategoryMissingHint")
        verify(categoryCombo !== null)
        verify(missingHint !== null)

        dialog.openForEdit(activeGoal())
        tryCompare(dialog, "opened", true)
        compare(categoryCombo.currentIndex, 0)

        categoryManager.categoriesData = [{ id: 8, name: "新科目", color: "#123456" }]
        categoryManager.categoriesChanged()
        tryCompare(categoryCombo, "currentIndex", -1)
        compare(missingHint.text, "原科目已删除，请重新选择")

        compare(dialog.submit(), false)
        compare(goalService.updateCalls, 0)
        compare(dialog.errorText, "请先为目标选择科目")

        categoryCombo.currentIndex = 0
        tryCompare(dialog, "selectedCategoryId", 8)
        compare(dialog.submit(), true)
        compare(goalService.updateCalls, 1)
        compare(goalService.lastUpdatedCategoryId, 8)
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
        var view = createTemporaryObject(goalsComponent, testCase, { width: 640, height: 520 })
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
        // Popup 被临时测试根承载时不保证映射到窗口坐标；用控件真实支持的键盘操作
        // 验证交互，既避开离屏坐标假失败，也覆盖无鼠标用户的同一行为。
        longTermCheck.forceActiveFocus()
        keyClick(Qt.Key_Space)
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

    // 投入量原本只由色块深浅表达，色觉障碍与读屏用户拿不到任何数量信息。
    // 这条锁住非颜色通道：每个当月格子都要能播报出具体番茄数。
    function test_heatmap_exposes_count_without_relying_on_color() {
        const heatmap = createTemporaryObject(heatmapComponent, testCase, {
            year: 2026,
            month: 7,
            today: new Date(2026, 6, 27),
            dailyCounts: [{ day: 9, count: 5 }]
        })
        verify(!!heatmap, "Component exists")

        const busyDay = findChild(heatmap, "goalHeatmapDay-9")
        verify(!!busyDay, "Object exists")
        verify(busyDay.Accessible.name.indexOf("5") >= 0)
        verify(busyDay.Accessible.name.indexOf("9") >= 0)

        const idleDay = findChild(heatmap, "goalHeatmapDay-10")
        verify(!!idleDay, "Object exists")
        verify(idleDay.Accessible.name.length > 0)
        verify(idleDay.Accessible.name.indexOf("无投入") >= 0)

        const todayCell = findChild(heatmap, "goalHeatmapDay-27")
        verify(!!todayCell, "Object exists")
        verify(todayCell.Accessible.name.indexOf("今天") >= 0)
    }

    // 三条视觉修复此前零覆盖，回归了不会有任何提示：
    // 徽章贴边、切换器白框、主按钮与倒计时页不同款。
    function test_card_reserves_padding_on_every_side() {
        const card = createTemporaryObject(cardComponent, testCase, { goal: activeGoal() })
        verify(!!card, "Component exists")
        // 曾经是 0：AbstractButton 默认零内边距，内容会一路铺到描边上。
        // 2026-08-10 改成三层版式后上下也有内容（进度条、结论行），四边都要留。
        // 这条同时挡住「写了个不存在的 Theme.spaceNN」——那种笔误求值为
        // undefined，内边距会静默变回 0，正是本次改版踩到的。
        verify(card.leftPadding > 0)
        verify(card.rightPadding > 0)
        verify(card.topPadding > 0)
        verify(card.bottomPadding > 0)
    }

    function test_view_mode_selection_uses_warm_tint_not_white_block() {
        const view = createTemporaryObject(goalsComponent, testCase)
        verify(!!view, "Component exists")

        const listFill = findChild(view, "goalViewModeFill-list")
        verify(!!listFill, "Object exists")
        // 曾用 glassThumb（浅色下接近纯白），压在壁纸上是一块突兀的白方框。
        compare(String(listFill.color), String(Theme.accentFill))
        verify(String(listFill.color) !== String(Theme.glassThumb))
        // 淡罩本身与轨道只差 1.01:1，选中图标与未选图标也只差 1.21:1——
        // 两条线索都失效时看不出当前是列表还是网格。描边是唯一能过
        // WCAG 1.4.11「状态识别」3:1 的做法（日间 5.84:1、夜间 10.13:1）。
        compare(listFill.border.width, 1)
        compare(String(listFill.border.color), String(Theme.accentFillInk))
    }

    function test_primary_button_matches_countdown_page_metrics() {
        const view = createTemporaryObject(goalsComponent, testCase)
        verify(!!view, "Component exists")

        const newButton = findChild(view, "newGoalButton")
        verify(!!newButton, "Object exists")
        // 尺寸仍与倒计时页「添加目标」同款：108×44。
        compare(newButton.implicitWidth, 108)
        compare(newButton.implicitHeight, 44)
        // 描边此前是 0（「主操作不描边」）。实测 accentFill 压在七套壁纸上
        // 最好 1.26:1、暖色下 1.02:1，远低于 WCAG 1.4.11 对界面组件边界要求的
        // 3:1，按钮整个化进背景。2026-08-10 补一圈 accentFillInk 描边
        // （日间 4.68:1、夜间 10.01:1）。别再按「主操作不描边」改回 0。
        compare(newButton.background.border.width, 1)
        compare(String(newButton.background.border.color), String(Theme.accentFillInk))
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
