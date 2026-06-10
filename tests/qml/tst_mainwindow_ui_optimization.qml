import QtQuick
import QtTest
import "../../qml"

TestCase {
    id: testCase
    name: "MainWindowUiOptimization"
    when: windowShown
    width: 960
    height: 640

    QtObject {
        id: taskManager

        signal tasksChanged

        function getTodayTasks() {
            return [];
        }

        function getWeekTasks(weekStart) {
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

        property bool isRunning: false
        property bool hasActiveSession: false
        property string currentTaskTitle: ""
        property int elapsedSeconds: 0

        signal focusCompleted(int duration)

        function startFocus(id, title) {
            return true;
        }

        function pauseFocus() {
        }

        function resumeFocus() {
            return true;
        }

        function stopFocus() {
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

        function getWeekStats() {
            return {
                totalDuration: 0,
                completedTasks: 0,
                totalTasks: 0,
                completionRate: 0
            };
        }

        function getCategoryStats(startDate, endDate) {
            return [];
        }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged

        function getCategories() {
            return [];
        }

        function getActiveCategories() {
            return [];
        }
    }

    QtObject {
        id: exportService
    }

    MainWindow {
        id: mainWindow

        width: testCase.width
        height: testCase.height
    }

    function init() {
        mainWindow.currentView = "today";
        mainWindow.pendingView = "today";
        mainWindow.queuedView = "";
        mainWindow.isSwitching = false;
        mainWindow.opacity = 1.0;
        wait(20);
    }

    function test_mainContentAndDividerUseOptimizedColors() {
        var mainContent = findChild(mainWindow, "mainContentBackground");
        var divider = findChild(mainWindow, "mainContentDivider");
        var stackLayout = findChild(mainWindow, "mainViewStack");

        verify(mainContent !== null);
        verify(divider !== null);
        verify(stackLayout !== null);

        verify(Qt.colorEqual(mainContent.color, "#fffef9"));
        verify(Qt.colorEqual(divider.color, "#e8dfc8"));
        compare(divider.opacity, 0.8);
        compare(stackLayout.currentIndex, mainWindow.viewIndex(mainWindow.currentView));
    }

    function test_viewSwitchAnimationUsesOptimizedTimingAndOpacity() {
        var fadeOut = findChild(mainWindow, "viewFadeOut");
        var fadeIn = findChild(mainWindow, "viewFadeIn");

        verify(fadeOut !== null);
        verify(fadeIn !== null);

        compare(fadeOut.from, 1.0);
        compare(fadeOut.to, 0.85);
        compare(fadeOut.duration, 180);
        compare(fadeOut.easing.type, Easing.OutQuad);

        compare(fadeIn.from, 0.85);
        compare(fadeIn.to, 1.0);
        compare(fadeIn.duration, 180);
        compare(fadeIn.easing.type, Easing.OutQuad);
    }

    function test_switchToViewDebouncesWhileAnimationIsRunning() {
        mainWindow.switchToView("week");

        compare(mainWindow.isSwitching, true);
        compare(mainWindow.pendingView, "week");

        mainWindow.switchToView("month");
        compare(mainWindow.pendingView, "week");
        compare(mainWindow.queuedView, "month");

        mainWindow.switchToView("stats");
        compare(mainWindow.pendingView, "week");
        compare(mainWindow.queuedView, "stats");

        wait(820);

        compare(mainWindow.currentView, "stats");
        compare(mainWindow.pendingView, "stats");
        compare(mainWindow.queuedView, "");
        compare(mainWindow.isSwitching, false);
    }
}
