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
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int mode: 0
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
        property int minimumValidMinutes: 3
        property int autoCompleteMinutes: 5
        property int completedPomodoros: 0

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)

        function startFocus(id, title) {
            return true;
        }

        function startPomodoroWork(id, title, workSeconds) {
            return true;
        }

        function startBreak(breakSeconds) {
            return true;
        }

        function startBreakForTask(breakSeconds, taskId, title) { return true }
        function resetPomodoroCount() { completedPomodoros = 0 }

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
        id: appSettings

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
        property int dayStartHour: 4
        property string rolloverIgnoredDate: ""
        property string backgroundTheme: "jiangnan"
        property bool sidebarVisible: true
        property bool reduceTransparency: false
        property bool raiseOnPhaseComplete: true
        property bool autoStartBreak: false
        property bool autoStartNextPomodoro: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property string nickname: ""
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

        function getWeekStats() {
            return {
                totalDuration: 0,
                completedTasks: 0,
                totalTasks: 0,
                completionRate: 0
            };
        }

        function getWeekComparison(weekStart) {
            return {
                effectiveDays: makeComparison("→ 0% vs 上周", 0),
                sessionCount: makeComparison("→ 0% vs 上周", 0),
                duration: makeComparison("→ 0% vs 上周", 0)
            };
        }

        function getCategoryStats(startDate, endDate) {
            return [];
        }

        function getMonthStats(year, month) {
            return {
                totalDuration: 0,
                effectiveDays: 0,
                sessionCount: 0,
                completedTasks: 0,
                totalTasks: 0
            };
        }

        function getMonthComparison(year, month) {
            return {
                effectiveDays: makeComparison("→ 0% vs 上月", 0),
                sessionCount: makeComparison("→ 0% vs 上月", 0),
                duration: makeComparison("→ 0% vs 上月", 0)
            };
        }

        function getMonthWeeklySummary(year, month) {
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
        mainWindow.focusImmersiveActive = false;
        appSettings.reduceMotion = false;
        appSettings.sidebarVisible = true;
        appSettings.reduceTransparency = false;
        wait(20);
    }

    function test_reduceTransparencyStopsSidebarBackdrop() {
        var frost = findChild(mainWindow, "sidebarFrost")
        verify(frost)
        tryCompare(Theme, "glassBlurAllowed", true)

        appSettings.reduceTransparency = true
        tryCompare(Theme, "glassBlurAllowed", false)
        tryCompare(frost, "visible", false)
    }

    function test_sidebarCollapseAndRevealAppleToggle() {
        var shell = findChild(mainWindow, "sidebarShell");
        var collapseBtn = findChild(mainWindow, "sidebarCollapseButton");
        var revealBtn = findChild(mainWindow, "sidebarRevealButton");
        var frost = findChild(mainWindow, "sidebarFrost");

        verify(shell !== null);
        verify(collapseBtn !== null);
        verify(revealBtn !== null);
        verify(frost !== null);

        // 初始展开：壳宽 208，悬浮展开钮不可点。
        compare(mainWindow.sidebarVisible, true);
        compare(shell.width, 208);
        compare(revealBtn.enabled, false);

        // 点侧栏内收起钮 → 布局收窄 + 设置落盘语义。
        appSettings.reduceMotion = true; // 瞬时，避免等动画
        mainWindow.setSidebarVisible(false);
        tryCompare(mainWindow, "sidebarVisible", false, 300);
        tryCompare(shell, "width", 0, 300);
        compare(appSettings.sidebarVisible, false);
        tryCompare(revealBtn, "enabled", true, 300);

        // 点悬浮钮展开。
        mainWindow.setSidebarVisible(true);
        tryCompare(mainWindow, "sidebarVisible", true, 300);
        tryCompare(shell, "width", 208, 300);
        compare(appSettings.sidebarVisible, true);
        compare(revealBtn.enabled, false);
    }

    function test_mainContentBackgroundTransparentAndDividerUnchanged() {
        var mainContent = findChild(mainWindow, "mainContentBackground");
        var divider = findChild(mainWindow, "mainContentDivider");
        var stackLayout = findChild(mainWindow, "mainViewStack");
        var textureLayer = findChild(mainWindow, "paperTextureLayer");

        verify(mainContent !== null);
        verify(divider !== null);
        verify(stackLayout !== null);
        verify(textureLayer === null, "旧噪点层应已移除，避免和 BackgroundWallpaper 双重叠加");

        verify(mainContent.color.a < 0.01, "主内容区必须透明，否则壁纸被盖住");
        verify(Qt.colorEqual(divider.color, Theme.border));
        compare(divider.opacity, 0.8);
        compare(stackLayout.currentIndex, mainWindow.viewIndex(mainWindow.currentView));
    }

    function test_wallpaperLayerFollowsSettings() {
        var wallpaper = findChild(mainWindow, "backgroundWallpaperLayer")
        verify(wallpaper)
        compare(wallpaper.themeId, "jiangnan")
        compare(wallpaper.resolvedTheme.id, "jiangnan")

        appSettings.backgroundTheme = "starry"
        compare(wallpaper.themeId, "starry")
        compare(wallpaper.resolvedTheme.id, "starry")
        appSettings.backgroundTheme = "jiangnan"
    }

    function test_viewSwitchAnimationUsesOptimizedTimingAndOpacity() {
        var fadeOut = findChild(mainWindow, "viewFadeOut");
        var fadeIn = findChild(mainWindow, "viewFadeIn");

        verify(fadeOut !== null);
        verify(fadeIn !== null);

        compare(fadeOut.from, 1.0);
        compare(fadeOut.to, 0.96);
        compare(fadeOut.duration, 70);
        compare(fadeOut.easing.type, Easing.OutQuad);

        compare(fadeIn.from, 0.96);
        compare(fadeIn.to, 1.0);
        compare(fadeIn.duration, 70);
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

        // 动画在不同机器上可能略慢，等状态结束比固定等待更稳定。
        tryCompare(mainWindow, "isSwitching", false, 1600);

        compare(mainWindow.currentView, "stats");
        compare(mainWindow.pendingView, "stats");
        compare(mainWindow.queuedView, "");
    }

    function test_settingsRoutineSignalOpensRoutineDialog() {
        var settings = findChild(mainWindow, "settingsDialog")
        verify(settings, "SettingsDialog 实例应存在")
        var routine = findChild(mainWindow, "routineDialogRoot")
        verify(routine, "RoutineDialog 实例应存在")

        compare(routine.opened, false)
        settings.routineRequested()
        tryCompare(routine, "opened", true, 500)
        routine.close()
    }

    function test_viewSwitchInstantUnderReduceMotion() {
        appSettings.reduceMotion = true
        mainWindow.switchToView("focus")

        compare(mainWindow.currentView, "focus")
        compare(mainWindow.isSwitching, false)
        var stack = findChild(mainWindow, "mainViewStack")
        verify(stack)
        compare(stack.opacity, 1.0)
    }

    function test_immersiveWiringActivatesAndDeactivates() {
        compare(mainWindow.focusImmersiveActive, false)

        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)

        const focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        focusView.immersiveRequested()
        compare(mainWindow.focusImmersiveActive, true)

        const row = findChild(mainWindow, "mainContentRow")
        verify(row)
        compare(row.visible, false)

        const overlay = findChild(mainWindow, "focusImmersiveOverlay")
        verify(overlay)
        overlay.exitRequested()
        compare(mainWindow.focusImmersiveActive, false)

        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
    }

    function test_focusEndedExitsImmersiveAndReturnsToday() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)

        const focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        focusView.immersiveRequested()
        compare(mainWindow.focusImmersiveActive, true)

        focusView.focusEnded()
        compare(mainWindow.focusImmersiveActive, false)
        compare(mainWindow.currentView, "today")

        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
    }

    function test_unprojectableAutoExitsViaOverlay() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)

        const focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        focusView.immersiveRequested()
        compare(mainWindow.focusImmersiveActive, true)

        focusTimer.hasActiveSession = false
        wait(20)
        compare(mainWindow.focusImmersiveActive, false)

        focusTimer.isRunning = false
    }
}
