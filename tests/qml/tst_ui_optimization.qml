import QtQuick
import QtTest
import "../../qml/components"
import "../../qml/views"
import "../../qml"

TestCase {
    id: testCase
    name: "UiOptimization"
    when: windowShown
    width: 480
    height: 180

    TaskItem {
        id: taskItem

        width: 420
        taskId: 42
        taskTitle: "测试任务"
        taskCategory: ({
                name: "数学",
                color: "#d4a574"
            })
    }

    TaskItem {
        id: initiallyCompletedTaskItem

        width: 420
        visible: false
        taskId: 43
        taskTitle: "初始已完成任务"
        taskCompleted: true
    }

    AddTaskDialog {
        id: addTaskDialog
    }

    QtObject {
        id: taskManager

        signal tasksChanged

        property var fakeTodayTasks: []
        property var fakeWeekTasks: []
        property bool setTaskCompletedResult: true
        property int setTaskCompletedCallCount: 0

        function getTodayTasks() {
            return fakeTodayTasks;
        }

        function getWeekTasks(weekStart) {
            return fakeWeekTasks;
        }

        function getMonthTasks(year, month) {
            return [];
        }

        function addTask(title, date, categoryId) {
        }

        function setTaskCompleted(id, completed) {
            setTaskCompletedCallCount += 1;
            if (!setTaskCompletedResult)
                return false;

            for (var i = 0; i < fakeTodayTasks.length; ++i) {
                if (fakeTodayTasks[i].id === id)
                    fakeTodayTasks[i].completed = completed;
            }
            for (var j = 0; j < fakeWeekTasks.length; ++j) {
                if (fakeWeekTasks[j].id === id)
                    fakeWeekTasks[j].completed = completed;
            }

            tasksChanged();
            return true;
        }

        function deleteTask(id) {
            return true;
        }
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)

        function startFocus(id, title) {
            return true;
        }
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return {
                totalDuration: 0,
                completedTasks: 0,
                totalTasks: 0,
                completionRate: 0
            };
        }

        function makeComparison(displayText, trend) {
            return {
                hasData: true,
                displayText: displayText,
                trend: trend
            };
        }

        function getDayComparison(date) {
            return {
                taskCompletion: makeComparison("→ 0% vs 昨天", 0),
                sessionCount: makeComparison("→ 0% vs 昨天", 0),
                duration: makeComparison("→ 0% vs 昨天", 0)
            };
        }

        function getWeekComparison(weekStart) {
            return {
                effectiveDays: makeComparison("→ 0% vs 上周", 0),
                sessionCount: makeComparison("→ 0% vs 上周", 0),
                duration: makeComparison("→ 0% vs 上周", 0)
            };
        }

        function getMonthComparison(year, month) {
            return {
                effectiveDays: makeComparison("→ 0% vs 上月", 0),
                sessionCount: makeComparison("→ 0% vs 上月", 0),
                duration: makeComparison("→ 0% vs 上月", 0)
            };
        }
    }

    TodayTaskView {
        id: todayTaskView

        width: 620
        height: 420
        visible: false
    }

    WeekPlanView {
        id: weekPlanView

        width: 620
        height: 520
        visible: false
    }

    MonthGoalView {
        id: monthGoalView

        width: 920
        height: 620
        visible: false
    }

    function init() {
        taskManager.fakeTodayTasks = [];
        taskManager.fakeWeekTasks = [];
        taskManager.setTaskCompletedResult = true;
        taskManager.setTaskCompletedCallCount = 0;
        var container = findChild(taskItem, "completionParticleContainer");
        if (container !== null && container.particleCount > 0)
            tryCompare(container, "particleCount", 0, 1000);

        taskItem.taskCompleted = false;
        taskItem.opacity = 1.0;
        todayTaskView.visible = false;
        weekPlanView.visible = false;
        monthGoalView.visible = false;
        addTaskDialog.close();
        if (typeof taskItem.setPointerInside === "function")
            taskItem.setPointerInside(false);
        var focusButton = findChild(taskItem, "focusButton");
        var deleteButton = findChild(taskItem, "taskDeleteButton");
        if (focusButton !== null)
            focusButton.down = false;
        if (deleteButton !== null)
            deleteButton.down = false;
        wait(220);
    }

    function configureSingleTodayTask(completed) {
        taskManager.fakeTodayTasks = [{
                id: 101,
                title: "真实点击链路任务",
                date: new Date(),
                completed: completed,
                categoryText: "测试"
            }];
        todayTaskView.visible = true;
        todayTaskView.refresh();
        tryCompare(todayTaskView, "tasks", taskManager.fakeTodayTasks, 220);
    }

    function configureSingleWeekTask(completed) {
        var taskDate = weekPlanView.isoDate(weekPlanView.weekStart);
        taskManager.fakeWeekTasks = [{
                id: 201,
                title: "周计划真实点击链路任务",
                date: taskDate,
                completed: completed,
                categoryText: "测试"
            }];
        weekPlanView.visible = true;
        weekPlanView.refresh();
        tryCompare(weekPlanView, "weekTasks", taskManager.fakeWeekTasks, 220);
    }

    function verifyNear(actual, expected, tolerance, message) {
        verify(Math.abs(actual - expected) <= tolerance,
               message + "，实际值：" + actual + "，期望值：" + expected);
    }

    function verifyWarmShadow(target, expectedOpacity, expectedBlur, expectedVerticalOffset, context) {
        verify(target !== null, context + "需要存在阴影承载对象");
        verify(typeof target.warmShadowColor !== "undefined", context + "需要暴露暖色阴影颜色");
        verify(typeof target.warmShadowOpacity !== "undefined", context + "需要暴露阴影透明度");
        verify(typeof target.warmShadowBlur !== "undefined", context + "需要暴露阴影模糊值");
        verify(typeof target.warmShadowVerticalOffset !== "undefined", context + "需要暴露阴影垂直偏移");
        verify(Qt.colorEqual(target.warmShadowColor, "#5d4e37"), context + "需要使用暖色阴影");
        verifyNear(target.warmShadowOpacity, expectedOpacity, 0.015, context + " shadowOpacity");
        verifyNear(target.warmShadowBlur, expectedBlur, 0.015, context + " shadowBlur");
        verifyNear(target.warmShadowVerticalOffset, expectedVerticalOffset, 0.15, context + " shadowVerticalOffset");
    }

    function test_taskItemUsesStandardQt6ShadowMetadata() {
        compare(taskItem.layer.enabled, true);
        verify(taskItem.layer.effect !== null);
        compare(taskItem.layer.effect.status, Component.Ready);
        verify(String(taskItem.layer.effect).indexOf("ShaderEffect") === -1);
    }

    function test_taskItemUsesWarmShadowAndAnimatesHoverParameters() {
        verifyWarmShadow(taskItem, 0.08, 0.18, 2, "TaskItem 普通状态");

        taskItem.setPointerInside(true);
        tryCompare(taskItem, "itemHovered", true, 220);
        wait(240);

        verifyWarmShadow(taskItem, 0.12, 0.25, 6, "TaskItem hover 状态");

        taskItem.setPointerInside(false);
        tryCompare(taskItem, "itemHovered", false, 220);
        wait(240);

        verifyWarmShadow(taskItem, 0.08, 0.18, 2, "TaskItem hover 离开后");
    }

    function test_taskItemCompletedOpacityTargetIsSeventyPercent() {
        taskItem.taskCompleted = true;
        wait(260);

        verify(Math.abs(taskItem.opacity - 0.70) <= 0.02);
    }

    function test_taskItemCheckBoxAndTitleUseOptimizedStructure() {
        var taskCheckBox = findChild(taskItem, "taskCheckBox");
        var taskCheckIndicator = findChild(taskItem, "taskCheckIndicator");
        var taskTitleText = findChild(taskItem, "taskTitleText");

        verify(taskCheckBox !== null);
        verify(taskCheckIndicator !== null);
        verify(taskTitleText !== null);
        compare(taskCheckIndicator.implicitWidth, 20);
        compare(taskCheckIndicator.implicitHeight, 20);
        compare(taskCheckIndicator.radius, 4);
        verify(taskCheckIndicator.border.width >= 1.5);
        compare(taskTitleText.font.weight, Font.Medium);
        compare(taskTitleText.lineHeight, 1.4);

        taskItem.taskCompleted = true;
        wait(260);

        compare(taskCheckBox.checked, true);
        compare(taskTitleText.font.strikeout, true);
    }

    function completionParticleContainer() {
        return findChild(taskItem, "completionParticleContainer");
    }

    function initiallyCompletedParticleContainer() {
        return findChild(initiallyCompletedTaskItem, "completionParticleContainer");
    }

    function verifyCompletionParticle(particle, index, expectedDirectionX, expectedDirectionY) {
        var expectedColors = ["#d4a574", "#e8dfc8", "#f0e6d2"];

        verify(particle !== null, "完成粒子需要存在");
        compare(particle.objectName, "completionParticle");
        compare(particle.width, 5);
        compare(particle.height, 5);
        compare(particle.radius, 2.5);
        verify(Qt.colorEqual(particle.color, expectedColors[index % expectedColors.length]));
        compare(particle.directionX, expectedDirectionX);
        compare(particle.directionY, expectedDirectionY);
        verify(Math.abs(particle.targetX - particle.startX) >= 35);
        verify(Math.abs(particle.targetX - particle.startX) <= 40);
        if (expectedDirectionY === 0) {
            verifyNear(particle.targetY - particle.startY, 0, 0.5, "水平完成粒子的 y 位移");
        } else {
            verify(Math.abs(particle.targetY - particle.startY) >= 35);
            verify(Math.abs(particle.targetY - particle.startY) <= 40);
        }
    }

    function test_taskItemCompletionCreatesSixWarmParticlesAndCleansUp() {
        var container = completionParticleContainer();
        verify(container !== null);
        compare(container.particleCount, 0);

        taskItem.taskCompleted = true;
        tryCompare(container, "particleCount", 6, 120);

        var directions = [
            [-1, -1],
            [-1, 0],
            [-1, 1],
            [1, -1],
            [1, 0],
            [1, 1]
        ];
        for (var i = 0; i < directions.length; ++i)
            verifyCompletionParticle(container.children[i], i, directions[i][0], directions[i][1]);

        tryCompare(container, "particleCount", 0, 950);
    }

    function test_taskItemCompletionParticlesStartAtVisibleIndicatorCenter() {
        var container = completionParticleContainer();
        var taskCheckIndicator = findChild(taskItem, "taskCheckIndicator");
        verify(container !== null);
        verify(taskCheckIndicator !== null);

        taskItem.taskCompleted = true;
        tryCompare(container, "particleCount", 6, 120);

        var firstParticle = container.children[0];
        var indicatorPosition = taskCheckIndicator.mapToItem(taskItem, 0, 0);
        var expectedStartX = indicatorPosition.x + taskCheckIndicator.width / 2 - firstParticle.width / 2;
        var expectedStartY = indicatorPosition.y + taskCheckIndicator.height / 2 - firstParticle.height / 2;

        verifyNear(firstParticle.startX, expectedStartX, 0.5, "完成粒子起点 x 应对齐可见复选框中心");
        verifyNear(firstParticle.startY, expectedStartY, 0.5, "完成粒子起点 y 应对齐可见复选框中心");
        tryCompare(container, "particleCount", 0, 950);
    }

    function test_taskItemCompletionParticlesDoNotStackDuringRapidToggle() {
        var container = completionParticleContainer();
        verify(container !== null);

        taskItem.taskCompleted = true;
        tryCompare(container, "particleCount", 6, 120);

        taskItem.taskCompleted = false;
        wait(40);
        taskItem.taskCompleted = true;
        wait(120);
        compare(container.particleCount, 6);

        tryCompare(container, "particleCount", 0, 950);

        taskItem.taskCompleted = false;
        wait(220);
        taskItem.taskCompleted = true;
        tryCompare(container, "particleCount", 6, 120);
        tryCompare(container, "particleCount", 0, 950);
    }

    function test_taskItemInitialCompletedStateDoesNotPlayCompletionParticles() {
        var container = initiallyCompletedParticleContainer();
        verify(container !== null);

        wait(900);
        compare(initiallyCompletedTaskItem.taskCompleted, true);
        compare(container.particleCount, 0);
    }

    function test_taskItemCancelCompletionRestoresOpacityAndStrikeout() {
        var taskTitleText = findChild(taskItem, "taskTitleText");
        verify(taskTitleText !== null);

        taskItem.taskCompleted = true;
        wait(260);
        verify(Math.abs(taskItem.opacity - 0.70) <= 0.02);
        compare(taskTitleText.font.strikeout, true);

        taskItem.taskCompleted = false;
        wait(220);
        verify(Math.abs(taskItem.opacity - 1.0) <= 0.02);
        compare(taskTitleText.font.strikeout, false);
    }

    function test_taskItemCompletionParticlesDoNotPlayOnCancelAndReplayAfterRecheck() {
        var container = completionParticleContainer();
        verify(container !== null);

        taskItem.taskCompleted = true;
        tryCompare(container, "particleCount", 6, 120);
        tryCompare(container, "particleCount", 0, 950);

        taskItem.taskCompleted = false;
        wait(120);
        compare(container.particleCount, 0);

        taskItem.taskCompleted = true;
        tryCompare(container, "particleCount", 6, 120);
        tryCompare(container, "particleCount", 0, 950);
    }

    function test_todayTaskViewRealClickKeepsCompletionParticlesAcrossSynchronousRefresh() {
        configureSingleTodayTask(false);

        var taskCheckBox = findChild(todayTaskView, "taskCheckBox");
        var container = findChild(todayTaskView, "completionParticleContainer");
        verify(taskCheckBox !== null);
        verify(container !== null);
        compare(container.particleCount, 0);

        taskCheckBox.forceActiveFocus();
        keyClick(Qt.Key_Space);

        compare(taskManager.setTaskCompletedCallCount, 1);
        compare(taskManager.fakeTodayTasks[0].completed, true);
        tryCompare(container, "particleCount", 6, 160);

        tryCompare(todayTaskView, "completionRefreshDelayActive", false, 1100);
        tryCompare(todayTaskView, "tasks", taskManager.fakeTodayTasks, 1000);
        compare(todayTaskView.tasks[0].completed, true);
        var refreshedContainer = findChild(todayTaskView, "completionParticleContainer");
        verify(refreshedContainer !== null);
        compare(refreshedContainer.particleCount, 0);
        compare(taskManager.setTaskCompletedCallCount, 1);
    }

    function test_todayTaskViewCompletionFailureCancelsDelayedRefreshAndRestoresUncheckedState() {
        configureSingleTodayTask(false);
        taskManager.setTaskCompletedResult = false;

        var taskCheckBox = findChild(todayTaskView, "taskCheckBox");
        verify(taskCheckBox !== null);

        taskCheckBox.forceActiveFocus();
        keyClick(Qt.Key_Space);

        compare(taskManager.setTaskCompletedCallCount, 1);
        compare(taskManager.fakeTodayTasks[0].completed, false);
        compare(todayTaskView.completionRefreshDelayActive, false);
        compare(todayTaskView.loadError, "任务完成失败，请重试");

        var restoredCheckBox = findChild(todayTaskView, "taskCheckBox");
        verify(restoredCheckBox !== null);
        compare(restoredCheckBox.checked, false);
    }

    function test_weekPlanViewRealClickKeepsCompletionParticlesAcrossSynchronousRefresh() {
        configureSingleWeekTask(false);

        var taskCheckBox = findChild(weekPlanView, "taskCheckBox");
        var container = findChild(weekPlanView, "completionParticleContainer");
        verify(taskCheckBox !== null);
        verify(container !== null);
        compare(container.particleCount, 0);

        taskCheckBox.forceActiveFocus();
        keyClick(Qt.Key_Space);

        compare(taskManager.setTaskCompletedCallCount, 1);
        compare(taskManager.fakeWeekTasks[0].completed, true);
        tryCompare(container, "particleCount", 6, 160);

        tryCompare(weekPlanView, "completionRefreshDelayActive", false, 1100);
        tryCompare(weekPlanView, "weekTasks", taskManager.fakeWeekTasks, 1000);
        compare(weekPlanView.weekTasks[0].completed, true);
        var refreshedContainer = findChild(weekPlanView, "completionParticleContainer");
        verify(refreshedContainer !== null);
        compare(refreshedContainer.particleCount, 0);
        compare(taskManager.setTaskCompletedCallCount, 1);
    }

    function test_focusButtonStatesLoadAndCompletedDisablesAction() {
        var focusButton = findChild(taskItem, "focusButton");
        var focusButtonBackground = findChild(taskItem, "focusButtonBackground");
        var focusButtonLabel = findChild(taskItem, "focusButtonLabel");

        verify(focusButton !== null);
        verify(focusButtonBackground !== null);
        verify(focusButtonLabel !== null);
        compare(focusButton.implicitWidth, 104);
        compare(focusButton.implicitHeight, 40);
        compare(focusButtonBackground.radius, 6);

        compare(focusButton.text, "开始专注");
        compare(focusButton.enabled, true);
        compare(focusButtonLabel.font.weight, Font.Medium);

        taskItem.taskCompleted = true;
        wait(260);

        compare(focusButton.text, "已完成");
        compare(focusButton.enabled, false);
    }

    function test_taskItemButtonsUsePressedDepthAndWarmShadow() {
        verifyButtonPressedFeedback("focusButton", "focusButtonBackground", "focusButtonLabel", "专注按钮");
        verifyButtonPressedFeedback("taskDeleteButton", "taskDeleteButtonBackground", "taskDeleteButtonLabel", "删除按钮");
    }

    function verifyButtonPressedFeedback(buttonName, backgroundName, labelName, context) {
        var button = findChild(taskItem, buttonName);
        var background = findChild(taskItem, backgroundName);
        var label = findChild(taskItem, labelName);

        verify(button !== null, context + "需要存在按钮");
        verify(background !== null, context + "需要存在背景");
        verify(label !== null, context + "需要存在文字");
        compare(background.layer.enabled, true);
        verify(background.layer.effect !== null, context + "需要存在按钮背景 MultiEffect");
        verifyWarmShadow(background, 0.08, 0.14, 2, context + "普通状态");
        verifyNear(background.y, 0, 0.05, context + "普通状态背景 y");
        verifyNear(label.scale, 1.0, 0.005, context + "普通状态文字缩放");

        button.down = true;
        tryCompare(button, "down", true, 220);
        wait(130);

        verifyWarmShadow(background, 0.04, 0.10, 1, context + "按下状态");
        verifyNear(background.y, 1, 0.05, context + "按下状态背景 y");
        verifyNear(label.scale, 0.98, 0.005, context + "按下状态文字缩放");

        button.down = false;
        tryCompare(button, "down", false, 220);
        wait(130);

        verifyWarmShadow(background, 0.08, 0.14, 2, context + "释放后");
        verifyNear(background.y, 0, 0.05, context + "释放后背景 y");
        verifyNear(label.scale, 1.0, 0.005, context + "释放后文字缩放");
    }

    function test_taskItemExposesDeleteAction() {
        var deleteButton = findChild(taskItem, "taskDeleteButton");
        var deleteButtonBackground = findChild(taskItem, "taskDeleteButtonBackground");

        verify(deleteButton !== null);
        verify(deleteButtonBackground !== null);
        compare(deleteButton.text, "删除");
        compare(deleteButtonBackground.radius, 6);

        var deletedTaskId = -1;
        var deletedTaskTitle = "";
        // 不点真实数据库，只验证 TaskItem 会把正确的任务信息发出来。
        taskItem.deleteClicked.connect(function (taskId, title) {
            deletedTaskId = taskId;
            deletedTaskTitle = title;
        });

        deleteButton.clicked();

        compare(deletedTaskId, 42);
        compare(deletedTaskTitle, "测试任务");
    }

    function test_addTaskDialogUsesOptimizedPanelAndInputStates() {
        addTaskDialog.open();
        wait(260);

        var dialogPanel = addTaskDialog.background;
        var titleField = findChild(addTaskDialog, "titleField");
        var titleFieldBackground = findChild(addTaskDialog, "titleFieldBackground");
        var categoryComboBackground = findChild(addTaskDialog, "categoryComboBackground");
        var cancelButton = findChild(addTaskDialog, "cancelButton");
        var cancelButtonBackground = findChild(addTaskDialog, "cancelButtonBackground");
        var submitButton = findChild(addTaskDialog, "submitButton");
        var submitButtonBackground = findChild(addTaskDialog, "submitButtonBackground");

        verify(dialogPanel !== null);
        verify(titleField !== null);
        verify(titleFieldBackground !== null);
        verify(categoryComboBackground !== null);
        verify(cancelButton !== null);
        verify(cancelButtonBackground !== null);
        verify(submitButton !== null);
        verify(submitButtonBackground !== null);

        compare(dialogPanel.objectName, "dialogPanel");
        compare(dialogPanel.radius, 8);
        verify(Qt.colorEqual(dialogPanel.color, "#fffef9"));
        verify(Qt.colorEqual(dialogPanel.border.color, "#e8dfc8"));
        compare(dialogPanel.layer.enabled, true);
        verify(dialogPanel.layer.effect !== null);

        compare(titleFieldBackground.radius, 6);
        verify(Qt.colorEqual(titleFieldBackground.color, "#faf8f3"));

        compare(categoryComboBackground.radius, 6);
        compare(cancelButtonBackground.radius, 6);
        compare(submitButtonBackground.radius, 6);
        compare(cancelButton.contentItem.font.weight, Font.Medium);
        compare(submitButton.contentItem.font.weight, Font.Medium);

        addTaskDialog.submit();
        wait(220);

        verify(titleField.activeFocus);
        verify(Qt.colorEqual(titleFieldBackground.border.color, "#c46f5f"));
        compare(titleFieldBackground.border.width, 2);
    }

    function test_todayTaskViewUsesOptimizedCardsAndControls() {
        wait(80);

        var description = findChild(todayTaskView, "todayDescriptionText");
        var addButton = findChild(todayTaskView, "todayAddButton");
        var addButtonBackground = findChild(todayTaskView, "todayAddButtonBackground");
        var addButtonLabel = findChild(todayTaskView, "todayAddButtonLabel");
        var focusStatCard = findChild(todayTaskView, "todayFocusStatCard");
        var completionStatCard = findChild(todayTaskView, "todayCompletionStatCard");
        var taskListContainer = findChild(todayTaskView, "todayTaskListContainer");
        var emptyStateCard = findChild(todayTaskView, "todayEmptyStateCard");
        var emptyStateIcon = findChild(todayTaskView, "todayEmptyStateIcon");

        verify(description !== null);
        verify(addButton !== null);
        verify(addButtonBackground !== null);
        verify(addButtonLabel !== null);
        verify(focusStatCard !== null);
        verify(completionStatCard !== null);
        verify(taskListContainer !== null);
        verify(emptyStateCard !== null);
        verify(emptyStateIcon !== null);

        verify(Qt.colorEqual(description.color, Theme.ink));
        compare(addButtonBackground.radius, Theme.radiusLg);
        verify(Qt.colorEqual(addButtonBackground.color, Theme.accent));
        compare(addButtonBackground.border.width, 0);
        compare(addButtonLabel.font.weight, Font.Medium);

        compare(focusStatCard.radius, 8);
        compare(completionStatCard.radius, 8);
        compare(focusStatCard.layer.enabled, true);
        compare(completionStatCard.layer.enabled, true);
        verify(focusStatCard.layer.effect !== null);
        verify(completionStatCard.layer.effect !== null);

        compare(taskListContainer.radius, 8);
        compare(taskListContainer.layer.enabled, true);
        verify(taskListContainer.layer.effect !== null);
        compare(emptyStateCard.radius, 8);
        compare(emptyStateIcon.radius, 8);
    }

    function test_monthGoalViewUsesOptimizedCalendarAndPanels() {
        monthGoalView.visible = true;
        wait(80);

        var previousButton = findChild(monthGoalView, "monthPreviousButton");
        var currentButton = findChild(monthGoalView, "monthCurrentButton");
        var nextButton = findChild(monthGoalView, "monthNextButton");
        var previousButtonBackground = findChild(monthGoalView, "monthPreviousButtonBackground");
        var calendarContainer = findChild(monthGoalView, "monthCalendarContainer");
        var timelinePanel = findChild(monthGoalView, "focusTimelinePanel");
        var timelineTitle = findChild(monthGoalView, "focusTimelineTitle");
        var emptyState = findChild(monthGoalView, "focusHistoryEmptyState");
        var timelineScrollView = findChild(monthGoalView, "focusTimelineScrollView");
        var monthContentStack = findChild(monthGoalView, "monthContentStack");
        var selectedDayCell = findChild(monthGoalView, "monthDayCell-" + monthGoalView.selectedDay);
        var selectedDayDuration = findChild(monthGoalView, "monthDayDuration-" + monthGoalView.selectedDay);

        verify(previousButton !== null);
        verify(currentButton !== null);
        verify(nextButton !== null);
        verify(previousButtonBackground !== null);
        verify(calendarContainer !== null);
        verify(timelinePanel !== null);
        verify(timelineTitle !== null);
        verify(emptyState !== null);
        verify(timelineScrollView !== null);
        verify(monthContentStack !== null);
        verify(selectedDayCell !== null);
        verify(selectedDayDuration !== null);

        // 专注历史页已经移除旧“月度目标”的任务统计和添加任务入口。
        compare(findChild(monthGoalView, "monthTotalStatCard"), null);
        compare(findChild(monthGoalView, "monthCompletedStatCard"), null);
        compare(findChild(monthGoalView, "monthRateStatCard"), null);
        compare(findChild(monthGoalView, "monthDetailAddButton"), null);

        compare(previousButtonBackground.radius, 8);

        compare(calendarContainer.radius, 8);
        compare(calendarContainer.layer.enabled, true);
        verify(calendarContainer.layer.effect !== null);
        verify(calendarContainer.width > 0);
        verify(calendarContainer.height >= 520);
        compare(timelinePanel.radius, 8);
        compare(timelinePanel.layer.enabled, true);
        verify(timelinePanel.layer.effect !== null);
        // 宽屏下专注历史应使用左右布局，否则右侧空白、时间轴被挤到首屏之外。
        verify(timelinePanel.x > calendarContainer.x + calendarContainer.width);
        verify(Math.abs(timelinePanel.y - calendarContainer.y) <= 2);
        verify(calendarContainer.width >= 360);
        verify(timelinePanel.width >= 360);
        verify(timelinePanel.height >= 260);
        verify(timelineTitle.text.indexOf("专注记录") >= 0);
        compare(emptyState.text, "这一天还没有专注记录");
        compare(timelineScrollView.visible, monthGoalView.selectedDaySessions.length > 0);

        compare(selectedDayCell.radius, 6);
        verify(selectedDayCell.border.width >= 2);
        compare(selectedDayDuration.font.pixelSize, 11);
    }
}
