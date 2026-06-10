import QtQuick
import QtTest
import "../../qml/components"
import "../../qml/views"

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

    AddTaskDialog {
        id: addTaskDialog
    }

    QtObject {
        id: taskManager

        signal tasksChanged

        function getTodayTasks() {
            return [];
        }

        function getMonthTasks(year, month) {
            return [];
        }

        function addTask(title, date, categoryId) {
        }

        function setTaskCompleted(id, completed) {
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
    }

    TodayTaskView {
        id: todayTaskView

        width: 620
        height: 420
        visible: false
    }

    MonthGoalView {
        id: monthGoalView

        width: 920
        height: 620
        visible: false
    }

    function init() {
        taskItem.taskCompleted = false;
        taskItem.opacity = 1.0;
        addTaskDialog.close();
        wait(220);
    }

    function test_taskItemUsesStandardQt6ShadowMetadata() {
        compare(taskItem.layer.enabled, true);
        verify(taskItem.layer.effect !== null);
        compare(taskItem.layer.effect.status, Component.Ready);
        verify(String(taskItem.layer.effect).indexOf("ShaderEffect") === -1);
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

        verify(Qt.colorEqual(description.color, "#6d5e47"));
        compare(addButtonBackground.radius, 8);
        verify(Qt.colorEqual(addButtonBackground.color, "#d4a574"));
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
        wait(80);

        var previousButton = findChild(monthGoalView, "monthPreviousButton");
        var currentButton = findChild(monthGoalView, "monthCurrentButton");
        var nextButton = findChild(monthGoalView, "monthNextButton");
        var previousButtonBackground = findChild(monthGoalView, "monthPreviousButtonBackground");
        var totalStatCard = findChild(monthGoalView, "monthTotalStatCard");
        var completedStatCard = findChild(monthGoalView, "monthCompletedStatCard");
        var rateStatCard = findChild(monthGoalView, "monthRateStatCard");
        var calendarContainer = findChild(monthGoalView, "monthCalendarContainer");
        var detailPanel = findChild(monthGoalView, "monthDetailPanel");
        var addButton = findChild(monthGoalView, "monthDetailAddButton");
        var addButtonBackground = findChild(monthGoalView, "monthDetailAddButtonBackground");
        var selectedDayCell = findChild(monthGoalView, "monthDayCell-" + monthGoalView.selectedDay);

        verify(previousButton !== null);
        verify(currentButton !== null);
        verify(nextButton !== null);
        verify(previousButtonBackground !== null);
        verify(totalStatCard !== null);
        verify(completedStatCard !== null);
        verify(rateStatCard !== null);
        verify(calendarContainer !== null);
        verify(detailPanel !== null);
        verify(addButton !== null);
        verify(addButtonBackground !== null);
        verify(selectedDayCell !== null);

        compare(previousButtonBackground.radius, 8);
        compare(totalStatCard.radius, 8);
        compare(completedStatCard.radius, 8);
        compare(rateStatCard.radius, 8);
        compare(totalStatCard.layer.enabled, true);
        verify(totalStatCard.layer.effect !== null);

        compare(calendarContainer.radius, 8);
        compare(calendarContainer.layer.enabled, true);
        verify(calendarContainer.layer.effect !== null);
        compare(detailPanel.radius, 8);
        compare(detailPanel.layer.enabled, true);
        verify(detailPanel.layer.effect !== null);

        compare(selectedDayCell.radius, 6);
        verify(selectedDayCell.border.width >= 2);
        compare(addButtonBackground.radius, 8);
    }
}
