import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "ManualSessionDialog"
    when: windowShown
    width: 900
    height: 760
    visible: true

    property var submittedChanges: null
    property int addCalls: 0
    ManualSessionDialog {
        id: dialog
        parent: testCase
        editHandler: function(id, changes) { testCase.submittedChanges = changes; return "" }
        submitHandler: function() { testCase.addCalls++; return "" }
    }
    function init() {
        submittedChanges = null
        addCalls = 0
    }
    function cleanup() { dialog.close() }
    function test_invalidDateIsNotNormalized() {
        dialog.openForAdd("2026-02-31", [])
        dialog.submit()
        compare(addCalls, 0)
        verify(dialog.errorText.length > 0)
        findChild(dialog, "manualSessionDateField").text = "2026-02-28"
        dialog.submit()
        compare(addCalls, 1)
    }
    function test_noChangeDoesNotRoundOrRemovePause() {
        dialog.openForEdit({id: 8, startTime: "2026-09-01T09:00:37.123", durationSeconds: 1859}, [])
        dialog.submit()
        compare(Object.keys(submittedChanges).length, 0)
    }
    function test_shortRestKeepsSecondsOnNoop() {
        dialog.openForEdit({id: 8, isRest: true, startTime: "2026-09-01T09:00:37.123", durationSeconds: 18}, [])
        dialog.submit()
        compare(Object.keys(submittedChanges).length, 0)
    }

    function test_missingOriginalTaskDoesNotSilentlyDetach() {
        // 候选任务有条数上限，原归属任务可能不在其中；下拉必须把它补进去，
        // 否则保存时会静默把记录改成「不关联任务」。
        dialog.openForEdit({id: 8, taskId: 42, taskTitle: "线性代数",
                            startTime: "2026-09-01T09:00:00", durationSeconds: 1800},
                           [{id: 7, title: "别的任务"}])
        compare(dialog.taskOptions.length, 3)
        compare(Number(dialog.taskOptions[1].id), 42)
        dialog.submit()
        compare(Object.keys(submittedChanges).length, 0)
    }

    function test_startEditDoesNotSubmitRoundedDuration() {
        dialog.openForEdit({id: 8, startTime: "2026-09-01T09:00:37.123", durationSeconds: 1859}, [])
        findChild(dialog, "manualSessionHourField").text = "10"
        dialog.submit()
        compare(Object.keys(submittedChanges).length, 1)
        compare(submittedChanges.startTime.getHours(), 10)
    }
}
