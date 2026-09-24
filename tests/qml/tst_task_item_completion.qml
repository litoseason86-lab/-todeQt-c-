import QtQuick
import QtTest
import "../../qml/components"

// 任务卡上的「完成」按钮与完成记录行。
// 单独成文件而不是并进 tst_task_item_edit：这里要用真实鼠标点击，测试窗口必须可见，
// 不想为此改变那份用例的运行环境。
TestCase {
    id: testCase
    name: "TaskItemCompletion"
    when: windowShown
    visible: true
    width: 700
    height: 200

    TaskItem {
        id: item
        width: testCase.width
        taskId: 42
        taskTitle: "数据结构"
        taskCompleted: false
    }

    SignalSpy {
        id: completeSpy
        target: item
        signalName: "completeWithNoteClicked"
    }

    SignalSpy {
        id: checkboxSpy
        target: item
        signalName: "completionChanged"
    }

    function init() {
        item.taskCompleted = false
        // playCompletedFeedback 只改视觉态、不改 taskCompleted，上面那行复位不到它，逐项归位。
        item.visualTaskCompleted = false
        item.completionAnimationPlayed = false
        item.showCompleteWithNote = false
        item.showStartFocus = true
        item.compact = false
        item.completionNote = ""
        completeSpy.clear()
        checkboxSpy.clear()
        // 上一条用例的粒子还在飞时 burst 会直接返回，等它们自己销毁完。
        tryCompare(testCase.particles(), "particleCount", 0, 3000)
    }

    function particles() {
        const container = findChild(item, "completionParticleContainer")
        verify(container !== null)
        return container
    }

    function test_completeButtonRequiresHostOptIn() {
        const button = findChild(item, "taskCompleteButton")
        verify(button)
        // 默认不露出：其它页面没有接完成弹窗，露出来点了也没反应。
        compare(button.visible, false)

        item.showCompleteWithNote = true
        mouseClick(button)
        compare(completeSpy.count, 1)
        compare(completeSpy.signalArguments[0][0], 42)
        // 点「完成」只是请求弹窗：写库成功之前，卡片不能先把自己画成已完成，也不能走复选框那条完成路径。
        compare(item.visualTaskCompleted, false)
        compare(checkboxSpy.count, 0)
    }

    function test_completeButtonHidesOnceCompleted() {
        item.showCompleteWithNote = true
        item.taskCompleted = true
        // 已完成就不再露出「完成」，改记录走「编辑」。
        compare(findChild(item, "taskCompleteButton").visible, false)
    }

    function test_completionNoteLineOnlyOnCompletedFullRows() {
        item.completionNote = "做完 1–15 题\n递归还不熟"
        // 未完成：记录还在库里（取消完成时保留），但卡片上不该出现「完成：……」。
        compare(item.showsCompletionNote, false)
        compare(findChild(item, "taskCompletionNoteLine").visible, false)

        item.taskCompleted = true
        compare(item.showsCompletionNote, true)
        // 多行并成一行，省略号之前能多看到一点。
        compare(findChild(item, "taskCompletionNoteLine").text, "完成：做完 1–15 题 · 递归还不熟")

        // 紧凑只读行（仪表盘已完成列表）不显示，免得把列表撑高。
        item.compact = true
        compare(item.showsCompletionNote, false)
        item.compact = false

        // 没写记录就不占这一行。
        item.completionNote = ""
        compare(item.showsCompletionNote, false)
    }

    function test_completedFeedbackMatchesCheckboxPath() {
        const checkbox = findChild(item, "taskCheckBox")
        verify(checkbox)

        item.playCompletedFeedback()
        // 与点复选框同一套反馈：方框勾上、进入完成态、粒子从复选框处放一次。
        compare(item.visualTaskCompleted, true)
        compare(checkbox.checked, true)
        compare(item.state, "completed")
        verify(testCase.particles().particleCount > 0)

        // 刷新回来的数据把 taskCompleted 置真时不能再放第二遍。
        tryCompare(testCase.particles(), "particleCount", 0, 3000)
        item.taskCompleted = true
        compare(testCase.particles().particleCount, 0)
        // 反馈本身不写库：写库是父视图在弹窗提交时做的，这里不能再发一次完成信号。
        compare(checkboxSpy.count, 0)
    }
}
