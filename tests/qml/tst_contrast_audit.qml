pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../../qml"
import "fixtures"

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
        property bool quickStartEnabled: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property string nickname: ""
        // 课表页要有学期锚点才画得出网格。停在首次引导态的话，
        // 这一页真正有风险的那些文字（列头「今天」胶囊、刻度、课程块）一个都扫不到。
        property string semesterStartDate: "2026-08-31"
        property int semesterWeeks: 16
        property string scheduleDisplayMode: "time"
        property bool scheduleShowWeekend: true
    }

    // 课表服务替身。只需要够画出一屏内容：一门带科目色的课、一门不带的，
    // 以及一套节次（切到「按节次」版式时的行定义）。
    QtObject {
        id: scheduleService

        signal scheduleChanged
        signal periodsChanged
        signal operationFailed(string message)

        readonly property int maxTitleLength: 60
        readonly property int maxLocationLength: 60
        readonly property int maxWeekIndex: 60
        readonly property int maxPeriodCount: 24

        function getEntriesForWeek(weekIndex) {
            if (weekIndex < 1) {
                return []
            }
            return [
                {
                    id: 1, title: "高等数学", location: "多媒体楼 A101", weekday: 1,
                    startMinutes: 480, endMinutes: 580, durationMinutes: 100,
                    weekStart: 1, weekEnd: 16, weekParity: 0,
                    categoryId: 1, categoryName: "学习", categoryColor: "#c98a4b"
                },
                {
                    id: 2, title: "大学英语", location: "B203", weekday: 3,
                    startMinutes: 600, endMinutes: 700, durationMinutes: 100,
                    weekStart: 1, weekEnd: 8, weekParity: 1,
                    categoryId: undefined, categoryName: "", categoryColor: ""
                }
            ]
        }

        function getPeriods() {
            return [
                { index: 1, startMinutes: 480, endMinutes: 525 },
                { index: 2, startMinutes: 535, endMinutes: 580 }
            ]
        }

        function findConflicts() {
            return []
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

        // 周视图刷新还要这几项；缺了会在刷新里抛异常，被页面捕获后整页显示成加载失败，
        // 扫到的就不是真实的周视图。
        function getDayStats(date) {
            return getTodayStats();
        }

        function getEffectiveDays(startDate, endDate) {
            return 0;
        }

        function getFocusSessionCount(startDate, endDate) {
            return 0;
        }

        // 周复盘结果由扫描过程逐个换成不同状态；默认没有可展示内容，不影响其它页面。
        property var weeklyReviewData: ({ loadState: "ready", hasDisplayContent: false })

        function getWeeklyReview(weekStart, logicalTodayIso) {
            return weeklyReviewData;
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

    MemoCategoryMock { id: categoryManager }
    MemoServiceMock {
        id: memoService
        records: [makeRecord(11, "数学进度", "第八讲做完", 1),
                  makeRecord(12, "第二条记录", "积分练习", 1),
                  makeRecord(21, "物理进度", "力学第一章", 2),
                  makeRecord(31, "", "未分类的记录", 0)]
    }

    QtObject {
        id: exportService
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


    // 今日专注明细页的记录源。不注入的话这页只渲染空状态，
    // 时间轴行、休息行、时长读数这些真正的文字全都进不了体检。
    QtObject {
        id: focusHistoryService

        signal historyChanged()

        function getDayTimeline(date) {
            return [
                { id: 1, taskId: 1, taskTitle: "对比度检查任务", isRest: false,
                  startTime: "09:00", endTime: "09:25", durationSeconds: 1500 },
                { id: 2, taskId: -1, taskTitle: "", isRest: true,
                  startTime: "09:25", endTime: "09:30", durationSeconds: 300 }
            ]
        }
        function getDaySessions(date) { return focusHistoryService.getDayTimeline(date) }
        function getTaskOptions(date) { return [ { id: 1, title: "对比度检查任务" } ] }
        function formatDuration(seconds) { return Math.floor(seconds / 60) + " 分钟" }
        function lastError() { return "" }
        // 有这个函数页面才认为历史可编辑，补录/编辑入口的文字才会渲染出来。
        function addManualSession(taskId, startDateTime, durationMinutes) { return 9 }
        function updateSession(sessionId, startDateTime, durationMinutes) { return true }
        function deleteSession(sessionId) { return true }
    }

    MainWindow {
        id: mainWindow

        width: testCase.width
        height: testCase.height
        memoServiceRef: memoService
        focusHistoryServiceRef: focusHistoryService
        taskManagerRef: taskManager
        categoryManagerRef: categoryManager
        exportServiceRef: exportService
        statisticsServiceRef: statisticsService
        appSettingsRef: appSettings
        focusTimerRef: focusTimer
        shortcutRegistryRef: shortcutRegistry
        scheduleServiceRef: scheduleService
    }

    // 目前没有例外。加一条进来必须是一次明确的产品决定，并写清「为什么可以这样」
    // 和实测值——不是让门禁闭嘴的手段。此前唯一那条（时钟冒号日间 1.70:1）
    // 已在 2026-08-09 按两套主题对称的做法修掉，不再需要豁免。
    readonly property var knownExceptions: []

    function statisticsViewOf(root) {
        var chart = findChild(root, "statisticsTrendChart")
        var node = chart ? chart.parent : null, guard = 0
        while (node && guard++ < 30) {
            if (node.currentTimeRange !== undefined && node.weeklyReview !== undefined) {
                return node
            }
            node = node.parent
        }
        return null
    }

    // 复盘卡的三种形态：当前周概览（目标、今日进度、进行中的预计用时任务）、
    // 已结束周（四种事实都出现）、加载失败。
    function weeklyReviewStates() {
        var planned = {
            inProgress: true,
            totalPlannedMinutes: 150,
            totalActualSeconds: 7200,
            totalActualDisplayMinutes: 120,
            totalDifferenceDisplayMinutes: -30,
            totalInvestmentRatioPercent: 80,
            rows: [
                { subject: "数学", color: "#d4a574", plannedMinutes: 100, actualSeconds: 3000,
                  actualDisplayMinutes: 50, differenceDisplayMinutes: -50, investmentRatioPercent: 50 },
                { subject: "英语", color: "#c9956e", plannedMinutes: 50, actualSeconds: 4200,
                  actualDisplayMinutes: 70, differenceDisplayMinutes: 20, investmentRatioPercent: 140 }
            ]
        }
        var ended = JSON.parse(JSON.stringify(planned))
        ended.inProgress = false
        return [
            { name: "当前周概览", review: {
                loadState: "ready", periodState: "current", weekStart: "2026-07-13", weekEnd: "2026-07-19",
                hasData: true, hasDisplayContent: true,
                goal: { goalDays: 3, metDays: 2, goalMinutesTotal: 360, actualSecondsTotal: 18000, days: [] },
                todayGoal: { date: "2026-07-16", goalMinutes: 120, actualSeconds: 3600, progressPercent: 50 },
                subjects: [], plannedTasks: planned, facts: [] } },
            { name: "已结束周", review: {
                loadState: "ready", periodState: "ended", weekStart: "2026-07-06", weekEnd: "2026-07-12",
                hasData: true, hasDisplayContent: true,
                goal: { goalDays: 5, metDays: 3, goalMinutesTotal: 600, actualSecondsTotal: 30000, days: [] },
                todayGoal: {}, subjects: [], plannedTasks: ended,
                facts: [
                    { type: "goalShortfall", date: "2026-07-08", goalMinutes: 120, actualSeconds: 3600, ratioPercent: 50 },
                    { type: "subjectShareChange", subject: "数学", currentSeconds: 36000, previousSeconds: 21600,
                      currentSharePercent: 60, deltaPoints: 15 },
                    { type: "estimateShortfall", subject: "数学", plannedMinutes: 100,
                      actualDisplayMinutes: 50, shortfallDisplayMinutes: 50 },
                    { type: "estimateOnTrack", ratioPercent: 100 }
                ] } },
            { name: "加载失败", review: {
                loadState: "error", errorMessage: "no such table: focus_sessions", periodState: "ended",
                hasData: false, hasDisplayContent: false,
                goal: {}, todayGoal: {}, subjects: [], plannedTasks: {}, facts: [] } }
        ]
    }

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
        // 不加判据会把「带标题属性的背景矩形」当成低对比文字。
        // 光看 font 还不够：Control 自带 font 与 text，再给它一个背景色 alias（侧栏条目就是这样），
        // 整条条目就会被当成文字，量到的其实是它的背景色。textFormat 只有真正的文字类型才有。
        if (item.font !== undefined && item.text !== undefined && item.color !== undefined
                && item.textFormat !== undefined
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
        // 这份清单必须与侧栏的入口一一对应。漏掉一页，那一页就完全在门禁之外——
        // 课表页曾经就这样漏了一整轮：正文说明用了只给「占位/禁用」的 inkMuted，
        // 全量测试照样全绿。
        // todayFocus 不在侧栏里，是从仪表盘/统计页跳进去的今日专注明细页；
        // 没有入口图标不代表不用体检，它同样是用户天天看的一整页文字。
        var views = ["dashboard", "today", "focus", "week", "month",
                     "stats", "countdown", "schedule", "knowledgeGaps",
                     "todayFocus", "memo"]
        for (var i = 0; i < views.length; ++i) {
            mainWindow.currentView = views[i]
            mainWindow.pendingView = views[i]
            wait(200)
            if (views[i] === "memo") {
                // 产品保证：两套主题都扫描真正带胶囊、组头、行和编辑区的备忘录页，不能空扫。
                var memoPage = findChild(mainWindow, "memoViewPage")
                tryCompare(memoPage, "selectedId", 11, 3000)
                verify(findChild(memoPage, "memoFilter1"))
                verify(findChild(memoPage, "memoFilter0"))
                verify(findChild(memoPage, "memoGroup1"))
                verify(findChild(memoPage, "memoRow11"))
                verify(findChild(memoPage, "memoTitleInput").text.length > 0)
            }
            walk(mainWindow, tag, Theme.surface, 0)
            // 产品保证：出错提示条的文字同样要过对比度门禁。它只在出错时出现，平时这里一个字都扫不到——
            // 知识缺口页的错误条曾经是危险色字压在沉底色上，日间只有 4.44:1，全量测试照样全绿。
            // 这里给两页各摆出一条错误，只扫这一页再看一遍。
            if (views[i] === "knowledgeGaps" || views[i] === "memo") {
                var errorPage = views[i] === "memo" ? findChild(mainWindow, "memoViewPage")
                                                        : findChild(mainWindow, "knowledgeGapViewPage")
                verify(errorPage, views[i])
                var errorProperty = views[i] === "memo" ? "errorMessage" : "loadError"
                var errorTextName = views[i] === "memo" ? "memoError" : "knowledgeGapErrorText"
                errorPage[errorProperty] = "读取失败：磁盘 I/O 错误，数据库文件可能被其它程序占用"
                tryVerify(function () {
                    var text = findChild(errorPage, errorTextName)
                    return text !== null && text.width > 0 && text.height > 0
                }, 3000, "前置：" + views[i] + " 的错误条排好了版")
                walk(errorPage, tag + "·出错提示", Theme.surface, 0)
                errorPage[errorProperty] = ""
            }
        }
        // 统计页默认停在「今日」，复盘卡只在「本周」出现：必须真的切进周视图，
        // 把当前周概览、已结束周的事实、错误态各扫一遍，否则目标、事实、对账与错误文字全在门禁之外。
        mainWindow.currentView = "stats"
        mainWindow.pendingView = "stats"
        wait(100)
        var statsView = statisticsViewOf(mainWindow)
        verify(statsView, "找不到统计页")
        var reviewCard = findChild(statsView, "statisticsWeeklyReviewCard")
        verify(reviewCard, "找不到复盘卡")
        statsView.currentTimeRange = "week"
        var reviewStates = weeklyReviewStates()
        for (var r = 0; r < reviewStates.length; ++r) {
            statisticsService.weeklyReviewData = reviewStates[r].review
            statsView.refresh()
            wait(100)
            // 防止空扫：卡片确实带着这组内容。
            verify(reviewCard.implicitHeight > 100, reviewStates[r].name)
            compare(reviewCard.errorState, reviewStates[r].review.loadState === "error", reviewStates[r].name)
            walk(mainWindow, tag + "周复盘·" + reviewStates[r].name, Theme.surface, 0)
        }
        statsView.currentTimeRange = "today"
        statisticsService.weeklyReviewData = ({ loadState: "ready", hasDisplayContent: false })

        // 结束专注/结束休息只在计时态出现，单扫空闲页面永远测不到这些按钮。
        mainWindow.currentView = "focus"
        mainWindow.pendingView = "focus"
        focusTimer.currentTaskId = 1
        focusTimer.currentTaskTitle = "对比度检查任务"
        for (var mode = 0; mode <= 2; ++mode) {
            focusTimer.mode = mode
            focusTimer.phase = mode === 0 ? 0 : mode === 1 ? 1 : 3
            focusTimer.hasActiveSession = mode !== 2
            focusTimer.isRunning = true
            wait(100)
            walk(mainWindow, tag + "计时模式" + mode, Theme.surface, 0)
            focusTimer.isRunning = false
            wait(100)
            walk(mainWindow, tag + "暂停模式" + mode, Theme.surface, 0)
        }
        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
        focusTimer.mode = 0
        focusTimer.phase = 0
    }

    // 门禁量的是每个文字最终停下来的颜色，必须关掉颜色渐变。
    // 切主题时文字和底色都会用 120–280 毫秒渐变过去；开着渐变时，扫描量到的可能是半路上的颜色。
    // 单独跑时固定等待来得及，8 个测试并行时机器忙，渲染跟不上，渐变就没走完：
    // 2026-10-02 并行复现 24 次全部失败，失败全在夜间切到日间之后，量到的都是两套主题之间的过渡色。
    // 全部颜色动画的时长都写成「reduceMotion 时为 0」，打开后一切换就是最终颜色，最终颜色本身不变。
    // Theme.reduceMotion 只有真实应用入口（main.qml）会绑定，测试要自己设；
    // 侧栏、统计卡等直接读设置里的 reduceMotion，所以替身 appSettings 也一并打开。
    function initTestCase() {
        Theme.reduceMotion = true
        appSettings.reduceMotion = true
    }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
        Theme.reduceMotion = false
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
