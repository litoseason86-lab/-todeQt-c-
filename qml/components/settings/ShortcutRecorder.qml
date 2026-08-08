pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import "../.."

// 单个快捷键的录制按钮。静息态显示当前键位（⌘⇧F 这种原生写法），
// 点击后进入录制态并把下一次按键翻译成键位交给上层保存。
//
// 录制态期间宿主会整体停用应用内快捷键（见 SettingsDialog.recordingShortcut），
// 否则想把 ⌘1 改绑到别处时，那次按键会先被「切到仪表盘」吃掉。
Button {
    id: root

    // 当前键位的显示文本；空串表示该动作已停用。
    // 不能叫 display：AbstractButton 已有一个 FINAL 的同名属性（图标/文字显示方式）。
    property string sequenceDisplay: ""
    // 该组合是否已保存但系统没接受（只可能出现在全局热键上）。
    property bool unregistered: false
    // 该动作有没有出厂键位。没有的（全局热键）空态说「未设置」，
    // 有出厂键位却被清空的说「已停用」——两者对用户是不同的意思。
    property bool hasDefault: true
    property bool recording: false
    // 把 key + modifiers 翻成 PortableText 的翻译器，由页面注入（走 C++ 的 normalize）。
    property var normalizer: null
    property string accessibleTitle: ""

    // 录到一组合法按键；空串表示用户按了删除键要求停用。
    signal captured(string portableSequence)
    signal recordingCancelled()

    implicitWidth: 104
    implicitHeight: 30
    activeFocusOnTab: true
    Accessible.name: root.accessibleTitle + "，当前快捷键 "
                     + (root.sequenceDisplay.length > 0
                        ? root.sequenceDisplay
                        : (root.hasDefault ? "已停用" : "未设置"))
    Accessible.description: "按回车开始录制新的快捷键"

    function startRecording() {
        root.recording = true
        root.forceActiveFocus()
    }

    function stopRecording() {
        root.recording = false
    }

    onClicked: root.recording ? root.stopRecording() : root.startRecording()

    // 失焦即退出录制：否则用户点去别处后，这个按钮还在暗中等着吃按键。
    onActiveFocusChanged: {
        if (!activeFocus && root.recording) {
            root.stopRecording()
            root.recordingCancelled()
        }
    }

    Keys.onPressed: function (event) {
        if (!root.recording) {
            return
        }
        event.accepted = true

        // Escape 取消，退格/删除表示「停用这个动作」——两者都不该被当成键位录进去。
        if (event.key === Qt.Key_Escape) {
            root.stopRecording()
            root.recordingCancelled()
            return
        }
        if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
            root.stopRecording()
            root.captured("")
            return
        }

        var portable = root.normalizer ? root.normalizer(event.key, event.modifiers) : ""
        // 只按住修饰键时 normalize 返回空串：继续等真正的主键，不退出录制态。
        if (String(portable).length === 0) {
            return
        }

        root.stopRecording()
        root.captured(String(portable))
    }

    background: Rectangle {
        radius: Theme.radiusMd
        color: root.recording
               ? Theme.accentSoft
               : (root.hovered ? Theme.surfaceSunken : Theme.surfaceRaised)
        // 录制态用强调色描边、未生效用危险色，静息态才是普通边框：
        // 三种状态不能只靠底色区分，否则深色壁纸下几乎看不出差别。
        border.color: root.recording
                      ? Theme.accent
                      : (root.unregistered ? Theme.danger
                                           : (root.activeFocus ? Theme.focusRing : Theme.border))
        border.width: (root.recording || root.activeFocus || root.unregistered) ? 2 : 1

        Behavior on color {
            ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
        }
    }

    contentItem: Text {
        objectName: "shortcutRecorderLabel"
        text: root.recording
              ? "按下新组合键…"
              : (root.sequenceDisplay.length > 0
                 ? root.sequenceDisplay
                 : (root.hasDefault ? "已停用" : "未设置"))
        color: root.recording ? Theme.accentInk
                              : (root.sequenceDisplay.length > 0 ? Theme.ink : Theme.inkSoft)
        font.pixelSize: Theme.fontMd
        // 键位符号（⌘⌃⌥⇧）在中文字体里字形参差，中等字重看起来最齐。
        font.weight: root.sequenceDisplay.length > 0 ? Font.Medium : Font.Normal
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
