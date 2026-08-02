import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase

    name: "NaturalCompletionNoticeDialog"
    when: windowShown
    width: 860
    height: 620

    NaturalCompletionNoticeDialog {
        id: dialog
    }

    Component {
        id: signalSpyComponent

        SignalSpy {}
    }

    function init() {
        dialog.close()
    }

    function test_copyAndKeyboardConfirmation() {
        var acknowledgedSpy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dialog,
            signalName: "acknowledged"
        })
        verify(acknowledgedSpy)

        dialog.open()
        tryCompare(dialog, "opened", true)

        var title = findChild(dialog, "naturalCompletionNoticeTitle")
        var body = findChild(dialog, "naturalCompletionNoticeBody")
        var acknowledgeButton = findChild(dialog, "naturalCompletionNoticeAcknowledgeButton")
        verify(title)
        verify(body)
        verify(acknowledgeButton)
        compare(title.text, "完整番茄计数规则已更新")
        compare(body.text, "升级后，只有自然计时到点的番茄会计入番茄数量、长期目标和相关统计。手动提前停止仍会保留专注时长，但不计为完整番茄。历史记录已按兼容规则保留，因此升级日前后的数字口径可能不同。")
        verify(acknowledgeButton.implicitHeight >= 44)
        verify(acknowledgeButton.activeFocusOnTab)
        var bodyPosition = dialog.background.mapFromItem(body, 0, 0)
        verify(bodyPosition.y >= 0)
        verify(bodyPosition.y + body.height <= dialog.background.height)

        acknowledgeButton.forceActiveFocus()
        keyClick(Qt.Key_Return)
        tryCompare(acknowledgedSpy, "count", 1)
        tryCompare(dialog, "opened", false)

        // 已关闭的同一实例不能因残留按键再发第二次确认。
        dialog.acknowledge()
        compare(acknowledgedSpy.count, 1)
    }

    function test_spaceKeyConfirms() {
        var acknowledgedSpy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dialog,
            signalName: "acknowledged"
        })
        verify(acknowledgedSpy)

        dialog.open()
        tryCompare(dialog, "opened", true)
        var acknowledgeButton = findChild(dialog, "naturalCompletionNoticeAcknowledgeButton")
        verify(acknowledgeButton)
        acknowledgeButton.forceActiveFocus()
        keyClick(Qt.Key_Space)
        tryCompare(acknowledgedSpy, "count", 1)
        tryCompare(dialog, "opened", false)
    }

    function test_escapeDoesNotAcknowledge() {
        var acknowledgedSpy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dialog,
            signalName: "acknowledged"
        })
        verify(acknowledgedSpy)

        dialog.open()
        tryCompare(dialog, "opened", true)
        keyClick(Qt.Key_Escape)
        tryCompare(dialog, "opened", false)
        compare(acknowledgedSpy.count, 0)
    }
}
