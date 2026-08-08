pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../.."

// 快捷键设置页：按分组列出全部动作，每行一个录制按钮 + 恢复默认。
// 页面自己不定义任何键位，全部读写 C++ 的 ShortcutRegistry——默认值、冲突判定、
// 全局热键注册都在那一层，界面只负责呈现和把用户按键交回去。
FocusScope {
    id: root

    objectName: "settingsShortcutsPage"
    property var appSettingsRef: null
    property var shortcutRegistryRef: null
    property bool compact: false
    // 有任何一行正在等待按键。上抬给对话框，用于整体停用应用内快捷键。
    property bool recording: false
    // 最近一次改键的反馈（冲突、非法组合、系统拒绝）。成功时也给一句确认。
    property string feedbackText: ""
    property bool feedbackIsError: false

    readonly property var actionList: root.shortcutRegistryRef
                                      ? root.shortcutRegistryRef.actions : []
    readonly property var groupList: root.shortcutRegistryRef
                                     ? root.shortcutRegistryRef.groups : []

    implicitHeight: contentColumn.implicitHeight

    function actionsInGroup(groupName) {
        var result = []
        for (var i = 0; i < root.actionList.length; ++i) {
            if (String(root.actionList[i].group) === String(groupName)) {
                result.push(root.actionList[i])
            }
        }
        return result
    }

    // 一行的状态说明。正常行返回空串，这样它保持单行高度——18 个动作里多数是正常的，
    // 让每行都预留说明位会白白多占一屏。
    function statusTextFor(action) {
        if (!action.isDisabled) {
            return action.registered ? "" : "系统未接受这组键，可能已被其他应用占用"
        }
        // 「从没设过」和「用户主动关掉」对用户是两件事：前者是全局热键的初始态。
        return action.hasDefault ? "已停用" : "未设置"
    }

    function applySequence(actionId, portableSequence) {
        if (!root.shortcutRegistryRef) {
            return
        }

        // 空串来自录制器的删除键：那是「停用这个动作」，不是一次失败的录制。
        var message = String(portableSequence).length === 0
                ? root.shortcutRegistryRef.disable(actionId)
                : root.shortcutRegistryRef.assign(actionId, portableSequence)

        root.feedbackIsError = String(message).length > 0
        root.feedbackText = root.feedbackIsError ? String(message) : "快捷键已保存"
    }

    function resetAction(actionId) {
        if (!root.shortcutRegistryRef) {
            return
        }
        root.shortcutRegistryRef.resetToDefault(actionId)
        root.feedbackIsError = false
        root.feedbackText = "已恢复默认键位"
    }

    Connections {
        // 系统拒绝注册是异步于「保存成功」的另一件事：键位存下了，但那组键没生效。
        target: root.shortcutRegistryRef
        ignoreUnknownSignals: true

        function onGlobalRegistrationFailed(actionId, title) {
            root.feedbackIsError = true
            root.feedbackText = "「" + String(title) + "」已保存，但系统未接受这组键，可能已被其他应用占用"
        }
    }

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space16

        // 操作说明放在最前：第一次进来需要先知道怎么改键，
        // 而不是滚过 18 行之后才在最底下看到用法。
        Text {
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.space4
            text: "点键位后按下新组合即可改键。可以只用一个键（如空格），"
                  + "在输入框里打字时它们会自动让路；按 Delete 停用，按 Esc 取消录制。"
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: root.groupList

            delegate: SettingsSection {
                id: groupSection

                required property var modelData

                title: String(groupSection.modelData)
                description: String(groupSection.modelData) === "全局"
                             ? "在番茄Todo处于后台时也能触发，会从整个系统抢走这组键。"
                               + "出厂不占用任何按键，至少需要两个修饰键（如 ⌃⌥P）。"
                             : ""

                Repeater {
                    model: root.actionsInGroup(groupSection.modelData)

                    delegate: ShortcutRow {
                        id: actionRow

                        required property var modelData

                        objectName: "shortcutRow_" + String(actionRow.modelData.id)
                        title: String(actionRow.modelData.title)
                        statusText: root.statusTextFor(actionRow.modelData)
                        sequenceDisplay: String(actionRow.modelData.display)
                        unregistered: !actionRow.modelData.registered
                        hasDefault: Boolean(actionRow.modelData.hasDefault)
                        isDefault: Boolean(actionRow.modelData.isDefault)
                        // 翻译交给 C++：QML 侧再抄一份键位规范化必然与后端漂移。
                        normalizer: function (key, modifiers) {
                            return root.shortcutRegistryRef
                                    ? root.shortcutRegistryRef.normalize(key, modifiers)
                                    : ""
                        }
                        onRecordingChanged: root.recording = recording
                        onCaptured: function (portableSequence) {
                            root.applySequence(String(actionRow.modelData.id), portableSequence)
                        }
                        onRecordingCancelled: root.feedbackText = ""
                        onResetRequested: root.resetAction(String(actionRow.modelData.id))
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space4
            spacing: Theme.space12

            Text {
                objectName: "shortcutFeedbackText"
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: root.feedbackText
                color: root.feedbackIsError ? Theme.danger : Theme.inkSoft
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
                Accessible.role: root.feedbackIsError
                                 ? Accessible.AlertMessage : Accessible.StaticText
                Accessible.name: text
                Accessible.ignored: text.length === 0
            }

            Button {
                id: resetAllButton

                objectName: "shortcutResetAll"
                Layout.preferredWidth: 104
                Layout.preferredHeight: 32
                Layout.alignment: Qt.AlignVCenter
                activeFocusOnTab: true
                Accessible.name: "全部恢复默认快捷键"
                onClicked: {
                    if (!root.shortcutRegistryRef) {
                        return
                    }
                    root.shortcutRegistryRef.resetAll()
                    root.feedbackIsError = false
                    root.feedbackText = "已全部恢复默认键位"
                }

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: resetAllButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: resetAllButton.activeFocus ? Theme.focusRing : Theme.border
                    border.width: resetAllButton.activeFocus ? 2 : 1
                }

                contentItem: Text {
                    text: "全部恢复默认"
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
