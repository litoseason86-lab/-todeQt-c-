import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 手工补录的界面契约。服务层的口径（补录记为自由计时、拦重叠、拦未来）由
// ServiceTests 守；这里守界面这一半：填什么、传什么、失败了怎么显示。
TestCase {
    id: testCase
    name: "ManualSession"
    when: windowShown
    width: 560
    height: 520

    property var lastCall: null
    property string nextFailure: ""

    Component {
        id: dialogComponent

        ManualSessionDialog {
            submitHandler: function (sessionId, startDateTime, durationMinutes, taskId) {
                testCase.lastCall = { sessionId: sessionId, start: startDateTime,
                                      minutes: durationMinutes, taskId: taskId }
                return testCase.nextFailure
            }
        }
    }

    function init() {
        testCase.lastCall = null
        testCase.nextFailure = ""
    }

    function test_add_passes_the_composed_start_time_and_duration() {
        var dlg = createTemporaryObject(dialogComponent, testCase)
        verify(!!dlg, "Component exists")
        dlg.openForAdd("2026-08-10", [{ id: 7, title: "考研数学" }])
        wait(30)

        findChild(dlg, "manualSessionHourField").text = "14"
        findChild(dlg, "manualSessionMinuteField").text = "05"
        findChild(dlg, "manualSessionDurationHourField").text = "1"
        findChild(dlg, "manualSessionDurationMinuteField").text = "30"
        dlg.submit()

        verify(!!testCase.lastCall, "submitHandler 没被调用")
        compare(testCase.lastCall.sessionId, -1)
        compare(testCase.lastCall.minutes, 90)
        // 日期与时刻要合成同一个时间点，不能各传各的。
        compare(Qt.formatDateTime(testCase.lastCall.start, "yyyy-MM-dd HH:mm"), "2026-08-10 14:05")
        // 默认第一项是「不关联任务」。
        compare(testCase.lastCall.taskId, -1)
    }

    function test_task_can_be_attributed() {
        var dlg = createTemporaryObject(dialogComponent, testCase)
        dlg.openForAdd("2026-08-10", [{ id: 7, title: "考研数学" }])
        wait(30)
        findChild(dlg, "manualSessionTaskCombo").currentIndex = 1
        dlg.submit()
        compare(testCase.lastCall.taskId, 7)
    }

    function test_edit_prefills_from_the_existing_record() {
        var dlg = createTemporaryObject(dialogComponent, testCase)
        dlg.openForEdit({ id: 42, startTime: "2026-08-09T20:15:00", durationSeconds: 45 * 60 }, [])
        wait(30)

        compare(findChild(dlg, "manualSessionDateField").text, "2026-08-09")
        compare(findChild(dlg, "manualSessionHourField").text, "20")
        compare(findChild(dlg, "manualSessionMinuteField").text, "15")
        compare(findChild(dlg, "manualSessionDurationMinuteField").text, "45")

        dlg.submit()
        compare(testCase.lastCall.sessionId, 42)
        compare(testCase.lastCall.minutes, 45)
    }

    function test_service_failure_keeps_the_dialog_open_with_the_reason() {
        var dlg = createTemporaryObject(dialogComponent, testCase)
        dlg.openForAdd("2026-08-10", [])
        wait(30)
        testCase.nextFailure = "这段时间已有专注记录"
        dlg.submit()

        // 失败必须留在原地并把原因显示出来——静默关闭等于把用户的输入吞掉。
        compare(dlg.opened, true)
        compare(findChild(dlg, "manualSessionError").text, "这段时间已有专注记录")
    }

    function test_malformed_date_is_rejected_before_reaching_the_service() {
        var dlg = createTemporaryObject(dialogComponent, testCase)
        dlg.openForAdd("2026-08-10", [])
        wait(30)
        findChild(dlg, "manualSessionDateField").text = "八月十日"
        dlg.submit()

        compare(testCase.lastCall, null)
        verify(findChild(dlg, "manualSessionError").text.length > 0)
    }
}
