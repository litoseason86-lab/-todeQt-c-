pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../Duration.js" as Duration
import ".."

// 今日专注目标 · 贴底状态条（今日任务页专用，横排三态：未设置/编辑/展示）。
// 与 FocusGoalCard（竖排，仪表盘只读）共享同一套逻辑接口与校验规则；
// 右端并入「任务完成 x / y」，顶部统计行由本条整体替代。
GlassPanel {
    id: root

    property int totalSeconds: 0
    property int goalMinutes: 0
    property bool editing: false
    property bool reduceMotion: false
    property string saveError: ""
    // 与卡片同接口：本条只在今日任务页使用，恒为可编辑。
    property bool editable: true
    // 快捷沿用的数据源（昨天的目标分钟数）；无效时回落推荐 4 小时。
    property int quickFillMinutes: 0
    property int completedTasks: 0
    property int totalTasks: 0
    // 今天所有任务「预计用时」之和。任务侧早就有这个数、目标也是分钟，
    // 但此前没有任何地方把两者对上——用户排完任务不知道自己是排多了还是排少了。
    property int plannedMinutes: 0

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

    readonly property bool hasPlan: root.plannedMinutes > 0
    // 正数=排的活超过目标，负数=还有余量。没设目标时不做判断。
    readonly property int plannedDeltaMinutes: root.hasGoal ? root.plannedMinutes - root.goalMinutes : 0

    readonly property bool quickFillFromYesterday: root.quickFillMinutes >= 1 && root.quickFillMinutes <= 1440
    readonly property int quickFillValue: root.quickFillFromYesterday ? root.quickFillMinutes : 240
    readonly property string quickFillLabel: root.quickFillFromYesterday
        ? qsTr("沿用昨天 · %1").arg(root.formatTarget(root.quickFillMinutes))
        : qsTr("推荐 · 4:00")

    implicitHeight: Math.max(56, stripContent.implicitHeight + Theme.space16)

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

    // 「今日已排」：任务预计用时之和，以及它与目标的差额。与 DoneCount 同款版式，
    // 未设目标时只报总量、不给判断——那时没有可比的基准。
    component PlannedLoad: RowLayout {
        spacing: Theme.space8
        visible: root.hasPlan

        Rectangle {
            Layout.preferredWidth: 1
            Layout.preferredHeight: 24
            color: Theme.border
            opacity: 0.8
        }

        Label {
            text: qsTr("已排")
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
        }

        Label {
            objectName: "stripPlannedMinutes"
            text: Duration.format(root.plannedMinutes)
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontLg
            font.family: Theme.fontFamilyData
            font.weight: Font.Bold
        }

        Label {
            objectName: "stripPlannedDelta"
            // 没设目标时给空串而不是靠 visible 藏起来：这个项目的离屏环境里
            // visible 的级联判定不可靠，用文案本身表达"没有可说的"更稳。
            textFormat: Text.PlainText
            text: {
                if (!root.hasGoal)
                    return ""
                if (root.plannedDeltaMinutes > 0)
                    return qsTr("超出 %1").arg(Duration.format(root.plannedDeltaMinutes))
                if (root.plannedDeltaMinutes < 0)
                    return qsTr("还可排 %1").arg(Duration.format(-root.plannedDeltaMinutes))
                return qsTr("刚好")
            }
            visible: text.length > 0
            // 超出不是错误，只是信息：用次要色，不用告警色。
            color: Theme.inkSoft
            font.pixelSize: Theme.fontXs
        }
    }

    // 右端「任务完成」计数：未设置/展示两态共用。
    component DoneCount: RowLayout {
        spacing: Theme.space8

        Rectangle {
            Layout.preferredWidth: 1
            Layout.preferredHeight: 24
            color: Theme.border
            opacity: 0.8
        }

        Label {
            text: qsTr("任务完成")
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
        }

        Label {
            objectName: "stripDoneCount"
            text: root.completedTasks + " / " + root.totalTasks
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontLg
            font.family: Theme.fontFamilyData
            font.weight: Font.Bold
        }
    }

    Item {
        id: stripContent

        anchors.fill: parent
        anchors.leftMargin: Theme.space16
        anchors.rightMargin: Theme.space16
        implicitHeight: Math.max(unsetRow.implicitHeight, editRow.implicitHeight, displayRow.implicitHeight)

        // —— 未设置 ——
        RowLayout {
            id: unsetRow

            anchors.fill: parent
            visible: !root.editing && !root.hasGoal
            spacing: Theme.space12

            Label {
                text: qsTr("今日专注目标")
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }

            Label {
                objectName: "focusGoalUnsetLabel"
                text: qsTr("尚未设置")
                color: Theme.inkStrong
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
            }

            Label {
                visible: root.saveError.length > 0
                text: root.saveError
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontXs
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Item {
                visible: root.saveError.length === 0
                Layout.fillWidth: true
            }

            Button {
                id: quickFillChip
                objectName: "focusGoalQuickChip"

                text: root.quickFillLabel
                activeFocusOnTab: true
                implicitHeight: 26
                onClicked: root.goalSubmitted(root.quickFillValue)

                background: Rectangle {
                    radius: 13
                    color: quickFillChip.pressed ? Theme.glassAccent
                           : (quickFillChip.hovered ? Theme.glassHover : Theme.glassAccent)
                    border.color: quickFillChip.hovered || quickFillChip.visualFocus
                                  ? Theme.accent : Theme.glassBorder
                    border.width: 1
                }

                contentItem: Text {
                    text: quickFillChip.text
                    textFormat: Text.PlainText
                    leftPadding: Theme.space8
                    rightPadding: Theme.space8
                    color: Theme.accentInk
                    font.pixelSize: Theme.fontXs
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: setGoalButton
                objectName: "focusGoalSetButton"

                text: qsTr("设置今日目标")
                activeFocusOnTab: true
                implicitHeight: 30
                onClicked: root.beginEditing()

                background: GlassPanel {
                    color: setGoalButton.pressed ? Theme.glassAccent
                                                 : (setGoalButton.hovered ? Theme.glassHover : Theme.glassCard)
                    panelShadowEnabled: false
                }

                contentItem: Text {
                    text: setGoalButton.text
                    textFormat: Text.PlainText
                    leftPadding: Theme.space12
                    rightPadding: Theme.space12
                    color: Theme.accentInk
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            PlannedLoad {}

            DoneCount {}
        }

        // —— 编辑（横排内联，复用同一编辑器与校验） ——
        RowLayout {
            id: editRow

            anchors.fill: parent
            visible: root.editing
            spacing: Theme.space12

            Label {
                text: qsTr("设置今日目标")
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
        }

        // —— 展示 ——
        RowLayout {
            id: displayRow

            anchors.fill: parent
            visible: !root.editing && root.hasGoal
            spacing: Theme.space12

            Label {
                text: qsTr("今日专注")
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }

            RowLayout {
                spacing: 1

                Repeater {
                    model: [
                        { value: root.twoDigits(Math.floor(root.safeSeconds / 3600)), colon: false },
                        { value: ":", colon: true },
                        { value: root.twoDigits(Math.floor((root.safeSeconds % 3600) / 60)), colon: false },
                        { value: ":", colon: true },
                        { value: root.twoDigits(root.safeSeconds % 60), colon: false }
                    ]

                    Label {
                        id: clockSegment

                        required property var modelData

                        objectName: clockSegment.modelData.colon ? "" : "focusGoalClockSegment"
                        text: clockSegment.modelData.value
                        textFormat: Text.PlainText
                        font.pixelSize: 22
                        font.family: Theme.fontFamilyClock
                        font.weight: Font.Medium
                        color: clockSegment.modelData.colon ? Theme.focusColonMuted : Theme.inkStrong
                    }
                }
            }

            Button {
                id: modifyGoalButton
                objectName: "focusGoalModifyButton"

                text: qsTr("目标 %1 · 修改 ›").arg(root.targetText)
                activeFocusOnTab: true
                flat: true
                onClicked: root.beginEditing()

                contentItem: Text {
                    text: modifyGoalButton.text
                    textFormat: Text.PlainText
                    color: modifyGoalButton.hovered ? Theme.accentInk : Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: modifyGoalButton.hovered ? Theme.glassHover : Qt.rgba(1, 1, 1, 0)
                    border.width: modifyGoalButton.visualFocus ? 2 : 0
                    border.color: Theme.accent
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.minimumWidth: 120
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

                    Behavior on width {
                        enabled: !root.reduceMotion
                        NumberAnimation {
                            duration: Theme.reduceMotion ? 0 : 300
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }

            RowLayout {
                visible: root.goalReached
                spacing: Theme.space4

                Rectangle {
                    Layout.preferredWidth: 15
                    Layout.preferredHeight: 15
                    radius: 8
                    color: Theme.focusBreakAccent

                    Label {
                        anchors.centerIn: parent
                        text: "✓"
                        color: Theme.accentForeground
                        font.pixelSize: Theme.fontXs
                        Accessible.ignored: true
                    }
                }

                Label {
                    objectName: "focusGoalReachedLabel"
                    text: qsTr("目标达成")
                    color: Theme.focusBreakInk
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Bold
                }
            }

            Label {
                objectName: "focusGoalPercent"
                visible: !root.goalReached
                text: root.percent + "%"
                textFormat: Text.PlainText
                color: Theme.accentInk
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamilyData
                font.weight: Font.Bold
            }

            Label {
                visible: root.saveError.length > 0
                text: root.saveError
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontXs
                elide: Text.ElideRight
            }

            PlannedLoad {}

            DoneCount {}
        }
    }

    Component {
        id: editorComponent

        DailyFocusGoalEditor {
            horizontal: true
            initialMinutes: root.hasGoal ? root.goalMinutes : 0
            reduceMotion: root.reduceMotion

            onSubmitted: function (totalMinutes) {
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
