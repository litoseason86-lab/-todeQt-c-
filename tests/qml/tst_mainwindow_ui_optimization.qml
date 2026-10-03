pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../../qml"
import "fixtures"

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
        property bool quickStartEnabled: false
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

        // 复盘接口是统计页契约的一部分，替身必须提供；这里返回没有可展示内容的成功结果。
        function getWeeklyReview(weekStart, logicalTodayIso) {
            return { loadState: "ready", periodState: "current", hasData: false, hasDisplayContent: false,
                     goal: ({}), todayGoal: ({}), subjects: [], plannedTasks: ({}), facts: [] }
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
        id: backupService

        property bool operationBlocksUi: false
        property string operationText: ""
    }

    // 最小快捷键注册表：只给一条应用内动作，够验证「弹窗打开时整体让路」这条接线。
    // 键位规则本身由 ShortcutRegistryTests 与 tst_shortcuts.qml 覆盖。
    QtObject {
        id: shortcutRegistry

        readonly property var inAppActions: [{
            id: "view.dashboard", title: "仪表盘", group: "导航",
            sequence: "Ctrl+1", display: "\u2318" + "1",
            defaultSequence: "Ctrl+1", defaultDisplay: "\u2318" + "1",
            isDefault: true, isGlobal: false, isDisabled: false,
            registered: true, hasDefault: true, hasModifier: true
        }, {
            // 单键绑定：应用内允许，但焦点进输入框时必须让路。
            id: "focus.toggle", title: "开始 / 暂停专注", group: "专注",
            sequence: "Space", display: "Space",
            defaultSequence: "Ctrl+Return", defaultDisplay: "\u2318\u21a9",
            isDefault: false, isGlobal: false, isDisabled: false,
            registered: true, hasDefault: true, hasModifier: false
        }]
        readonly property var actions: shortcutRegistry.inAppActions
        readonly property var globalActions: []
        readonly property var groups: ["导航"]

        signal globalActionTriggered(string actionId)
        signal globalRegistrationFailed(string actionId, string title)

        function normalize(key, modifiers) { return "" }
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
        backupServiceRef: backupService
        shortcutRegistryRef: shortcutRegistry
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
        backupService.operationBlocksUi = false
        backupService.operationText = ""
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
        tryCompare(mainWindow, "sidebarVisible", false, 3000);
        tryCompare(shell, "width", 0, 3000);
        compare(appSettings.sidebarVisible, false);
        tryCompare(revealBtn, "enabled", true, 3000);

        // 点悬浮钮展开。
        mainWindow.setSidebarVisible(true);
        tryCompare(mainWindow, "sidebarVisible", true, 3000);
        tryCompare(shell, "width", 208, 3000);
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
        // 侧栏展开时分隔线必须真的占到宽度。此前只查颜色与 opacity，
        // 一条宽度恒为 0、从未渲染出来的分隔线也能让这条用例全绿——实测就是如此。
        // 只断言 width 不断言 visible：本项目的 QML 测试沙箱里 visible 的级联不可靠。
        tryCompare(divider, "width", 1);
        compare(stackLayout.currentIndex, mainWindow.viewIndex(mainWindow.currentView));
    }

    // 产品保证：备忘录能从正式页面栈进入，退出流程能保存草稿，失败则回到编辑页展示原因。
    function test_memoWiringAndQuitFlush() {
        const oldReduceMotion = Theme.reduceMotion
        memoService.reset([memoService.makeRecord(1, "退出前", "原正文", 1)])
        mainWindow.memoServiceRef = memoService
        mainWindow.categoryManagerRef = memoCategories
        Theme.reduceMotion = true
        mainWindow.switchToView("memo")
        var page = findChild(mainWindow, "memoViewPage")
        tryCompare(page, "selectedId", 1, 3000)
        compare(page.memoServiceRef, memoService)
        page.editorBody = "退出之前还没保存的正文"
        verify(page.dirty)
        compare(mainWindow.flushMemoEdits(), true)
        compare(memoService.updates[0].changes.body, "退出之前还没保存的正文")
        page.editorBody = "保存失败的正文"
        memoService.failSave = true
        mainWindow.currentView = "today"
        compare(mainWindow.flushMemoEdits(), false)
        compare(mainWindow.currentView, "memo")
        compare(page.editorBody, "保存失败的正文")
        compare(page.errorMessage, "磁盘不可写")
        memoService.failSave = false
        page.saveNow()
        mainWindow.memoServiceRef = null
        mainWindow.categoryManagerRef = null
        Theme.reduceMotion = oldReduceMotion
    }

    // 页面编号必须与 StackLayout 里页面的书写顺序一一对应，切页状态机按编号取页。
    // 2026-09 删掉「目标」页（原第 7 页）后，排在它后面的三页各前移一位；这条逐页核对
    // 「按名字切过去，栈里显示的正是那一页」，而不只是「currentIndex 等于映射出来的数」。
    function test_everyViewNameMapsToItsOwnPage_data() {
        return [
            { tag: "today", page: "todayTaskViewPage" },
            { tag: "focus", page: "focusViewPage" },
            { tag: "week", page: "weekPlanViewPage" },
            { tag: "month", page: "monthGoalViewPage" },
            { tag: "stats", page: "statisticsViewPage" },
            { tag: "countdown", page: "countdownViewPage" },
            { tag: "dashboard", page: "dashboardViewPage" },
            { tag: "todayFocus", page: "todayFocusViewPage" },
            { tag: "schedule", page: "schedulePlanViewPage" },
            { tag: "memo", page: "memoViewPage" },
            { tag: "knowledgeGaps", page: "knowledgeGapViewPage" }
        ]
    }

    function test_everyViewNameMapsToItsOwnPage(data) {
        const stack = findChild(mainWindow, "mainViewStack")
        verify(stack !== null)
        const index = mainWindow.viewIndex(data.tag)
        verify(index >= 0 && index < stack.children.length, data.tag + " 映射到 " + index)
        compare(stack.children[index].objectName, data.page)
    }

    function test_removedGoalsViewHasNoPageOfItsOwn() {
        const stack = findChild(mainWindow, "mainViewStack")
        verify(stack !== null)
        // 栈里正好是上面那十页：多一页或少一页，编号就会整体错位。
        compare(stack.children.length, 11)
        // 旧配置、旧快捷键里残留的 "goals" 落到默认的今日页，不能落到别的页上。
        compare(mainWindow.viewIndex("goals"), mainWindow.viewIndex("today"))
        verify(findChild(mainWindow, "goalsViewPage") === null)
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
        tryCompare(routine, "opened", true, 3000)
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

    function test_inAppShortcutsStandDownWhileADialogHoldsFocus() {
        // Qt 的 Shortcut 不受弹窗遮挡影响：不主动让路的话，用户在新建任务对话框里
        // 打字时按 ⌘1，页面会在弹窗背后被切走（已实测复现）。
        const appShortcuts = findChild(mainWindow, "appShortcuts")
        verify(appShortcuts)
        compare(appShortcuts.suspended, false)

        const dialog = findChild(mainWindow, "settingsDialog")
        verify(dialog)
        dialog.open()
        tryCompare(appShortcuts, "suspended", true)

        // 让路必须真的落到每个 Shortcut 上，光有一个标记位不算数。
        const instantiator = findChild(appShortcuts, "inAppShortcutInstantiator")
        verify(instantiator)
        verify(instantiator.count > 0)
        compare(instantiator.objectAt(0).enabled, false)

        dialog.close()
        tryCompare(appShortcuts, "suspended", false)
        tryCompare(instantiator.objectAt(0), "enabled", true)
    }

    function test_backupRestoreBlocksShortcutInputAndRestoresIt() {
        appSettings.reduceMotion = true
        const appShortcuts = findChild(mainWindow, "appShortcuts")
        const instantiator = findChild(appShortcuts, "inAppShortcutInstantiator")
        verify(appShortcuts)
        verify(instantiator)
        verify(instantiator.count > 0)

        compare(mainWindow.backupOperationBlocksInput, false)
        compare(appShortcuts.suspended, false)
        mainWindow.triggerShortcutAction("view.week")
        compare(mainWindow.currentView, "week")

        backupService.operationText = "正在备份当前数据并恢复"
        backupService.operationBlocksUi = true
        tryCompare(mainWindow, "backupOperationBlocksInput", true)
        tryCompare(appShortcuts, "suspended", true)
        tryCompare(instantiator.objectAt(0), "enabled", false)

        // 直接调用最终分发器来覆盖 AppShortcuts 以外的入口。
        mainWindow.triggerShortcutAction("view.month")
        compare(mainWindow.currentView, "week")

        backupService.operationBlocksUi = false
        tryCompare(mainWindow, "backupOperationBlocksInput", false)
        tryCompare(appShortcuts, "suspended", false)
        tryCompare(instantiator.objectAt(0), "enabled", true)
        mainWindow.triggerShortcutAction("view.month")
        compare(mainWindow.currentView, "month")
    }

    function test_bareKeyShortcutsStandDownWhileTypingOutsideAnyDialog() {
        // 任务行的内联重命名框和每日目标编辑器都不在弹窗里，overlayHoldsFocus 盖不住，
        // 必须靠 textInputFocused 单独兜住——否则把空格绑成「开始/暂停」之后，
        // 在这些输入框里就再也打不出空格。
        const appShortcuts = findChild(mainWindow, "appShortcuts")
        const instantiator = findChild(appShortcuts, "inAppShortcutInstantiator")
        verify(instantiator)
        compare(instantiator.count, 2)

        const probe = textInputProbe.createObject(mainWindow)
        verify(probe)
        probe.forceActiveFocus()
        tryCompare(mainWindow, "textInputFocused", true)

        // 单键让路，带修饰键的照常可用（macOS 上输入时按 ⌘1 切页是正常行为）。
        tryCompare(instantiator.objectAt(1), "enabled", false)
        compare(instantiator.objectAt(0).enabled, true)
        // 弹窗没开，整体 suspended 不应被误置。
        compare(appShortcuts.suspended, false)

        probe.destroy()
        tryCompare(mainWindow, "textInputFocused", false)
        tryCompare(instantiator.objectAt(1), "enabled", true)
    }

    MemoServiceMock { id: memoService }
    MemoCategoryMock { id: memoCategories }

    Component {
        id: textInputProbe

        TextField {}
    }
}
