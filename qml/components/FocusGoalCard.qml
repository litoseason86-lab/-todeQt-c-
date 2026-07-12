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
    // 只有今日任务页实例可编辑；仪表盘实例只读，未设置时引导跳转。
    property bool editable: true
    // 快捷沿用的数据源（昨天的目标分钟数）；无效时回落推荐 4 小时。
    property int quickFillMinutes: 0

    signal goalSubmitted(int totalMinutes)
    signal setupRequested()

    readonly property bool quickFillFromYesterday: root.quickFillMinutes >= 1 && root.quickFillMinutes <= 1440
    readonly property int quickFillValue: root.quickFillFromYesterday ? root.quickFillMinutes : 240
    readonly property string quickFillLabel: root.quickFillFromYesterday
        ? qsTr("沿用昨天 · %1").arg(root.formatTarget(root.quickFillMinutes))
        : qsTr("推荐 · 4:00")

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
        // 只读实例（仪表盘）不进入编辑态，编辑一律回今日任务页。
        if (!root.editable) {
            return
        }
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
                text: root.editable ? qsTr("为今天定一个清晰、可完成的目标。")
                                    : qsTr("目标在「今日任务」页设置。")
                color: Theme.inkMuted
                font.pixelSize: Theme.fontXs
                wrapMode: Text.WordWrap
            }

            Button {
                id: setGoalButton
                objectName: "focusGoalSetButton"
                Layout.fillWidth: true
                Layout.topMargin: Theme.space4
                visible: root.editable
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

            Button {
                id: quickFillChip
                objectName: "focusGoalQuickChip"

                visible: root.editable
                Layout.topMargin: 2
                text: root.quickFillLabel
                activeFocusOnTab: true
                implicitHeight: 26
                // 快捷落库：保留"每天主动确认"的仪式，消掉重复输入。
                onClicked: root.goalSubmitted(root.quickFillValue)

                background: Rectangle {
                    radius: 13
                    color: quickFillChip.pressed ? Theme.glassAccent
                           : (quickFillChip.hovered ? Theme.glassHover : Theme.glassAccent)
                    border.color: quickFillChip.hovered ? Theme.accent : Theme.glassBorder
                    border.width: 1
                }

                contentItem: Text {
                    text: quickFillChip.text
                    leftPadding: Theme.space8
                    rightPadding: Theme.space8
                    color: Theme.accentInk
                    font.pixelSize: Theme.fontXs
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Label {
                objectName: "focusGoalGuideLink"

                visible: !root.editable
                Layout.topMargin: 2
                text: qsTr("去「今日任务」页设置 ›")
                color: guideArea.containsMouse ? Theme.accentInk : Theme.inkSoft
                font.pixelSize: Theme.fontSm

                MouseArea {
                    id: guideArea

                    anchors.fill: parent
                    anchors.margins: -Theme.space4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setupRequested()
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
                    visible: root.editable
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
