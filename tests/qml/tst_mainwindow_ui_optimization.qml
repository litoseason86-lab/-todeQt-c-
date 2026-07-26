pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
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

    QtObject {
        id: goalService

        signal goalProgressed(int goalId, string title, int doneCount, int targetPomodoros)
        signal milestoneReached(int goalId, string title, int percent)
        signal goalsChanged

        property var detailData: ({
            id: 7,
            title: "英语精读",
            doneCount: 50,
            targetPomodoros: 100,
            percent: 50,
            achieved: false,
            forecastDays: 10
        })

        function getGoals() { return [] }
        function getGoal(goalId) { return detailData }
        function getGoalDailyCounts(goalId, year, month) { return [] }
    }

    QtObject {
        id: phaseSoundService

        property int milestoneCalls: 0
        property int achievedCalls: 0

        function playMilestoneChime() {
            milestoneCalls += 1
            return true
        }
        function playGoalAchievedChime() {
            achievedCalls += 1
            return true
        }
    }

    MainWindow {
        id: mainWindow

        width: testCase.width
        height: testCase.height
        taskManagerRef: taskManager
        categoryManagerRef: categoryManager
        exportServiceRef: exportService
        statisticsServiceRef: statisticsService
        appSettingsRef: appSettings
        focusTimerRef: focusTimer
        goalServiceRef: goalService
        phaseSoundServiceRef: phaseSoundService
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
        appSettings.soundEnabled = true;
        phaseSoundService.milestoneCalls = 0
        phaseSoundService.achievedCalls = 0
        mainWindow.milestoneQueue = []
        mainWindow.suppressedMilestones = []
        mainWindow.milestonePresentationScheduled = false
        mainWindow.disposeActiveMilestoneDialog()
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

    function test_goalProgressedShowsGlobalToast() {
        goalService.goalProgressed(7, "英语精读", 3, 100)
        var toastText = findChild(mainWindow, "toastText")
        verify(toastText !== null)
        tryCompare(toastText, "text", "英语精读 +1 · 3/100")
    }

    function test_milestoneCreatesPlainDialogOutsideImmersive() {
        appSettings.reduceMotion = true
        goalService.detailData = {
            id: 7, title: "英语精读", doneCount: 50, targetPomodoros: 100,
            percent: 50, achieved: false, forecastDays: 10
        }

        goalService.milestoneReached(7, "英语精读", 50)
        tryVerify(function() { return mainWindow.activeMilestoneDialog !== null })
        compare(mainWindow.activeMilestoneDialog.percent, 50)
        compare(mainWindow.activeMilestoneDialog.achieved, false)
        compare(phaseSoundService.milestoneCalls, 1)
        compare(phaseSoundService.achievedCalls, 0)
    }

    function test_immersiveSuppressesDialogButKeepsSoundAndAddsExitToast() {
        appSettings.reduceMotion = true
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)
        var focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView !== null)
        focusView.immersiveRequested()
        tryCompare(mainWindow, "focusImmersiveActive", true)

        goalService.milestoneReached(7, "英语精读", 50)
        tryCompare(phaseSoundService, "milestoneCalls", 1)
        compare(mainWindow.activeMilestoneDialog, null)
        verify(mainWindow.suppressedMilestone !== null)

        mainWindow.focusImmersiveActive = false
        var toastText = findChild(mainWindow, "toastText")
        verify(toastText !== null)
        tryVerify(function() { return toastText.text.indexOf("50%") >= 0 })
        compare(mainWindow.suppressedMilestone, null)
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
    }

    function test_reduceMotionCreatesNoRewardParticles() {
        appSettings.reduceMotion = true
        goalService.milestoneReached(7, "英语精读", 50)
        tryVerify(function() { return mainWindow.activeMilestoneDialog !== null })
        tryCompare(mainWindow, "rewardParticleCount", 0)
    }

    function test_milestoneParticlesAreVisibleAboveDialog() {
        // 反面用例只能证明减少动效时不创建粒子；这里同时锁住数量和宿主层级，
        // 避免动画对象正常运行，却被 Popup 所在的 overlay 整层遮住。
        appSettings.reduceMotion = false
        goalService.milestoneReached(7, "英语精读", 50)
        tryVerify(function() { return mainWindow.activeMilestoneDialog !== null })
        tryVerify(function() { return mainWindow.rewardParticleCount > 0 })

        const particles = findChild(mainWindow, "goalRewardParticles")
        verify(particles !== null)
        compare(particles.parent, Overlay.overlay)
    }

    function test_goalAchievementUsesAchievedDialogAndChime() {
        appSettings.reduceMotion = true
        goalService.detailData = {
            id: 7, title: "英语精读", doneCount: 100, targetPomodoros: 100,
            percent: 100, achieved: true, forecastDays: 0
        }

        goalService.milestoneReached(7, "英语精读", 100)
        tryVerify(function() { return mainWindow.activeMilestoneDialog !== null })
        compare(mainWindow.activeMilestoneDialog.achieved, true)
        compare(mainWindow.activeMilestoneDialog.percent, 100)
        compare(phaseSoundService.milestoneCalls, 0)
        compare(phaseSoundService.achievedCalls, 1)
    }

    function test_backToBackMilestonesArePresentedInOrder() {
        appSettings.reduceMotion = true

        goalService.milestoneReached(7, "英语精读", 50)
        goalService.milestoneReached(8, "写作训练", 100)

        tryVerify(function() { return mainWindow.activeMilestoneDialog !== null })
        compare(mainWindow.activeMilestoneDialog.goalId, 7)
        compare(mainWindow.pendingMilestone.goalId, 8)

        mainWindow.activeMilestoneDialog.dismiss()
        tryVerify(function() {
            return mainWindow.activeMilestoneDialog !== null
                    && mainWindow.activeMilestoneDialog.goalId === 8
        })
        compare(mainWindow.pendingMilestone, null)
        compare(phaseSoundService.milestoneCalls, 1)
        compare(phaseSoundService.achievedCalls, 1)
    }

    function test_escapeClosesMilestoneAndReleasesLifecycle() {
        appSettings.reduceMotion = true
        goalService.milestoneReached(7, "英语精读", 50)
        tryVerify(function() { return mainWindow.activeMilestoneDialog !== null })

        keyClick(Qt.Key_Escape)
        tryCompare(mainWindow, "activeMilestoneDialog", null)
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
