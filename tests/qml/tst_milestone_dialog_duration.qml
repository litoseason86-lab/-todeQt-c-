import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 里程碑进度文案按时长展示。
//
// 目标的计量单位是分钟，不是番茄数。把 1500 分钟写成「1500 个番茄」
// 会凭空放大 25 倍，用户看到的进度条和数字对不上。
TestCase {
    id: testCase
    name: "MilestoneDialogDuration"
    when: windowShown
    visible: true
    width: 640
    height: 480

    MilestoneDialog { id: milestone }

    function test_progressTextIsWrittenInHoursNotPomodoros() {
        milestone.doneCount = 1500
        milestone.targetCount = 6000
        var text = findChild(milestone, "milestoneProgressText").text
        compare(text, "25 小时 / 100 小时，还剩 75 小时")
    }
}
