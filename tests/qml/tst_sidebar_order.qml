import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"
import "../../qml/components/settings"

// 侧栏顺序：渲染跟随设置、非法 id 不落地、以及「新增页面时漏改呈现表」这个坑。
TestCase {
    id: testCase
    name: "SidebarOrder"
    when: windowShown
    width: 320
    height: 640

    property var storedOrder: []
    property int resetCalls: 0

    QtObject {
        id: focusTimerMock

        property bool isRunning: false
        property bool hasActiveSession: false
        property int mode: 0
        property int phase: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
    }

    QtObject {
        id: settingsMock

        // 真实 AppSettings 会把顺序归一化后再落地；这里的替身只做存取，
        // 归一化本身由 ServiceTests 的 C++ 用例覆盖。
        property var sidebarOrder: testCase.storedOrder
        property bool sidebarOrderIsDefault: false

        function resetSidebarOrder() {
            testCase.resetCalls += 1
            settingsMock.sidebarOrder = testCase.defaultOrder()
        }
    }

    function defaultOrder() {
        return ["dashboard", "today", "todayFocus", "focus", "schedule", "week",
                "month", "stats", "countdown", "goals", "knowledgeGaps"]
    }

    Sidebar {
        id: sidebar

        width: 208
        height: 640
        currentView: "today"
        focusTimerRef: focusTimerMock
        settingsRef: settingsMock
    }

    SignalSpy {
        id: clickSpy
        target: sidebar
        signalName: "itemClicked"
    }

    function init() {
        testCase.resetCalls = 0
        settingsMock.sidebarOrder = testCase.defaultOrder()
        settingsMock.sidebarOrderIsDefault = true
        clickSpy.clear()
        wait(20)
    }

    function markersInOrder() {
        var markers = []
        var ids = sidebar.orderedEntryIds
        for (var i = 0; i < ids.length; ++i) {
            markers.push(sidebar.entryPresentation[ids[i]].marker)
        }
        return markers
    }

    function test_everyDefaultEntryHasPresentation() {
        // 新增页面要同时改 AppSettings::defaultSidebarOrder 和 Sidebar 的呈现表。
        // 漏改后一半：那一页在侧栏里是一行空白，肉眼几乎看不出，但点不动也说不清。
        var ids = testCase.defaultOrder()
        for (var i = 0; i < ids.length; ++i) {
            var presentation = sidebar.entryPresentation[ids[i]]
            verify(presentation !== undefined, "缺少呈现定义：" + ids[i])
            verify(String(presentation.text).length > 0, "条目没有文案：" + ids[i])
            verify(String(presentation.marker).length > 0, "条目没有标记：" + ids[i])
        }
    }

    function test_renderOrderFollowsSettings() {
        var custom = ["knowledgeGaps", "today", "dashboard", "todayFocus", "focus",
                      "schedule", "week", "month", "stats", "countdown", "goals"]
        settingsMock.sidebarOrder = custom
        wait(20)

        compare(sidebar.orderedEntryIds.length, custom.length)
        for (var i = 0; i < custom.length; ++i) {
            compare(sidebar.orderedEntryIds[i], custom[i])
        }
        // 条目确实按这个顺序渲染出来了，不只是属性变了。
        compare(testCase.markersInOrder()[0], "补")
        verify(findChild(sidebar, "sidebarItem-补") !== null)
    }

    function test_unknownIdsAreSkippedInsteadOfRenderingBlankRows() {
        settingsMock.sidebarOrder = ["today", "somePageFromTheFuture", "focus"]
        wait(20)

        compare(sidebar.orderedEntryIds.length, 2)
        compare(sidebar.orderedEntryIds[0], "today")
        compare(sidebar.orderedEntryIds[1], "focus")
    }

    function test_duplicateIdsRenderOnce() {
        settingsMock.sidebarOrder = ["today", "today", "focus"]
        wait(20)
        compare(sidebar.orderedEntryIds.length, 2)
    }

    function test_missingSettingsFallsBackToDefaultOrder() {
        // 离屏走查和预览场景常常只注入自己关心的那几个 ref。
        // 侧栏不能因为没拿到设置就整个空掉。
        var bare = createTemporaryObject(bareSidebarComponent, testCase)
        verify(bare)
        wait(20)
        compare(bare.orderedEntryIds.length, testCase.defaultOrder().length)
        compare(bare.orderedEntryIds[0], "dashboard")
    }

    Component {
        id: bareSidebarComponent

        Sidebar {
            width: 208
            height: 640
        }
    }

    function test_settingsEntryStaysPinnedAtBottom() {
        settingsMock.sidebarOrder = ["knowledgeGaps", "today"]
        wait(20)
        // 「设置」不是视图，不参与排序，也不该被用户排走。
        verify(sidebar.orderedEntryIds.indexOf("settings") < 0)
        verify(findChild(sidebar, "sidebarItem-设") !== null)
    }

    function test_clickStillReportsTheRightView() {
        settingsMock.sidebarOrder = ["knowledgeGaps", "today", "focus"]
        wait(20)
        var item = findChild(sidebar, "sidebarItem-补")
        verify(item)
        item.clicked()
        compare(clickSpy.count, 1)
        compare(clickSpy.signalArguments[0][0], "knowledgeGaps")
    }

    function test_focusEntryKeepsItsLiveStatusAfterReorder() {
        // 走秒状态原来是写死在「专注计时」那一条上的；改成 Repeater 之后
        // 必须仍然只挂在它身上，而且换了位置也还在。
        focusTimerMock.hasActiveSession = true
        focusTimerMock.isRunning = true
        focusTimerMock.mode = 1
        focusTimerMock.phase = 1
        focusTimerMock.remainingSeconds = 754
        settingsMock.sidebarOrder = ["focus", "today", "dashboard"]
        wait(20)

        var focusItem = findChild(sidebar, "sidebarItem-专")
        verify(focusItem)
        verify(focusItem.statusText.indexOf("12:34") >= 0, "实际为：" + focusItem.statusText)

        var todayItem = findChild(sidebar, "sidebarItem-今")
        verify(todayItem)
        compare(todayItem.statusText, "")

        focusTimerMock.hasActiveSession = false
        focusTimerMock.isRunning = false
        focusTimerMock.mode = 0
        focusTimerMock.phase = 0
        focusTimerMock.remainingSeconds = 0
    }

    // —— 设置页 ——
    SettingsAppearancePage {
        id: appearancePage

        width: 420
        appSettingsRef: settingsMock
    }

    function test_settingsPageListsEntriesInCurrentOrder() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)
        compare(appearancePage.sidebarOrder.length, 3)
        verify(findChild(appearancePage, "settingsSidebarOrderRow-goals") !== null)
        verify(findChild(appearancePage, "settingsSidebarOrderRow-today") !== null)
    }

    function test_moveEntryWritesWholeOrderBack() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)

        appearancePage.moveEntry(2, 0)
        compare(settingsMock.sidebarOrder.length, 3)
        compare(settingsMock.sidebarOrder[0], "focus")
        compare(settingsMock.sidebarOrder[1], "goals")
        compare(settingsMock.sidebarOrder[2], "today")

        // 整份提交而不是就地改副本：侧栏必须跟着变，否则界面和存储会悄悄分家。
        wait(20)
        compare(sidebar.orderedEntryIds[0], "focus")
    }

    function test_moveEntryIgnoresOutOfRangeAndNoOp() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)

        appearancePage.moveEntry(0, 0)
        appearancePage.moveEntry(-1, 1)
        appearancePage.moveEntry(0, 99)
        compare(settingsMock.sidebarOrder[0], "goals")
        compare(settingsMock.sidebarOrder[2], "focus")
    }

    function test_resetButtonOnlyEnabledWhenOrderDiffers() {
        settingsMock.sidebarOrderIsDefault = true
        wait(20)
        compare(appearancePage.orderIsDefault, true)
        var resetButton = findChild(appearancePage, "settingsSidebarOrderResetButton")
        verify(resetButton)
        compare(resetButton.enabled, false)

        settingsMock.sidebarOrderIsDefault = false
        wait(20)
        compare(resetButton.enabled, true)

        resetButton.clicked()
        compare(testCase.resetCalls, 1)
    }

    function test_unknownIdFallsBackToShowingTheIdItself() {
        // 呈现表漏了某个 id 时，显示 id 本身也好过一行空白——至少看得出是哪条坏了。
        compare(appearancePage.entryLabel("somePageFromTheFuture"), "somePageFromTheFuture")
        compare(appearancePage.entryLabel("today"), "今日任务")
    }
}
