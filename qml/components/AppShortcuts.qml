pragma ComponentBehavior: Bound

import QtQuick

// 快捷键的 QML 出口：把 ShortcutRegistry 的动作清单变成一组真正的 Shortcut，
// 并把全局热键的信号并进同一条出口。宿主只需要认「动作 id」，不关心这个键是
// 应用内的还是系统级的，也不需要在新增动作时改这里——清单由 C++ 侧统一维护。
Item {
    id: root

    // C++ 的 ShortcutRegistry。为空时整棵树静默失效，独立组件测试可以不注入它。
    property var registryRef: null
    // 录制新键位时必须整体停用：否则用户按下 ⌘1 会先被「切到仪表盘」吃掉，
    // 录制框永远等不到那次按键。
    property bool suspended: false
    // 焦点是否落在文本输入框上。应用内快捷键允许绑单个按键（空格、数字键这类），
    // 而单键会和正常打字直接冲突——绑了「N」就再也打不出这个字母。所以输入时
    // 只让无修饰键的那些让路；带 ⌘/⌃/⌥ 的组合照常可用（macOS 上在输入框里按 ⌘1 切页是正常行为）。
    property bool textInputFocused: false

    signal actionTriggered(string actionId)

    // 纯逻辑节点，不参与布局也不占位。
    visible: false
    width: 0
    height: 0

    Instantiator {
        id: inAppShortcuts
        objectName: "inAppShortcutInstantiator"

        // 只取应用内动作。全局动作绝不能在这里再生成一个 Shortcut：那样应用在前台时
        // 同一次按键会被系统热键和 Qt 各触发一次，动作执行两遍。
        model: root.registryRef ? root.registryRef.inAppActions : []

        delegate: Shortcut {
            required property var modelData

            sequence: String(modelData.sequence)
            // 空序列 = 用户主动停用了这个动作。
            // hasModifier 由 C++ 侧算好，这里不再自己解析键位字符串。
            enabled: !root.suspended
                     && String(modelData.sequence).length > 0
                     && (Boolean(modelData.hasModifier) || !root.textInputFocused)
            // 应用级上下文：这些 Shortcut 由 Instantiator 创建，不在可视项树上，
            // 用 WindowShortcut 会因为找不到宿主窗口而不生效。
            context: Qt.ApplicationShortcut
            onActivated: root.actionTriggered(String(modelData.id))
        }
    }

    Connections {
        target: root.registryRef
        ignoreUnknownSignals: true

        function onGlobalActionTriggered(actionId) {
            root.actionTriggered(String(actionId))
        }
    }
}
