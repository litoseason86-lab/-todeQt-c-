import QtQuick
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "TodayFocusView"
    when: windowShown
    width: 960
    height: 720

    // 固定“现在”为 2026-09-02 22:00。逻辑日起点是 4 点，所以逻辑今天就是 9 月 2 日；
    // 不固定的话跨零点跑用例会换一天，断言全部失效。
    property var fakeNow: new Date(2026, 8, 2, 22, 0)
    // 假记录按日期键存放，用例中途改写它就能模拟补录/删除之后的新结果。
    property var sessionsByDate: ({})
    property bool throwOnLoad: false

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: taskManager

        function getTasksByDate(date) {
            return [
                {
                    id: 11,
                    title: "复盘第十讲"
                }
            ];
        }
    }

    // 可写桩：提供 addManualSession，页面据此判定 canEditHistory 为真。
    QtObject {
        id: historyService

        signal historyChanged()

        property var deletedIds: []
        property bool deleteResult: true
        property string errorText: ""

        function getDaySessions(date) {
            if (testCase.throwOnLoad)
                throw new Error("数据库不可用");

            return testCase.sessionsByDate[Qt.formatDate(date, "yyyy-MM-dd")] || [];
        }

        function formatDuration(seconds) {
            return Math.floor(Math.max(0, seconds) / 60) + "分钟";
        }

        function lastError() {
            return historyService.errorText;
        }

        function addManualSession(taskId, startDateTime, durationMinutes) {
            return 9;
        }

        function updateSession(sessionId, startDateTime, durationMinutes) {
            return true;
        }

        function deleteSession(sessionId) {
            historyService.deletedIds.push(sessionId);
            if (!historyService.deleteResult)
                return false;

            // 真的把记录从假数据里摘掉，这样“删除后是否重新查过”才有可观测的结果。
            for (var key in testCase.sessionsByDate) {
                var kept = [];
                var rows = testCase.sessionsByDate[key];
                for (var i = 0; i < rows.length; ++i) {
                    if (rows[i].id !== sessionId)
                        kept.push(rows[i]);
                }
                testCase.sessionsByDate[key] = kept;
            }
            return true;
        }
    }

    // 只读桩：故意不提供 addManualSession，用来守住“只读服务不长出编辑入口”。
    QtObject {
        id: readOnlyHistoryService

        function getDaySessions(date) {
            return [];
        }

        function formatDuration(seconds) {
            return "0分钟";
        }

        function lastError() {
            return "";
        }
    }

    function makeSession(id, title, startTime, endTime, seconds, date) {
        return {
            id: id,
            taskId: id,
            taskTitle: title,
            startTime: startTime,
            endTime: endTime,
            durationSeconds: seconds,
            date: date
        };
    }

    TodayFocusView {
        id: view

        width: 900
        height: 680
        visible: false
        pageActive: true
        focusHistoryServiceRef: historyService
        logicalDayServiceRef: logicalDayService
        settingsRef: appSettings
        taskManagerRef: taskManager
        logicalNowProvider: function () {
            return testCase.fakeNow;
        }
    }

    TodayFocusView {
        id: readOnlyView

        width: 900
        height: 680
        visible: false
        pageActive: true
        focusHistoryServiceRef: readOnlyHistoryService
        settingsRef: appSettings
    }

    // 月历页只负责选日期，点格子后必须把日期交给今日专注页，自己不再展示明细。
    MonthGoalView {
        id: monthView

        width: 900
        height: 680
        visible: true
        pageActive: true
        settingsRef: appSettings
        logicalDayServiceRef: logicalDayService
        logicalNowProvider: function () {
            return testCase.fakeNow;
        }
    }

    SignalSpy {
        id: focusDateSpy

        target: monthView
        signalName: "focusDateRequested"
    }

    function init() {
        testCase.fakeNow = new Date(2026, 8, 2, 22, 0);
        testCase.throwOnLoad = false;
        historyService.deletedIds = [];
        historyService.deleteResult = true;
        historyService.errorText = "";
        testCase.sessionsByDate = {
            "2026-09-02": [testCase.makeSession(1, "复盘第十讲", "2026-09-02T14:19:00", "2026-09-02T15:49:00", 5400, "2026-09-02"), testCase.makeSession(2, "170词", "2026-09-02T16:40:00", "2026-09-02T17:00:00", 1200, "2026-09-02")],
            "2026-08-20": [testCase.makeSession(3, "旧记录", "2026-08-20T09:00:00", "2026-08-20T09:30:00", 1800, "2026-08-20")],
            "2026-09-03": [testCase.makeSession(4, "新一天", "2026-09-03T05:00:00", "2026-09-03T05:40:00", 2400, "2026-09-03")]
        };
        view.logicalToday = view.computeLogicalToday();
        view.showToday();
        focusDateSpy.clear();
    }

    function test_initialDayIsLogicalTodayAndLoadsItsSessions() {
        compare(view.dateKey(view.selectedDate), "2026-09-02");
        verify(view.showingToday);
        compare(view.sessions.length, 2);
        compare(view.totalSeconds, 6600);
        compare(view.loadError, "");

        var title = findChild(view, "todayFocusPageTitle");
        verify(title !== null);
        compare(title.text, "今日专注");

        var label = findChild(view, "todayFocusDateLabel");
        verify(label !== null);
        verify(label.text.indexOf("2026年9月2日") >= 0);
        verify(label.text.indexOf("2 次") >= 0);
    }

    function test_showDateSwitchesToHistoryDay() {
        view.showDate(new Date(2026, 7, 20));

        compare(view.dateKey(view.selectedDate), "2026-08-20");
        verify(!view.showingToday);
        compare(view.sessions.length, 1);
        compare(view.totalSeconds, 1800);

        // 看的不是今天时标题要改口，否则“今日专注”会挂在 8 月的记录上面。
        compare(findChild(view, "todayFocusPageTitle").text, "专注记录");
        verify(findChild(view, "todayFocusDateLabel").text.indexOf("2026年8月20日") >= 0);
    }

    function test_returnTodayButtonGoesBackToLogicalToday() {
        view.showDate(new Date(2026, 7, 20));
        verify(!view.showingToday);

        var button = findChild(view, "todayFocusReturnTodayButton");
        verify(button !== null);
        button.clicked();

        compare(view.dateKey(view.selectedDate), "2026-09-02");
        verify(view.showingToday);
        compare(view.sessions.length, 2);
    }

    function test_logicalDayRolloverFollowsTodayWhenPinnedToToday() {
        testCase.fakeNow = new Date(2026, 8, 3, 4, 0);

        logicalDayService.changed();

        compare(view.dateKey(view.selectedDate), "2026-09-03");
        verify(view.showingToday);
        compare(view.sessions.length, 1);
    }

    function test_logicalDayRolloverKeepsUserPinnedHistoryDay() {
        view.showDate(new Date(2026, 7, 20));
        testCase.fakeNow = new Date(2026, 8, 3, 4, 0);

        logicalDayService.changed();

        // 用户特意翻到 8 月 20 日，跨逻辑日不能把他甩回今天。
        compare(view.dateKey(view.selectedDate), "2026-08-20");
        verify(!view.showingToday);
        compare(view.sessions.length, 1);
    }

    function test_deleteSessionRemovesRowAndReloads() {
        view.deleteSession(1);

        compare(historyService.deletedIds.length, 1);
        compare(historyService.deletedIds[0], 1);
        compare(view.sessions.length, 1);
        compare(view.totalSeconds, 1200);
        compare(view.loadError, "");
    }

    function test_deleteFailureSurfacesServiceError() {
        historyService.deleteResult = false;
        historyService.errorText = "记录已被其它窗口删除";

        view.deleteSession(1);

        compare(view.loadError, "记录已被其它窗口删除");
        compare(view.sessions.length, 2);
    }

    function test_loadFailureShowsMessageAndClearsRows() {
        testCase.throwOnLoad = true;

        view.refresh();

        compare(view.loadError, "专注记录加载失败");
        compare(view.sessions.length, 0);
        compare(view.totalSeconds, 0);
    }

    function test_historyChangedReloadsWhileActive() {
        testCase.sessionsByDate["2026-09-02"] = [testCase.makeSession(5, "补录的一段", "2026-09-02T20:00:00", "2026-09-02T20:25:00", 1500, "2026-09-02")];

        historyService.historyChanged();

        compare(view.sessions.length, 1);
        compare(view.totalSeconds, 1500);
    }

    function test_readOnlyServiceHidesEditingEntries() {
        // 只读服务没有 addManualSession，补录/修改/删除都不该露出来。
        compare(readOnlyView.canEditHistory, false);
        compare(view.canEditHistory, true);

        var timeline = findChild(readOnlyView, "focusTimelinePanel");
        verify(timeline !== null);
        compare(timeline.editable, false);
    }

    function test_monthCalendarHandsDateToFocusPage() {
        var cell = findChild(monthView, "monthDayCell-15");
        verify(cell !== null);

        // 离屏平台上父链的 visible 为假，合成鼠标事件收不到；直接触发格子自己的点击信号。
        var dayMouseArea = findChild(monthView, "monthDayMouseArea-15");
        verify(dayMouseArea !== null);
        dayMouseArea.clicked(null);

        compare(focusDateSpy.count, 1);
        compare(monthView.selectedDay, 15);

        var emitted = focusDateSpy.signalArguments[0][0];
        compare(Qt.formatDate(emitted, "yyyy-MM-dd"), "2026-09-15");

        // 月历页自己不再持有明细，日期只能交给今日专注页去查。
        compare(findChild(monthView, "focusTimelinePanel"), null);
    }
}
