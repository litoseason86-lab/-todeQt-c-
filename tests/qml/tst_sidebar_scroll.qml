pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"
import "TestWaits.js" as TestWaits

TestCase {
    id: testCase
    name: "SidebarScroll"
    when: windowShown
    visible: true
    width: 260
    height: 900

    readonly property var markers: ["仪", "今", "记", "专", "课", "周", "月", "数", "倒", "补", "备"]
    property bool savedReduceMotion: false

    QtObject {
        id: settingsMock
        property var sidebarOrder: []
    }
    Component {
        id: sidebarComponent
        Sidebar {
            width: 208
            height: testCase.height
            reduceMotionActive: true
            settingsRef: settingsMock
        }
    }
    property var sidebar: null

    SignalSpy { id: clickedSpy; target: testCase.sidebar; signalName: "itemClicked" }

    function initTestCase() {
        // 离屏取色和截图只看最终帧，避免并发负载下颜色动画干扰比较。
        savedReduceMotion = Theme.reduceMotion
        Theme.reduceMotion = true
    }
    function cleanupTestCase() { Theme.reduceMotion = savedReduceMotion }
    function init() {
        height = 900
        settingsMock.sidebarOrder = []
        sidebar = createTemporaryObject(sidebarComponent, testCase)
        verify(sidebar !== null)
        verify(waitForItemPolished(sidebar))
        clickedSpy.clear()
        failOnWarning(/Binding loop|TypeError|ReferenceError|RangeError/)
    }
    function cleanup() { sidebar = null }

    function entry(marker) {
        var item = findChild(sidebar, "sidebarItem-" + marker)
        verify(item !== null, "入口必须存在：" + marker)
        return item
    }
    function sidebarY(item) { return item.mapToItem(sidebar, 0, 0).y }
    function inViewport(item) {
        var scroll = findChild(sidebar, "sidebarEntryScroll")
        if (!scroll) return false
        var y = item.mapToItem(scroll, 0, 0).y
        return y >= -0.5 && y + item.height <= scroll.height + 0.5
    }
    function shorten() {
        height = 620
        // 根项不负责子 Layout 的 polish；等待固定项真正排到新窗口底部再发输入。
        tryCompare(sidebar, "height", 620, 3000)
        tryVerify(function () { return sidebarY(entry("设")) === 560 }, 3000)
        TestWaits.letElapse(testCase, 0, "让本轮布局排队的选中项定位回调（Qt.callLater）执行完，再模拟下一轮用户输入；回调本身没有可等的状态")
    }
    function assertFixedBottom() {
        compare(sidebarY(entry("废")), 512)
        compare(sidebarY(entry("设")), 560)
        compare(entry("废").height, 44)
        compare(entry("设").height, 44)
    }

    function test_tallWindowKeepsOriginalGeometry() {
        // 保证空间够时全部入口和底部固定项保持原位置与尺寸。
        // 期望值来自未修改 Sidebar 的 Qt 6.10.3 离屏探针：宽 208、高 900、默认顺序。
        for (var i = 0; i < markers.length; ++i) {
            var item = entry(markers[i])
            compare(item.mapToItem(sidebar, 0, 0).x, 16)
            compare(sidebarY(item), 58 + i * 48)
            compare(item.width, 176)
            compare(item.height, 44)
        }
        compare(sidebarY(entry("废")), 792)
        compare(sidebarY(entry("设")), 840)
        var bar = findChild(sidebar, "pageScrollBar")
        verify(bar !== null)
        compare(bar.size, 1)
        compare(bar.visible, false)
    }

    function test_shortWindowWheelReachesLastEntryAndClicks() {
        // 保证最小高度时可用滚轮到达最后入口并切页，底部两项不随滚动移动。
        shorten()
        assertFixedBottom()
        var last = entry("备")
        verify(!inViewport(last), "最后入口在滚动前应被遮住")
        mouseWheel(sidebar, 100, 300, 0, -720)
        tryVerify(function () { return inViewport(last) }, 3000)
        assertFixedBottom()
        // 滚轮平滑滚动尚在移动时会吞掉首次点击；等用户滚动停止后验证真实命中。
        tryCompare(findChild(sidebar, "sidebarEntryScroll"), "moving", false, 3000)
        mouseClick(last, last.width / 2, last.height / 2)
        compare(clickedSpy.count, 1)
        compare(clickedSpy.signalArguments[0][0], "memo")
    }

    function test_tabFocusRevealsHiddenEntryAndKeepsOrder() {
        // 保证 Tab 仍按原条目顺序导航，并自动露出刚获得焦点的入口。
        shorten()
        var next = entry("补")
        verify(!inViewport(next), "Tab 的目标在获得焦点前应被遮住")
        var previous = entry("倒")
        previous.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(previous, "activeFocus", true, 3000)
        keyClick(Qt.Key_Tab)
        tryCompare(next, "activeFocus", true, 3000)
        tryVerify(function () { return inViewport(next) }, 3000)
        keyClick(Qt.Key_Tab)
        tryCompare(entry("备"), "activeFocus", true, 3000)
        tryVerify(function () { return inViewport(entry("备")) }, 3000)
        keyClick(Qt.Key_Tab)
        tryCompare(entry("废"), "activeFocus", true, 3000)
        assertFixedBottom()
    }

    function test_pageSelectionRevealsEntryInBothDirections() {
        // 保证外部切页能把选中入口滚入视口，向上切回也恢复可见。
        shorten()
        verify(!inViewport(entry("备")))
        sidebar.currentView = "memo"
        tryVerify(function () { return inViewport(entry("备")) }, 3000)
        verify(!inViewport(entry("仪")))
        sidebar.currentView = "dashboard"
        tryVerify(function () { return inViewport(entry("仪")) }, 3000)
        assertFixedBottom()
    }

    function test_reorderingRevealsSelectedEntry() {
        // 保证更换侧栏顺序后，选中入口即使被移到末尾也会自动滚入视口。
        shorten()
        verify(inViewport(entry("今")))
        var reordered = sidebar.fallbackOrder.slice()
        reordered.splice(reordered.indexOf("today"), 1)
        reordered.push("today")
        settingsMock.sidebarOrder = reordered
        tryCompare(sidebar, "orderedEntryIds", reordered, 3000)
        // 新委托的初始 y 为 0，先确认它真的排到末尾，避免把尚未排位当成自动滚入。
        tryCompare(entry("今"), "y", 480, 3000)
        tryVerify(function () { return inViewport(entry("今")) }, 3000)
        var scroll = findChild(sidebar, "sidebarEntryScroll")
        verify(scroll.contentY > 0)
        assertFixedBottom()
    }

    function test_resizeKeepsSelectedEntryVisible() {
        // 保证选中底部入口后缩小窗口时，它仍可见；重新放大后恢复原坐标。
        sidebar.currentView = "memo"
        shorten()
        tryVerify(function () { return inViewport(entry("备")) }, 3000)
        height = 900
        verify(waitForItemPolished(sidebar))
        tryCompare(entry("仪"), "y", 0, 3000)
        tryVerify(function () { return sidebarY(entry("仪")) === 58 }, 3000)
    }

    function test_scrollBarStaysAtSidebarEdgeAndCanDrag() {
        // 保证矮窗口的滚动条贴侧栏右缘，拖动滑块可露出最后入口且不触发切页。
        shorten()
        var bar = findChild(sidebar, "pageScrollBar")
        verify(bar !== null)
        verify(bar.size < 1)
        compare(bar.width, 8)
        compare(bar.mapToItem(sidebar, 0, 0).x + bar.width, sidebar.width)
        compare(sidebarY(bar), 58)
        var last = entry("备")
        verify(!inViewport(last))
        var thumbY = bar.height * bar.size / 2
        mousePress(bar, bar.width / 2, thumbY)
        mouseMove(bar, bar.width / 2, thumbY + 100, 20)
        mouseRelease(bar, bar.width / 2, thumbY + 100)
        tryVerify(function () { return inViewport(last) }, 3000)
        compare(clickedSpy.count, 0)
        assertFixedBottom()
    }
}
