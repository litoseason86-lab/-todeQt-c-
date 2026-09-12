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
    // 窗口必须真的显示：拖动排序那条用例要发真实鼠标事件，窗口没显示时收不到。
    visible: true

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

    // —— 拖动排序 ——
    // 放在 Flickable 里的第二个页面实例，专门验证拖到边缘时的自动滚动。
    // 摆在窗口之外，免得挡住其它用例的命中区。
    Flickable {
        id: scroller

        x: 1000
        y: 0
        width: 420
        height: 240
        contentHeight: scrolledPage.implicitHeight
        clip: true

        SettingsAppearancePage {
            id: scrolledPage

            width: 420
            appSettingsRef: settingsMock
        }
    }

    function rowIn(page, entryId) {
        return findChild(page, "settingsSidebarOrderRow-" + entryId)
    }

    function rowCenterScene(entryId) {
        var row = testCase.rowIn(appearancePage, entryId)
        return row.mapToItem(null, row.width / 2, row.height / 2)
    }

    function test_sidebarOrderRowsHaveNoMoveButtons() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)
        // 2026-09-11 用户看过设计稿后选定「只留拖动，去掉 ↑↓」。
        compare(findChild(appearancePage, "settingsSidebarMoveUp-goals"), null)
        compare(findChild(appearancePage, "settingsSidebarMoveDown-goals"), null)
    }

    function test_dragDownDropsAfterTargetAndCommitsWholeOrder() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)

        appearancePage.beginDrag("goals")
        var target = testCase.rowCenterScene("focus")
        appearancePage.updateDrag("goals", target.x, target.y)
        compare(appearancePage.dropTargetIndex, 2)
        // 拖动期间不动模型：松手之前存储里还是原顺序。中途改模型会重建全部行，
        // 正在拖的那一行连同它的 DragHandler 一起被销毁。
        compare(settingsMock.sidebarOrder[0], "goals")

        var indicator = findChild(appearancePage, "settingsSidebarDropIndicator")
        verify(indicator)
        var focusRow = testCase.rowIn(appearancePage, "focus")
        // 往下拖：指示线落在目标行下方，和松手后的真实位置一致。
        verify(indicator.y > focusRow.y + focusRow.height / 2,
               "指示线 " + indicator.y + " 应在目标行下方")

        appearancePage.finishDrag("goals", false)
        compare(settingsMock.sidebarOrder[0], "today")
        compare(settingsMock.sidebarOrder[1], "focus")
        compare(settingsMock.sidebarOrder[2], "goals")
        compare(appearancePage.draggingEntryId, "")
        compare(appearancePage.dropTargetIndex, -1)

        // 整份提交，侧栏跟着变。
        wait(20)
        compare(sidebar.orderedEntryIds[2], "goals")
    }

    function test_dragUpDropsBeforeTarget() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)

        appearancePage.beginDrag("focus")
        var target = testCase.rowCenterScene("goals")
        appearancePage.updateDrag("focus", target.x, target.y)
        compare(appearancePage.dropTargetIndex, 0)

        var indicator = findChild(appearancePage, "settingsSidebarDropIndicator")
        var goalsRow = testCase.rowIn(appearancePage, "goals")
        verify(indicator.y < goalsRow.y + goalsRow.height / 2,
               "指示线 " + indicator.y + " 应在目标行上方")

        appearancePage.finishDrag("focus", false)
        compare(settingsMock.sidebarOrder[0], "focus")
        compare(settingsMock.sidebarOrder[1], "goals")
        compare(settingsMock.sidebarOrder[2], "today")
    }

    function test_cancelledOrUnmovedDragWritesNothing() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)

        appearancePage.beginDrag("goals")
        var target = testCase.rowCenterScene("focus")
        appearancePage.updateDrag("goals", target.x, target.y)
        appearancePage.finishDrag("goals", true)
        compare(settingsMock.sidebarOrder[0], "goals")

        // 放回原位也不提交：同样的顺序整份写回去，只会让侧栏白重建一次。
        appearancePage.beginDrag("today")
        var ownSlot = testCase.rowCenterScene("today")
        appearancePage.updateDrag("today", ownSlot.x, ownSlot.y)
        compare(findChild(appearancePage, "settingsSidebarDropIndicator").visible, false)
        appearancePage.finishDrag("today", false)
        compare(settingsMock.sidebarOrder[1], "today")
    }

    function test_pointerOutsideListClampsToFirstOrLastSlot() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)

        appearancePage.beginDrag("today")
        // 拖到列表上方松手就是「放到第一个」，不能因为指针出界就判成无效落点。
        var top = testCase.rowCenterScene("goals")
        appearancePage.updateDrag("today", top.x, top.y - 400)
        compare(appearancePage.dropTargetIndex, 0)

        var bottom = testCase.rowCenterScene("focus")
        appearancePage.updateDrag("today", bottom.x, bottom.y + 400)
        compare(appearancePage.dropTargetIndex, 2)
        appearancePage.finishDrag("today", true)
    }

    function test_mouseDragReordersThroughDragHandler() {
        settingsMock.sidebarOrder = ["goals", "today", "focus"]
        wait(20)

        var row = testCase.rowIn(appearancePage, "goals")
        var lastRow = testCase.rowIn(appearancePage, "focus")
        verify(row)
        verify(lastRow)
        // 侧栏顺序在页面底部，默认落在窗口之外；先把页面上移，让这几行进到窗口里，
        // 否则收不到真实鼠标事件。
        var originalY = appearancePage.y
        appearancePage.y = originalY - row.mapToItem(appearancePage, 0, 0).y + 40
        wait(20)

        var dropY = lastRow.mapToItem(row, 0, lastRow.height / 2).y
        mousePress(row, 60, row.height / 2)
        for (var step = 1; step <= 6; ++step) {
            mouseMove(row, 60, row.height / 2 + (dropY - row.height / 2) * step / 6, 16, Qt.LeftButton)
        }
        mouseRelease(row, 60, dropY, Qt.LeftButton)

        tryVerify(function () { return settingsMock.sidebarOrder[2] === "goals" }, 2000)
        appearancePage.y = originalY
    }

    function test_dragNearViewportEdgeAutoScrolls() {
        settingsMock.sidebarOrder = testCase.defaultOrder()
        wait(20)

        var firstRow = testCase.rowIn(scrolledPage, "dashboard")
        verify(firstRow)
        // 先滚到侧栏顺序那一段的开头。
        scroller.contentY = Math.max(0, firstRow.mapToItem(scrolledPage, 0, 0).y - 20)
        wait(20)
        var before = scroller.contentY

        scrolledPage.beginDrag("dashboard")
        // 设置页自己不持有滚动区（ScrollView 在 SettingsDialog 里），拖动开始时沿父链找到它。
        compare(scrolledPage.dragScroller, scroller)

        var bottomEdge = scroller.mapToItem(null, 10, scroller.height - 6)
        scrolledPage.updateDrag("dashboard", bottomEdge.x, bottomEdge.y)
        tryVerify(function () { return scroller.contentY > before + 20 }, 2000)

        scrolledPage.finishDrag("dashboard", true)
        compare(scrolledPage.dragScroller, null)
    }
}
