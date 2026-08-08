pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../.."

// 快捷键清单里的一行。不复用 SettingsRow：那个组件为「标题 + 说明 + 图标」设计，
// 而这里一屏要放下 18 个动作，多数行连说明都没有。行高压到 40，说明文字只在
// 非正常态（未设置 / 已停用 / 系统未接受）时才出现。
Item {
    id: root

    property string title: ""
    property string statusText: ""
    property string sequenceDisplay: ""
    property bool unregistered: false
    property bool hasDefault: true
    property bool isDefault: true
    property var normalizer: null

    property alias recording: recorder.recording

    signal captured(string portableSequence)
    signal recordingCancelled()
    signal resetRequested()

    Layout.fillWidth: true
    implicitHeight: Math.max(40, rowLayout.implicitHeight + Theme.space4 * 2)

    RowLayout {
        id: rowLayout

        anchors.fill: parent
        anchors.topMargin: Theme.space4
        anchors.bottomMargin: Theme.space4
        spacing: Theme.space12

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 1

            Text {
                Layout.fillWidth: true
                text: root.title
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                elide: Text.ElideRight
            }

            // 只有非正常态才占第二行；正常的行保持单行高度。
            Text {
                Layout.fillWidth: true
                visible: root.statusText.length > 0
                text: root.statusText
                color: root.unregistered ? Theme.danger : Theme.inkSoft
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
            }
        }

        ShortcutRecorder {
            id: recorder

            objectName: "shortcutRecorder"
            Layout.preferredWidth: 104
            Layout.preferredHeight: 30
            Layout.alignment: Qt.AlignVCenter
            sequenceDisplay: root.sequenceDisplay
            unregistered: root.unregistered
            hasDefault: root.hasDefault
            accessibleTitle: root.title
            normalizer: root.normalizer
            onCaptured: function (portableSequence) { root.captured(portableSequence) }
            onRecordingCancelled: root.recordingCancelled()
        }

        // 恢复默认用 opacity 而不是 visible 让位：18 行里多数是默认键位，
        // 用 visible 会让这一列的行宽此起彼伏地跳动。
        Button {
            id: resetButton

            objectName: "shortcutReset"
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            enabled: !root.isDefault
            opacity: enabled ? 1 : 0
            activeFocusOnTab: enabled
            Accessible.name: "恢复「" + root.title + "」默认键位"
            Accessible.ignored: !enabled
            onClicked: root.resetRequested()

            background: Rectangle {
                radius: Theme.radiusSm + 2
                color: resetButton.hovered ? Theme.surfaceSunken : "transparent"
                border.color: resetButton.activeFocus ? Theme.focusRing : "transparent"
                border.width: resetButton.activeFocus ? 2 : 0
            }

            contentItem: Text {
                // 回转箭头比「默认」二字省一半宽度，18 行累积起来差别很明显。
                text: "↺"
                color: Theme.inkSoft
                font.pixelSize: Theme.fontLg
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
