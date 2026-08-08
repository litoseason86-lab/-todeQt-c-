import QtQuick
import QtTest
import "../../qml/components"
import "../../qml/components/settings"
import "../../qml"

// 快捷键在 QML 侧的三块：动作清单 → Shortcut 生成、动作 id → 具体行为的分发、
// 设置页录制器的按键处理。真正的键位规则（默认值、冲突、全局注册）由 C++ 的
// ShortcutRegistryTests 覆盖，这里用假注册表只验证界面这一层的接线。
TestCase {
    id: testCase
    name: "Shortcuts"
    when: windowShown

    // 假注册表：给出一份固定的动作清单，并记录 assign/disable/reset 的调用。
    // 结构与 C++ ShortcutRegistry 暴露给 QML 的完全一致。
    QtObject {
        id: registryMock

        property string lastAssignedId: ""
        property string lastAssignedSequence: ""
        property string lastDisabledId: ""
        property string lastResetId: ""
        property int resetAllCount: 0
        // assign 的返回值：空串=成功，非空=给用户看的中文失败原因。
        property string assignResult: ""

        readonly property var actions: [
            {
                id: "view.dashboard", title: "仪表盘", group: "导航",
                sequence: "Ctrl+1", display: "⌘1",
                defaultSequence: "Ctrl+1", defaultDisplay: "⌘1",
                isDefault: true, isGlobal: false, isDisabled: false, registered: true,
                hasDefault: true, hasModifier: true
            },
            {
                id: "task.new", title: "新建任务", group: "任务",
                sequence: "Ctrl+Shift+N", display: "⌘⇧N",
                defaultSequence: "Ctrl+N", defaultDisplay: "⌘N",
                isDefault: false, isGlobal: false, isDisabled: false, registered: true,
                hasDefault: true, hasModifier: true
            },
            {
                // 单键绑定：应用内允许，但在输入框里打字时必须让路。
                id: "focus.toggle", title: "开始 / 暂停专注", group: "专注",
                sequence: "Space", display: "Space",
                defaultSequence: "Ctrl+Return", defaultDisplay: "⌘↩",
                isDefault: false, isGlobal: false, isDisabled: false, registered: true,
                hasDefault: true, hasModifier: false
            },
            {
                id: "global.focusToggle", title: "开始 / 暂停专注（全局）", group: "全局",
                sequence: "Meta+Alt+P", display: "⌃⌥P",
                defaultSequence: "", defaultDisplay: "",
                isDefault: false, isGlobal: true, isDisabled: false, registered: false,
                hasDefault: false, hasModifier: true
            }
        ]
        readonly property var inAppActions: [actions[0], actions[1], actions[2]]
        readonly property var globalActions: [actions[3]]
        readonly property var groups: ["导航", "任务", "专注", "全局"]

        signal globalActionTriggered(string actionId)
        signal globalRegistrationFailed(string actionId, string title)

        function assign(actionId, sequence) {
            lastAssignedId = actionId
            lastAssignedSequence = sequence
            return assignResult
        }
        function disable(actionId) {
            lastDisabledId = actionId
            return ""
        }
        function resetToDefault(actionId) { lastResetId = actionId }
        function resetAll() { resetAllCount += 1 }
        // 只实现测试用得到的最小规则：带修饰键才算数，与 C++ 侧语义一致。
        function normalize(key, modifiers) {
            if (key === Qt.Key_Control || key === Qt.Key_Shift || key === Qt.Key_Alt
                    || key === Qt.Key_Meta) {
                return ""
            }
            if ((modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier)) === 0) {
                return ""
            }
            return "Ctrl+K"
        }
    }

    AppShortcuts {
        id: shortcuts
        registryRef: registryMock
    }

    SettingsShortcutsPage {
        id: shortcutsPage
        width: 560
        shortcutRegistryRef: registryMock
    }

    ShortcutRecorder {
        id: recorder
        sequenceDisplay: "⌘1"
        normalizer: function (key, modifiers) { return registryMock.normalize(key, modifiers) }
    }

    SignalSpy {
        id: triggerSpy
        target: shortcuts
        signalName: "actionTriggered"
    }

    SignalSpy {
        id: capturedSpy
        target: recorder
        signalName: "captured"
    }

    SignalSpy {
        id: cancelledSpy
        target: recorder
        signalName: "recordingCancelled"
    }

    function init() {
        triggerSpy.clear()
        capturedSpy.clear()
        cancelledSpy.clear()
        registryMock.assignResult = ""
        registryMock.lastAssignedId = ""
        registryMock.lastAssignedSequence = ""
        registryMock.lastDisabledId = ""
        registryMock.lastResetId = ""
        registryMock.resetAllCount = 0
        recorder.recording = false
        shortcuts.suspended = false
        shortcuts.textInputFocused = false
        shortcutsPage.feedbackText = ""
    }

    function findChildByObjectName(item, name) {
        if (!item) {
            return null
        }
        if (item.objectName === name) {
            return item
        }
        // 必须遍历 data 而不是 children：Instantiator、Connections 这类非可视对象
        // 不在 children 里，只用 children 会漏掉这次要断言的 Instantiator。
        // 两者都可能不存在（纯 QObject 节点），一律退回空数组。
        var slots = item.data
        if (slots === undefined || slots === null) {
            slots = item.children
        }
        if (slots === undefined || slots === null) {
            return null
        }
        for (var i = 0; i < slots.length; ++i) {
            var found = findChildByObjectName(slots[i], name)
            if (found) {
                return found
            }
        }
        return null
    }

    function test_only_in_app_actions_become_shortcuts() {
        var instantiator = findChildByObjectName(shortcuts, "inAppShortcutInstantiator")
        verify(instantiator !== null)
        // 全局动作绝不能再生成一个应用内 Shortcut：应用在前台时同一次按键
        // 会被系统热键和 Qt 各触发一次，动作就执行了两遍。
        compare(instantiator.count, registryMock.inAppActions.length)
        compare(instantiator.count, 3)
        compare(instantiator.objectAt(0).sequence, "Ctrl+1")
        compare(instantiator.objectAt(1).sequence, "Ctrl+Shift+N")
        compare(instantiator.objectAt(2).sequence, "Space")
    }

    function test_bare_key_shortcuts_stand_down_while_typing() {
        var instantiator = findChildByObjectName(shortcuts, "inAppShortcutInstantiator")
        // 基线：都可用。
        compare(instantiator.objectAt(0).enabled, true)
        compare(instantiator.objectAt(2).enabled, true)

        // 焦点进了输入框：单键必须让路，否则绑了空格就再也打不出空格。
        shortcuts.textInputFocused = true
        compare(instantiator.objectAt(2).enabled, false)
        // 带修饰键的组合不受影响——macOS 上在输入框里按 ⌘1 切页是正常行为。
        compare(instantiator.objectAt(0).enabled, true)
        compare(instantiator.objectAt(1).enabled, true)

        shortcuts.textInputFocused = false
        compare(instantiator.objectAt(2).enabled, true)
    }

    function test_suspending_disables_every_in_app_shortcut() {
        var instantiator = findChildByObjectName(shortcuts, "inAppShortcutInstantiator")
        compare(instantiator.objectAt(0).enabled, true)

        // 录制新键位时必须整体让路，否则想改绑 ⌘1 时那次按键会先被导航吃掉。
        shortcuts.suspended = true
        compare(instantiator.objectAt(0).enabled, false)
        compare(instantiator.objectAt(1).enabled, false)

        shortcuts.suspended = false
        compare(instantiator.objectAt(0).enabled, true)
    }

    function test_global_hotkey_signal_reaches_the_same_outlet() {
        // 全局热键与应用内快捷键最终必须汇成同一条出口，宿主只认动作 id。
        registryMock.globalActionTriggered("global.focusToggle")
        compare(triggerSpy.count, 1)
        compare(triggerSpy.signalArguments[0][0], "global.focusToggle")
    }

    function test_recorder_ignores_bare_modifier_and_keeps_recording() {
        recorder.startRecording()
        compare(recorder.recording, true)

        // 只按住 ⌘ 时不能立刻「录到」一个无法触发的组合，要继续等主键。
        keyPress(Qt.Key_Control, Qt.ControlModifier)
        keyRelease(Qt.Key_Control, Qt.ControlModifier)
        compare(capturedSpy.count, 0)
        compare(recorder.recording, true)

        keyPress(Qt.Key_K, Qt.ControlModifier)
        keyRelease(Qt.Key_K, Qt.ControlModifier)
        compare(capturedSpy.count, 1)
        compare(capturedSpy.signalArguments[0][0], "Ctrl+K")
        compare(recorder.recording, false)
    }

    function test_recorder_escape_cancels_and_delete_disables() {
        recorder.startRecording()
        keyPress(Qt.Key_Escape)
        keyRelease(Qt.Key_Escape)
        compare(cancelledSpy.count, 1)
        compare(capturedSpy.count, 0)
        compare(recorder.recording, false)

        // 删除键的含义是「停用这个动作」，要以空串上报，而不是当成一次失败录制。
        recorder.startRecording()
        keyPress(Qt.Key_Delete)
        keyRelease(Qt.Key_Delete)
        compare(capturedSpy.count, 1)
        compare(capturedSpy.signalArguments[0][0], "")
    }

    function test_page_saves_captured_sequence_and_reports_failure() {
        // 行本身就是测试面：ShortcutRow 把录制器与恢复按钮封在里面，
        // 用例不再依赖内部控件的 objectName。
        var row = findChildByObjectName(shortcutsPage, "shortcutRow_task.new")
        verify(row !== null)

        row.captured("Ctrl+Shift+K")
        compare(registryMock.lastAssignedId, "task.new")
        compare(registryMock.lastAssignedSequence, "Ctrl+Shift+K")
        compare(shortcutsPage.feedbackIsError, false)

        // 失败原因必须原样呈现给用户，不能被吞成一句泛泛的「保存失败」。
        registryMock.assignResult = "这组键已分配给「仪表盘」"
        row.captured("Ctrl+1")
        compare(shortcutsPage.feedbackIsError, true)
        compare(shortcutsPage.feedbackText, "这组键已分配给「仪表盘」")
    }

    function test_page_disable_and_reset_paths() {
        var row = findChildByObjectName(shortcutsPage, "shortcutRow_task.new")
        row.captured("")
        compare(registryMock.lastDisabledId, "task.new")
        compare(registryMock.lastAssignedId, "")

        // 已是默认键位的行不该给出恢复入口；task.new 在假清单里被改过，应该给。
        compare(row.isDefault, false)
        row.resetRequested()
        compare(registryMock.lastResetId, "task.new")

        var defaultRow = findChildByObjectName(shortcutsPage, "shortcutRow_view.dashboard")
        compare(defaultRow.isDefault, true)

        var resetAll = findChildByObjectName(shortcutsPage, "shortcutResetAll")
        resetAll.clicked()
        compare(registryMock.resetAllCount, 1)
    }

    function test_page_marks_hotkey_the_system_refused() {
        var row = findChildByObjectName(shortcutsPage, "shortcutRow_global.focusToggle")
        verify(row !== null)
        // 「已保存但系统没接受」必须在行上说清楚，否则用户只会觉得改键没反应。
        verify(row.statusText.indexOf("系统未接受") >= 0)
        compare(row.unregistered, true)

        // 正常的行不占第二行高度——18 个动作里多数是正常的，每行都预留说明位会白占一屏。
        var normalRow = findChildByObjectName(shortcutsPage, "shortcutRow_view.dashboard")
        compare(normalRow.statusText, "")

        registryMock.globalRegistrationFailed("global.focusToggle", "开始 / 暂停专注（全局）")
        compare(shortcutsPage.feedbackIsError, true)
        verify(shortcutsPage.feedbackText.indexOf("其他应用") >= 0)
    }

    function test_page_recording_state_bubbles_up() {
        var row = findChildByObjectName(shortcutsPage, "shortcutRow_task.new")
        compare(shortcutsPage.recording, false)

        row.recording = true
        compare(shortcutsPage.recording, true)

        row.recording = false
        compare(shortcutsPage.recording, false)
    }
}
