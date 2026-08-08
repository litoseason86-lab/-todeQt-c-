import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 数据库整体替换期间的阻断遮罩。它会吞掉 Escape 且没有取消入口，所以「用户能不能
// 看出它还活着」是这个组件唯一的实质职责——两种动效档位下都必须成立。
TestCase {
    id: testCase
    name: "BackupOverlay"
    when: windowShown
    width: 480
    height: 320

    Component {
        id: overlayComponent

        BackupOperationOverlay {
            width: 480
            height: 320
            message: "正在恢复数据"
        }
    }

    function findChildByObjectName(item, name) {
        if (!item) {
            return null
        }
        if (item.objectName === name) {
            return item
        }
        var slots = item.data
        if (slots === undefined || slots === null) {
            slots = item.children
        }
        if (slots === undefined || slots === null) {
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

    function test_normal_motion_uses_the_spinner_and_no_timer() {
        var overlay = createTemporaryObject(overlayComponent, testCase, { reduceMotion: false })
        verify(overlay)
        compare(overlay.showsElapsedInstead, false)

        var timer = findChildByObjectName(overlay, "backupOverlayElapsedTimer")
        verify(timer)
        // 旋转指示器已经在表达「还活着」，此时不该再多跑一个每秒定时器。
        compare(timer.running, false)
    }

    function test_reduced_motion_replaces_the_spinner_with_a_live_readout() {
        var overlay = createTemporaryObject(overlayComponent, testCase, { reduceMotion: true })
        verify(overlay)
        compare(overlay.showsElapsedInstead, true)

        // 关键回归点：减少动效曾经把指示器整个移除，遮罩上只剩一行静止文字，
        // 而它还吞掉 Escape——用户没有任何办法区分「正在跑」和「已经卡死」。
        var timer = findChildByObjectName(overlay, "backupOverlayElapsedTimer")
        verify(timer)
        compare(timer.running, true)

        var readout = findChildByObjectName(overlay, "backupOverlayElapsedText")
        verify(readout)
        compare(readout.text, "已用 0 秒")

        overlay.elapsedSeconds = 7
        compare(readout.text, "已用 7 秒")
    }

    function test_escape_stays_swallowed() {
        var overlay = createTemporaryObject(overlayComponent, testCase, { reduceMotion: true })
        verify(overlay)
        overlay.forceActiveFocus()
        // 恢复事务不能被界面层中断；这条断言保证上面的改动没有顺手放开按键。
        keyClick(Qt.Key_Escape)
        compare(overlay.parent, testCase)
    }
}
