import QtQuick
import QtTest
import "../../qml"
import "../../qml/mobile"

// 伴侣页快速记录的输入边界：标题到了服务端上限时，输入框会静默截断，
// 必须同时出现一行提示，用户才知道多出来的字没有记进去。
TestCase {
    id: testCase
    name: "CompanionQuickAdd"
    when: windowShown
    width: 400
    height: 800

    QtObject {
        id: timerStub

        signal phaseCompleted(int phase)
        signal phaseSettledOffline(int phase)
        signal currentTaskChanged()

        property bool freeTimingAllowed: false
        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int mode: 1
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
        property int minimumValidMinutes: 3
        property int completedPomodoros: 0

        function startPomodoroWork(taskId, title, seconds) { return false }
        function startBreakForTask(seconds, taskId, title) { return false }
        function stopFocus() { return true }
        function pauseFocus() { return true }
        function resumeFocus() { return true }
    }

    QtObject {
        id: settingsStub

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
        property bool reduceMotion: true
        property bool slimClockFont: true
        property bool autoStartBreak: false
        property bool autoStartNextPomodoro: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property int freeTimerWarningHours: 8
        property int dayStartHour: 4
    }

    QtObject {
        id: taskStub

        signal tasksChanged()
        signal operationFailed(string message)

        // 上限取得很小，方便用短文本构造「刚好到顶」和「超出被截断」。
        property int maxTitleLength: 5
        property var added: []

        function getTodayTasks() { return [] }
        function getTask(id) { return null }
        function addTask(title, date) {
            added = added.concat([title])
            return true
        }
        function setTaskCompleted(id, completed) { return true }
    }

    Component {
        id: companionComponent

        CompanionWindow {
            width: testCase.width
            height: testCase.height
            focusTimerRef: timerStub
            appSettingsRef: settingsStub
            taskManagerRef: taskStub
        }
    }

    function init() {
        taskStub.added = []
    }

    function test_limitHintAppearsWhenTitleReachesMaximum() {
        // 输入到上限（含粘贴被截断）时显示上限提示，没到上限时不打扰；提交成功清空后提示随之消失。
        var companion = createTemporaryObject(companionComponent, testCase)
        verify(companion !== null)
        var field = findChild(companion, "companionQuickAddField")
        var hint = findChild(companion, "companionQuickAddLimitHint")
        verify(field !== null)
        verify(hint !== null)
        // 断言驱动 visible 的 atLimit：TestCase 默认不可见，挂在它下面的项读 visible 恒为假。
        compare(field.maximumLength, 5)
        verify(!hint.atLimit)

        field.text = "一二三四"
        verify(!hint.atLimit)

        // 粘贴一段超长文本：输入框只留下前 5 个字，提示必须出现并写明上限。
        field.text = "一二三四五六七"
        compare(field.text, "一二三四五")
        verify(hint.atLimit)
        verify(hint.text.indexOf("5") >= 0)

        field.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(taskStub.added, ["一二三四五"])
        compare(field.text, "")
        verify(!hint.atLimit)
    }

    function test_unrelatedCompletionFailureDoesNotBecomeLoadError_data() {
        // 产品保证：伴侣页不会把其它入口的完成、新建、修改或改期失败再显示为加载错误。
        return [ { tag: "create", message: "新建任务失败：数据库未打开" },
                 { tag: "update", message: "修改任务失败：任务不存在" },
                 { tag: "move", message: "任务改期失败：日期无效" },
                 { tag: "complete", message: "完成失败：任务不存在" },
                 { tag: "uncomplete", message: "取消完成失败：数据库未打开" },
                 { tag: "note", message: "完成并记笔记失败：笔记超长" } ]
    }

    function test_unrelatedCompletionFailureDoesNotBecomeLoadError(data) {
        // 产品保证：完成失败沿用原入口提示，伴侣页只保留自身的其它任务错误。
        var companion = createTemporaryObject(companionComponent, testCase)
        verify(companion !== null)
        compare(companion.loadError, "")
        taskStub.operationFailed(data.message)
        compare(companion.loadError, "")
        taskStub.operationFailed("任务加载失败")
        compare(companion.loadError, "任务加载失败")
    }
}
