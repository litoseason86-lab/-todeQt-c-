import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 任务卡「完成」弹窗：写下这次具体完成了什么，再把任务标为完成。
// 这里只测弹窗自己的契约（预填、校验、提交、键盘、失败重试）；写库与列表刷新在今日页用例里测。
TestCase {
    id: testCase
    name: "CompleteTaskDialog"
    when: windowShown
    // 要用真实的鼠标、键盘事件驱动，测试窗口必须可见。
    visible: true
    width: 600
    height: 500

    property var submissions: []
    property bool submitResult: true

    QtObject {
        id: coordinator

        property bool refreshBlocked: false
        property bool failRead: false
        property string lastError: "任务已不存在"
        property var latest: ({ id: 42, title: "数据库里的最新标题", completionNote: "" })
        signal changed()

        function beginEdit(owner, id, source) {
            refreshBlocked = !failRead
            changed()
            return failRead ? ({}) : latest
        }
        function end(owner) {
            refreshBlocked = false
            changed()
        }
    }

    CompleteTaskDialog {
        id: dialog

        parent: testCase
        noteSubmitter: function (taskId, note) {
            testCase.submissions = testCase.submissions.concat([{ taskId: taskId, note: note }])
            return testCase.submitResult
        }
    }

    // 不注入写入函数时走信号，供独立使用。
    CompleteTaskDialog {
        id: signalDialog

        parent: testCase
    }

    SignalSpy {
        id: openFailedSpy
        target: dialog
        signalName: "openFailed"
    }

    SignalSpy {
        id: submittedSpy
        target: signalDialog
        signalName: "completionSubmitted"
    }

    function init() {
        dialog.finishEditing()
        dialog.interactionCoordinatorRef = null
        // 表单状态不会随关闭自动复位（离屏环境不保证投递关闭信号），逐项归位。
        dialog.maxNoteLength = 2000
        coordinator.failRead = false
        coordinator.refreshBlocked = false
        coordinator.latest = { id: 42, title: "数据库里的最新标题", completionNote: "" }
        testCase.submissions = []
        testCase.submitResult = true
        openFailedSpy.clear()
        submittedSpy.clear()
        dialog.close()
        signalDialog.close()
        tryCompare(dialog, "visible", false, 3000)
        tryCompare(signalDialog, "visible", false, 3000)
    }

    function noteField() {
        return findChild(dialog, "completeNoteField")
    }

    function openDialog(task) {
        verify(dialog.openForTask(task))
        tryCompare(dialog, "opened", true, 3000)
    }

    function test_openRereadsLatestTaskAndReleasesRegistration() {
        // 列表里的行可能已经过期（外部 AI 刚改过标题）：预填必须用协调器读回的最新数据。
        dialog.interactionCoordinatorRef = coordinator
        coordinator.latest = { id: 42, title: "数据库里的最新标题", completionNote: "取消完成前写的" }
        testCase.openDialog({ id: 42, title: "列表里的旧标题" })
        compare(findChild(dialog, "completeTaskTitle").text, "数据库里的最新标题")
        // 取消过完成的任务还留着上次的记录，要预填回来接着改。
        compare(testCase.noteField().text, "取消完成前写的")
        compare(coordinator.refreshBlocked, true)

        mouseClick(findChild(dialog, "completeCancelButton"))
        tryCompare(dialog, "opened", false, 3000)
        // 取消也必须释放登记，否则今日列表会一直停止刷新。
        compare(coordinator.refreshBlocked, false)
        compare(testCase.submissions.length, 0)
    }

    function test_openFailureReportsAndStaysClosed() {
        dialog.interactionCoordinatorRef = coordinator
        coordinator.failRead = true
        compare(dialog.openForTask({ id: 42, title: "已经被删的任务" }), false)
        compare(openFailedSpy.count, 1)
        compare(openFailedSpy.signalArguments[0][0], "任务已不存在")
        compare(dialog.opened, false)
        compare(coordinator.refreshBlocked, false)
    }

    function test_confirmSubmitsTrimmedNoteExactlyOnce() {
        testCase.openDialog({ id: 42, title: "数据结构" })
        testCase.noteField().text = "  做完 1–15 题\n递归还不熟  \n"
        mouseClick(findChild(dialog, "completeConfirmButton"))

        compare(testCase.submissions.length, 1)
        compare(testCase.submissions[0].taskId, 42)
        // 首尾空白去掉，中间的换行保留：多行记录是用户自己分的段。
        compare(testCase.submissions[0].note, "做完 1–15 题\n递归还不熟")

        // 退出动画期间弹窗还在，再提交一次不能写第二遍。
        compare(dialog.submit(), false)
        compare(testCase.submissions.length, 1)
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_emptyNoteStillCompletes() {
        // 记录是可选的：什么都不写也要能完成，不能被当成空表单拦下。
        testCase.openDialog({ id: 7, title: "复习单词" })
        compare(testCase.noteField().text, "")
        mouseClick(findChild(dialog, "completeConfirmButton"))
        compare(testCase.submissions.length, 1)
        compare(testCase.submissions[0].taskId, 7)
        compare(testCase.submissions[0].note, "")
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_noteLengthBoundary() {
        dialog.maxNoteLength = 10
        testCase.openDialog({ id: 42, title: "数据结构" })
        const field = testCase.noteField()

        // 超一个字：拦下并说清楚是哪一栏，草稿原样保留，不写库。
        field.text = "一二三四五六七八九十十"
        compare(dialog.submit(), false)
        compare(testCase.submissions.length, 0)
        verify(dialog.errorText.indexOf("完成记录太长了") === 0, dialog.errorText)
        compare(field.text, "一二三四五六七八九十十")
        compare(dialog.opened, true)

        // 正好在上限（首尾空白不计）：放行，改回合法长度时错误提示随之消失。
        field.text = "  一二三四五六七八九十  "
        compare(dialog.errorText, "")
        compare(dialog.submit(), true)
        compare(testCase.submissions.length, 1)
        compare(testCase.submissions[0].note, "一二三四五六七八九十")
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_failedSubmitKeepsDraftForRetry() {
        testCase.submitResult = false
        testCase.openDialog({ id: 42, title: "数据结构" })
        testCase.noteField().text = "做完第三章"
        mouseClick(findChild(dialog, "completeConfirmButton"))

        compare(testCase.submissions.length, 1)
        compare(dialog.errorText, "保存失败，请检查数据库后重试")
        compare(testCase.noteField().text, "做完第三章")
        compare(dialog.opened, true)

        // 问题排除后原地重试即可，不用关掉重开、也不用重写。
        testCase.submitResult = true
        mouseClick(findChild(dialog, "completeConfirmButton"))
        compare(testCase.submissions.length, 2)
        compare(testCase.submissions[1].note, "做完第三章")
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_returnInsertsNewlineAndCommandReturnSubmits() {
        testCase.openDialog({ id: 42, title: "数据结构" })
        const field = testCase.noteField()
        tryCompare(field, "activeFocus", true, 3000)

        keyClick(Qt.Key_A)
        keyClick(Qt.Key_Return)
        keyClick(Qt.Key_B)
        // 普通回车是换行，不能一按就把只写了半句的记录提交掉。
        compare(testCase.submissions.length, 0)
        compare(field.text, "a\nb")

        // ⌘↩ 完成：Qt 在 macOS 上把 Command 报成 ControlModifier。
        keyClick(Qt.Key_Return, Qt.ControlModifier)
        compare(testCase.submissions.length, 1)
        compare(testCase.submissions[0].note, "a\nb")
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_tabLeavesNoteFieldAndReachesButtons() {
        testCase.openDialog({ id: 42, title: "数据结构" })
        const field = testCase.noteField()
        tryCompare(field, "activeFocus", true, 3000)

        // Tab 不能被输入框吞成制表符，否则键盘用户进了输入框就够不着按钮。
        keyClick(Qt.Key_Tab)
        compare(field.text.indexOf("\t"), -1)
        tryCompare(findChild(dialog, "completeCancelButton"), "activeFocus", true, 3000)
        keyClick(Qt.Key_Tab)
        tryCompare(findChild(dialog, "completeConfirmButton"), "activeFocus", true, 3000)

        // 焦点停在「完成」上，按空格就是完成。
        keyClick(Qt.Key_Space)
        compare(testCase.submissions.length, 1)
        tryCompare(dialog, "opened", false, 3000)
    }

    function test_withoutSubmitterEmitsSignal() {
        verify(signalDialog.openForTask({ id: 9, title: "高等数学" }))
        tryCompare(signalDialog, "opened", true, 3000)
        findChild(signalDialog, "completeNoteField").text = " 做完极限 "
        compare(signalDialog.submit(), true)
        compare(submittedSpy.count, 1)
        compare(submittedSpy.signalArguments[0][0], 9)
        compare(submittedSpy.signalArguments[0][1], "做完极限")
        tryCompare(signalDialog, "opened", false, 3000)
    }
}
