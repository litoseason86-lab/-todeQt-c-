pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../../qml"

// 全视图对比度门禁。
//
// 起因：夜间主题下「添加新任务」的输入文字和科目下拉是白底白字（2026-08-09 上报）。
// 根源是控件的视觉属性没接管、落回 Qt Quick Controls 写死的默认值；顺着这条线还查出
// 一批 call site 选错了令牌——该用 accentForeground 的用了近白、该用 accentFillInk 的
// 用了 accentInk、该用 inkSoft 的用了 inkMuted。这些都不是某一个页面的问题，
// 靠人眼逐页看不可能守得住，所以做成门禁：遍历每个视图的整棵项树，
// 对每个文字项算它压在自身背景上的真实对比度。
//
// 判据按 WCAG 2.2：正文 4.5:1，大号文字（>=24px，或 >=19px 加粗）3:1。
// 禁用态控件按标准豁免——它们本来就该看起来不可用。
TestCase {
    id: testCase
    name: "ContrastAudit"
    when: windowShown
    width: 1100
    height: 780
    visible: true

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
        goalServiceRef: goalService
        phaseSoundServiceRef: phaseSoundService
        shortcutRegistryRef: shortcutRegistry
    }

    // 目前没有例外。加一条进来必须是一次明确的产品决定，并写清「为什么可以这样」
    // 和实测值——不是让门禁闭嘴的手段。此前唯一那条（时钟冒号日间 1.70:1）
    // 已在 2026-08-09 按两套主题对称的做法修掉，不再需要豁免。
    readonly property var knownExceptions: []

    function isExempt(item) {
        for (var i = 0; i < testCase.knownExceptions.length; ++i) {
            if (String(item.text) === testCase.knownExceptions[i].text) {
                return true
            }
        }
        return false
    }

    // 往上找最近的 Control，判断它是不是禁用态。
    function inDisabledControl(item) {
        var node = item, guard = 0
        while (node && guard++ < 20) {
            if (node.enabled === false) {
                return true
            }
            node = node.parent
        }
        return false
    }

    function kidsOf(item) {
        var slots = item.data
        if (slots === undefined || slots === null) slots = item.children
        return slots ? slots : []
    }

    // Control 的 background 与 contentItem 是兄弟而不是父子：只沿 parent 往上
    // 会跳过按钮自己的底色，把页面底当成背景，得出一堆假的低对比。
    function backdropOf(item, fallback) {
        var node = item.parent, guard = 0
        while (node && guard++ < 60) {
            if (node.background !== undefined && node.background !== null
                    && node.background.color !== undefined && node.background.color !== null
                    && node.background.color.a >= 0.85) {
                return node.background.color
            }
            if (node.color !== undefined && node.color !== null
                    && node.border !== undefined && node.text === undefined
                    && node.color.a >= 0.85) {
                return node.color
            }
            node = node.parent
        }
        return fallback
    }

    property var findings: []

    function pathOf(item) {
        var parts = [], node = item, guard = 0
        while (node && guard++ < 12) {
            var n = String(node.objectName || "")
            if (n.length > 0) parts.unshift(n)
            node = node.parent
        }
        return parts.length ? parts.slice(-2).join("/") : "(无 objectName)"
    }

    function walk(item, tag, fallback, depth) {
        if (!item || depth > 40) return
        // 必须真的是文字渲染类型：委托根节点常常同时有 text 属性和背景 color，
        // 不加 font 这一判据会把「带标题属性的背景矩形」当成低对比文字。
        if (item.font !== undefined && item.text !== undefined && item.color !== undefined
                && String(item.text).length > 0 && item.opacity > 0.05
                && item.width > 0 && item.height > 0
                && item.color.a > 0.15
                && !inDisabledControl(item) && !isExempt(item)) {
            var bg = backdropOf(item, fallback)
            if (bg) {
                var fg = item.color.a >= 0.99 ? item.color : Qt.rgba(
                    item.color.r * item.color.a + bg.r * (1 - item.color.a),
                    item.color.g * item.color.a + bg.g * (1 - item.color.a),
                    item.color.b * item.color.a + bg.b * (1 - item.color.a), 1)
                var size = Number(item.font.pixelSize || 0)
                var bold = Number(item.font.weight || 400) >= 700 || item.font.bold === true
                var large = size >= 24 || (size >= 19 && bold)
                var need = large ? 3.0 : 4.5
                var r = Theme.contrastRatio(fg, bg)
                if (r < need) {
                    testCase.findings.push(tag + " │ \"" + String(item.text).substring(0, 20)
                        + "\" │ " + String(fg) + " on " + String(bg)
                        + " │ " + r.toFixed(2) + ":1 < " + need + " │ " + pathOf(item))
                }
            }
        }
        var kids = kidsOf(item)
        for (var i = 0; i < kids.length; ++i) walk(kids[i], tag, fallback, depth + 1)
    }

    function sweep(themeId, tag) {
        Theme.activeThemeId = themeId
        var views = ["dashboard", "today", "focus", "week", "month",
                     "statistics", "countdown", "goals"]
        for (var i = 0; i < views.length; ++i) {
            mainWindow.currentView = views[i]
            mainWindow.pendingView = views[i]
            wait(200)
            walk(mainWindow, tag, Theme.surface, 0)
        }
    }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
    }

    function test_no_unreadable_text_in_any_view() {
        testCase.findings = []
        sweep("starry", "夜间")
        sweep("warm", "日间")

        var seen = ({})
        var uniq = []
        for (var i = 0; i < testCase.findings.length; ++i) {
            if (!seen[testCase.findings[i]]) {
                seen[testCase.findings[i]] = true
                uniq.push(testCase.findings[i])
            }
        }
        if (uniq.length > 0) {
            for (var j = 0; j < uniq.length; ++j) {
                console.log("对比度不足：" + uniq[j])
            }
        }
        compare(uniq.length, 0, "存在看不清的文字，明细见上方日志")
    }
}
