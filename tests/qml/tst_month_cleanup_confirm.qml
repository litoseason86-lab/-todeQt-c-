import QtQuick
import QtTest
import "../../qml/views"
import "../../qml"

// 「清理无效记录」永久删除专注记录且没有撤销，此前是一点即删、零测试覆盖。
// 这个文件只守一件事：必须点两下才真的删。
TestCase {
    id: testCase
    name: "MonthCleanupConfirm"
    when: windowShown
    width: 1000
    height: 800

    QtObject {
        id: focusHistoryService

        property int cleanupCalls: 0
        property int pendingInvalid: 7

        signal historyChanged()

        function invalidSessionCount() { return focusHistoryService.pendingInvalid }
        function cleanupInvalidSessions() {
            focusHistoryService.cleanupCalls += 1
            focusHistoryService.pendingInvalid = 0
            return 7
        }
        function getMonthSessions(year, month) { return [] }
    }

    QtObject {
        id: appSettings
        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService
        signal changed()
    }

    Component {
        id: monthComponent

        MonthGoalView {
            width: 1000
            height: 800
            focusHistoryServiceRef: focusHistoryService
            logicalDayServiceRef: logicalDayService
            settingsRef: appSettings
        }
    }

    function findChildByObjectName(item, name) {
        if (!item) {
            return null
        }
        if (item.objectName === name) {
            return item
        }
        var slots = item.data !== undefined && item.data !== null ? item.data : item.children
        if (!slots) {
            return null
        }
        for (var i = 0; i < slots.length; ++i) {
            var found = findChildByObjectName(slots[i], name)
            if (found) {
                return found
            }
        }
        return null
    }

    function init() {
        focusHistoryService.cleanupCalls = 0
        focusHistoryService.pendingInvalid = 7
    }

    function test_first_click_only_arms_the_button() {
        var view = createTemporaryObject(monthComponent, testCase)
        verify(view)
        var button = findChildByObjectName(view, "focusHistoryCleanupInvalidButton")
        verify(button)

        compare(button.confirming, false)
        button.clicked()
        // 第一下只进入确认态，绝不能删。
        compare(focusHistoryService.cleanupCalls, 0)
        compare(button.confirming, true)
        // 确认态要把条数摆出来，用户得知道自己要删掉多少。
        verify(button.text.indexOf("7") >= 0, "确认文案应显示待删条数")
    }

    function test_second_click_performs_the_deletion() {
        var view = createTemporaryObject(monthComponent, testCase)
        var button = findChildByObjectName(view, "focusHistoryCleanupInvalidButton")
        verify(button)

        button.clicked()
        button.clicked()
        compare(focusHistoryService.cleanupCalls, 1)
        // 删完必须退出确认态，避免按钮停在「已武装」状态。
        compare(button.confirming, false)
    }

    function test_losing_focus_disarms_the_button() {
        var view = createTemporaryObject(monthComponent, testCase)
        var button = findChildByObjectName(view, "focusHistoryCleanupInvalidButton")
        verify(button)

        button.clicked()
        compare(button.confirming, true)
        // 一个「已武装」的删除按钮不该长期留在界面上等下一次误触。
        button.forceActiveFocus()
        button.focus = false
        compare(button.confirming, false)
        compare(focusHistoryService.cleanupCalls, 0)
    }
}
