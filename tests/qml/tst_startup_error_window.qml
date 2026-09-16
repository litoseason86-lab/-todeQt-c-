import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml"

// 数据库打不开时的独立失败窗口。
//
// 这个窗口是用户在最糟情况下唯一能看到的界面：业务服务一个都没起来，
// 主界面根本不会加载。它必须自己能渲染（不依赖任何注入的服务），
// 并且告诉用户数据在哪——否则用户只能盯着一句「初始化失败」，
// 既找不到数据库，也不知道迁移快照 pomodoro_backup_*.db 存在。
TestCase {
    id: testCase
    name: "StartupErrorWindow"
    when: windowShown
    width: 640
    height: 480

    Component {
        id: windowComponent

        StartupErrorWindow {}
    }

    function test_windowRendersWithoutAnyInjectedService() {
        var win = createTemporaryObject(windowComponent, testCase)
        verify(win, "失败窗口必须能在没有任何业务服务的情况下实例化")
        verify(String(win.title).length > 0)
    }

    function test_dataDirectoryIsShownAndSelectable() {
        var win = createTemporaryObject(windowComponent, testCase,
                                        { dataDirectory: "/Users/someone/Library/Application Support/番茄Todo" })
        verify(win)
        var pathField = findChild(win, "startupErrorDataDirectory")
        verify(pathField, "失败窗口必须给出数据目录")
        compare(pathField.text, "/Users/someone/Library/Application Support/番茄Todo")
        // 用户第一件事就是复制这条路径，必须可选中且不可编辑。
        verify(pathField.readOnly, "路径不能被改写")
        verify(pathField.selectByMouse, "路径必须能选中复制")
    }

    function test_missingDataDirectoryHidesThePathBlock() {
        // 拿不到可写位置时不留一个空白输入框在那里。
        var win = createTemporaryObject(windowComponent, testCase, { dataDirectory: "" })
        verify(win)
        var pathField = findChild(win, "startupErrorDataDirectory")
        verify(pathField)
        compare(pathField.visible, false)
    }
}
