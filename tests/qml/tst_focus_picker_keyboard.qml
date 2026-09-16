import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 专注页任务选择器的键盘动线：展开后方向键选、回车确认。
TestCase {
    id: testCase
    name: "FocusPickerKeyboard"
    when: windowShown
    visible: true
    width: 640
    height: 480
    FocusTaskPicker {
        id: picker
        x: 160
        y: 40
        width: 320
        height: 44
        tasks: [{ id: 1, title: "第一项" }, { id: 2, title: "第二项" }]
    }
    SignalSpy { id: chosen; target: picker; signalName: "taskChosen" }
    function test_arrowsAndReturnChooseTask() {
        picker.expand()
        tryCompare(picker, "expanded", true)
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Return)
        compare(chosen.count, 1)
        compare(chosen.signalArguments[0][0], 2)
        compare(chosen.signalArguments[0][1], "第二项")
    }
}
