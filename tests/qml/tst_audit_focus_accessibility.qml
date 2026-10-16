import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"
import "../../qml/components/settings"
import "../../qml/mobile"

TestCase {
    id: testCase
    name: "AuditFocusAccessibility"
    when: windowShown
    visible: true
    width: 1000
    height: 1600

    property bool previousReduceMotion: false
    property var currentRoot: null

    QtObject {
        id: syncStub
        property bool enabled: true
        property string statusKey: "needsConfirmation"
        property bool hasProblem: false
        property bool choosesFolder: false
        property bool choosingFolder: false
        property bool hasFolder: true
        property string folderDisplayPath: "隔离测试文件夹"
        property string folderProblem: ""
        property string statusText: "等待确认"
        property string statusDetail: ""
        property string summaryText: "等待确认"
        property int pendingCount: 0
        property int logCount: 0
        function confirmJoin() {}
        function setEnabled(value) {}
        function rebuildFolder() {}
        function chooseFolder() {}
        function syncNow() {}
    }
    QtObject {
        id: companionStub
        property bool timerActive: false
        property int timerPhase: 0
        property int currentTaskId: -1
        function setCompleted(task, completed) {}
        function startPomodoro(id, title) {}
    }

    Component { id: stepperComponent; DurationStepper { namePrefix: "audit"; value: 10; width: 220 } }
    Component { id: dataComponent; SettingsDataPage { width: 800; syncControllerRef: syncStub } }
    Component { id: completeComponent; CompleteTaskDialog { parent: testCase } }
    Component { id: longComponent; LongFreeFocusConfirmDialog { parent: testCase } }
    Component { id: naturalComponent; NaturalCompletionNoticeDialog { parent: testCase } }
    Component { id: logComponent; SyncLogDialog { parent: testCase } }
    Component { id: neutralComponent; Item { width: 1; height: 1 } }
    Component { id: rowComponent; CompanionTaskRow { width: 360; companion: companionStub } }

    function initTestCase() {
        // 不让主题颜色过渡参与焦点判断，测试结束恢复全局单例。
        previousReduceMotion = Theme.reduceMotion
        Theme.reduceMotion = true
    }
    function cleanupTestCase() {
        Theme.reduceMotion = previousReduceMotion
    }
    function cleanup() {
        if (currentRoot && typeof currentRoot.close === "function") {
            currentRoot.close()
            tryCompare(currentRoot, "opened", false, 3000)
        }
        currentRoot = null
    }

    // 产品保证：所有已定位的自绘焦点环只对键盘导航显示，鼠标焦点和普通焦点恢复不产生额外描边。
    function test_focusRingFollowsInputReason_data() {
        return [
            { tag: "stepper-minus", kind: "stepper", target: "auditMinus", normal: 1 },
            { tag: "stepper-plus", kind: "stepper", target: "auditPlus", normal: 1 },
            { tag: "data-sync", kind: "data", target: "settingsSyncConfirmJoin", normal: 1 },
            { tag: "data-manage", kind: "data", target: "settingsManageRoutine", normal: 0 },
            { tag: "complete-cancel", kind: "complete", target: "completeCancelButton", normal: 1 },
            { tag: "complete-confirm", kind: "complete", target: "completeConfirmButton", normal: 0 },
            { tag: "long-continue", kind: "long", target: "longFreeFocusContinueButton", normal: 1 },
            { tag: "long-discard", kind: "long", target: "longFreeFocusDiscardButton", normal: 1 },
            { tag: "long-record", kind: "long", target: "longFreeFocusRecordButton", normal: 0 },
            { tag: "natural", kind: "natural", target: "naturalCompletionNoticeAcknowledgeButton", normal: 1 },
            { tag: "log", kind: "log", target: "syncLogCloseButton", normal: 1 }
        ]
    }

    // 产品保证：同一控件的鼠标、键盘和恢复焦点必须得到各自的环状态，不能靠永远关闭描边通过。
    function test_focusRingFollowsInputReason(data) {
        var components = {
            stepper: stepperComponent, data: dataComponent, complete: completeComponent,
            long: longComponent, natural: naturalComponent, log: logComponent
        }
        currentRoot = createTemporaryObject(components[data.kind], testCase)
        verify(currentRoot !== null)
        if (data.kind === "complete") {
            verify(currentRoot.openForTask({ id: 42, title: "隔离任务", completionNote: "" }))
        } else if (data.kind === "long") {
            currentRoot.prepare(36000, 8)
            currentRoot.open()
        } else if (data.kind === "natural" || data.kind === "log") {
            currentRoot.open()
        }
        if (typeof currentRoot.open === "function")
            tryCompare(currentRoot, "opened", true, 3000)
        var control = findChild(currentRoot, data.target)
        verify(control !== null, "生产控件必须实际创建：" + data.target)
        verify(control.enabled)
        verify(control.width > 0 && control.height > 0)
        // 每次先离开目标，确保 Qt 重新投递焦点原因；不点击提交按钮，避免测试修改表单数据。
        var neutral = createTemporaryObject(neutralComponent, control.parent)
        verify(neutral !== null)
        neutral.forceActiveFocus(Qt.OtherFocusReason)
        control.forceActiveFocus(Qt.MouseFocusReason)
        tryCompare(control, "activeFocus", true, 3000)
        compare(control.visualFocus, false)
        compare(control.background.border.width, data.normal)

        neutral.forceActiveFocus(Qt.OtherFocusReason)
        control.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(control, "visualFocus", true, 3000)
        compare(control.background.border.width, 2)

        neutral.forceActiveFocus(Qt.OtherFocusReason)
        control.forceActiveFocus(Qt.OtherFocusReason)
        tryCompare(control, "activeFocus", true, 3000)
        compare(control.visualFocus, false)
        compare(control.background.border.width, data.normal)
    }

    // 产品保证：读屏完成状态跟随真实任务更新，不能一直将已完成任务报告为未勾选。
    function test_companionCheckedStateFollowsTask() {
        var row = createTemporaryObject(rowComponent, testCase, {
            task: { id: 7, title: "完成状态投影", completed: true }
        })
        verify(row !== null)
        var check = findChild(row, "companionTaskCheck")
        verify(check !== null)
        compare(row.completed, true)
        compare(check.Accessible.checked, true)
        row.task = { id: 7, title: "完成状态投影", completed: false }
        compare(row.completed, false)
        compare(check.Accessible.checked, false)
        row.task = { id: 7, title: "完成状态投影", completed: true }
        compare(check.Accessible.checked, true)
    }
}
