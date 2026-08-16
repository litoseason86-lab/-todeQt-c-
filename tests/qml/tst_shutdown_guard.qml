import QtQuick
import QtTest
import "../../qml/components"

// 关窗/退出的阻断判据。这段逻辑原本内联在 main.qml 的 onClosing 里，
// offscreen 测试起不了真窗口也触发不了关闭事件，所以拆成纯函数在这里锁住。
TestCase {
    id: testCase
    name: "ShutdownGuard"
    when: windowShown
    width: 200
    height: 200

    Component {
        id: guardComponent

        ShutdownGuard {
        }
    }

    function makeGuard() {
        var guard = createTemporaryObject(guardComponent, testCase)
        verify(guard)
        return guard
    }

    function test_idle_allows_close() {
        var guard = makeGuard()
        // 空串是"放行"的唯一表示；改成别的哨兵值会让调用方的 length > 0 判断失效。
        compare(guard.blockReason(false, "", false), "")
    }

    function test_backup_busy_blocks_with_its_own_text() {
        var guard = makeGuard()
        var reason = guard.blockReason(true, "正在恢复备份", false)
        verify(reason.indexOf("正在恢复备份") >= 0)
        verify(reason.indexOf("完成后再关闭") >= 0)
    }

    function test_backup_busy_without_text_falls_back() {
        var guard = makeGuard()
        // operationText 可能还没被赋值；不能因此退化成空串把关闭放行了。
        var reason = guard.blockReason(true, "", false)
        verify(reason.length > 0)
        verify(reason.indexOf("数据操作正在进行") >= 0)
    }

    function test_export_busy_blocks() {
        var guard = makeGuard()
        var reason = guard.blockReason(false, "", true)
        verify(reason.length > 0)
        verify(reason.indexOf("导出") >= 0)
    }

    function test_backup_wins_when_both_busy() {
        var guard = makeGuard()
        // 备份会原子替换整个库文件，比导出更危险；同时进行时必须报备份那条。
        var reason = guard.blockReason(true, "正在恢复备份", true)
        verify(reason.indexOf("正在恢复备份") >= 0)
        compare(reason.indexOf("导出"), -1)
    }
}
