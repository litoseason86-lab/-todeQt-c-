pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 今日目标卡只负责展示和编辑；逻辑日期与持久化由 DashboardView 协调。
GlassPanel {
    id: root

    property int totalSeconds: 0
    property int goalMinutes: 0
    property bool editing: false
    property bool reduceMotion: false
    property string saveError: ""

    signal goalSubmitted(int totalMinutes)

    readonly property bool hasGoal: root.goalMinutes >= 1 && root.goalMinutes <= 1440
    readonly property int safeSeconds: Math.max(0, Number(root.totalSeconds || 0))
    readonly property int goalSeconds: root.hasGoal ? root.goalMinutes * 60 : 0
    readonly property int percent: root.hasGoal
        ? Math.min(100, Math.floor(root.safeSeconds * 100 / root.goalSeconds))
        : 0
    readonly property bool goalReached: root.hasGoal && root.safeSeconds >= root.goalSeconds
    readonly property string clockText: root.formatClock(root.safeSeconds)
    readonly property string targetText: root.formatTarget(root.goalMinutes)

    implicitHeight: contentColumn.implicitHeight + Theme.space24
    panelShadowEnabled: false
    solidFallback: !Theme.glassBlurAllowed

    function twoDigits(value) {
        return (value < 10 ? "0" : "") + value
    }

    function formatClock(seconds) {
        var hours = Math.floor(seconds / 3600)
        var minutes = Math.floor((seconds % 3600) / 60)
        var secs = seconds % 60
        return root.twoDigits(hours) + ":" + root.twoDigits(minutes) + ":" + root.twoDigits(secs)
    }

    function formatTarget(minutes) {
        var safe = Math.max(0, Math.min(1440, Number(minutes || 0)))
        return root.twoDigits(Math.floor(safe / 60)) + ":" + root.twoDigits(safe % 60)
    }

    function beginEditing() {
        root.saveError = ""
        root.editing = true
    }

    function handleSaveResult(success) {
        if (success) {
            root.saveError = ""
            root.editing = false
        } else {
            root.saveError = qsTr("目标保存失败，请重试")
        }
    }

    ColumnLayout {
        id: contentColumn

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.space12
        anchors.rightMargin: Theme.space12
        spacing: Theme.space8

        Label {
            text: root.editing ? qsTr("设置今日专注目标")
                               : (root.hasGoal ? qsTr("今日专注总时长") : qsTr("今日专注目标"))
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
        }

        Loader {
            id: editorLoader
            objectName: "focusGoalEditorLoader"

            Layout.fillWidth: true
            active: root.editing
            sourceComponent: editorComponent
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: !root.editing && !root.hasGoal
            spacing: Theme.space4

            Label {
                objectName: "focusGoalUnsetLabel"
                text: qsTr("尚未设置")
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.weight: Font.Medium
            }

            Label {
                Layout.fillWidth: true
                text: qsTr("为今天定一个清晰、可完成的目标。")
                color: Theme.inkMuted
                font.pixelSize: Theme.fontXs
                wrapMode: Text.WordWrap
            }

            Button {
                id: setGoalButton
                objectName: "focusGoalSetButton"
                Layout.fillWidth: true
                Layout.topMargin: Theme.space4
                text: qsTr("设置今日目标")
                activeFocusOnTab: true
                implicitHeight: 34
                onClicked: root.beginEditing()

                background: GlassPanel {
                    color: setGoalButton.pressed ? Theme.glassAccent
                                                 : (setGoalButton.hovered ? Theme.glassHover : Theme.glassCard)
                    panelShadowEnabled: false
                }

                contentItem: Text {
                    text: setGoalButton.text
                    color: Theme.accentInk
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: !root.editing && root.hasGoal
            spacing: Theme.space8

            Label {
                objectName: "focusGoalClock"
                text: root.clockText
                color: Theme.inkStrong
                font.pixelSize: 28
                font.family: Theme.fontFamilyClock
                font.weight: Font.Medium
            }

            RowLayout {
                Layout.fillWidth: true

                Label {
                    objectName: "focusGoalTarget"
                    text: qsTr("目标 %1").arg(root.targetText)
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                Item { Layout.fillWidth: true }

                Button {
                    id: modifyGoalButton
                    objectName: "focusGoalModifyButton"
                    text: qsTr("修改目标")
                    activeFocusOnTab: true
                    flat: true
                    onClicked: root.beginEditing()

                    contentItem: Text {
                        text: modifyGoalButton.text
                        color: Theme.accentInk
                        font.pixelSize: Theme.fontSm
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true

                RowLayout {
                    visible: root.goalReached
                    spacing: Theme.space4

                    Rectangle {
                        Layout.preferredWidth: 16
                        Layout.preferredHeight: 16
                        radius: 8
                        color: Theme.focusBreakAccent

                        Label {
                            anchors.centerIn: parent
                            text: "✓"
                            color: Theme.surface
                            font.pixelSize: Theme.fontXs
                            Accessible.ignored: true
                        }
                    }

                    Label {
                        objectName: "focusGoalReachedLabel"
                        text: qsTr("目标达成")
                        color: Theme.focusBreakAccent
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Bold
                    }
                }

                Label {
                    visible: !root.goalReached
                    text: qsTr("已完成")
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                Item { Layout.fillWidth: true }

                Label {
                    objectName: "focusGoalPercent"
                    text: root.percent + "%"
                    color: root.goalReached ? Theme.focusBreakAccent : Theme.accentInk
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamilyData
                    font.weight: Font.Bold
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 6
                radius: 3
                color: Theme.surfaceSunken
                border.color: Theme.borderSubtle
                border.width: 1

                Rectangle {
                    objectName: "focusGoalFill"
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * root.percent / 100
                    radius: 3
                    color: root.goalReached ? Theme.focusBreakAccent : Theme.accent
                }
            }
        }

        Label {
            objectName: "focusGoalSaveError"
            Layout.fillWidth: true
            visible: root.saveError.length > 0
            text: root.saveError
            color: Theme.danger
            font.pixelSize: Theme.fontXs
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.AlertMessage
        }
    }

    Component {
        id: editorComponent

        DailyFocusGoalEditor {
            initialMinutes: root.hasGoal ? root.goalMinutes : 0
            reduceMotion: root.reduceMotion

            onSubmitted: function(totalMinutes) {
                root.saveError = ""
                root.goalSubmitted(totalMinutes)
            }
            onCancelled: {
                root.saveError = ""
                root.editing = false
            }
        }
    }
}
