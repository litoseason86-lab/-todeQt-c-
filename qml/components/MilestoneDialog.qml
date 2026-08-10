pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../Duration.js" as Duration
import ".."

// 奖励弹窗保持“素版”：层级只靠字号、留白和焦糖色，不用绿色、emoji 或图章制造廉价刺激。
Popup {
    id: root

    property int goalId: -1
    property string goalTitle: ""
    property int percent: 0
    property int doneCount: 0
    property int targetCount: 0
    property bool achieved: false
    property bool reduceMotion: Theme.reduceMotion

    signal viewGoalRequested()

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    width: Math.min(440, parent ? Math.max(320, parent.width - Theme.space32) : 440)
    height: dialogColumn.implicitHeight + Theme.space32 * 2
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: Theme.space32

    function dismiss() {
        root.close()
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.96
                to: 1
                duration: root.reduceMotion ? 0 : 180
                easing.type: Easing.OutCubic
            }
            OpacityAnimator {
                from: 0
                to: 1
                duration: root.reduceMotion ? 0 : 160
            }
        }
    }

    exit: Transition {
        OpacityAnimator {
            from: 1
            to: 0
            duration: root.reduceMotion ? 0 : 120
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim

        TapHandler {
            onTapped: root.dismiss()
        }
    }

    background: Rectangle {
        color: root.achieved ? Theme.accentFill
                             : (Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard)
        border.color: root.achieved ? Theme.accent : Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        id: dialogColumn

        spacing: Theme.space12

        Text {
            Layout.fillWidth: true
            text: root.achieved ? qsTr("目标达成") : qsTr("里程碑")
            color: root.achieved ? Theme.accentFillInk : Theme.inkSoft
            font.pixelSize: Theme.fontSm
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            objectName: "milestonePercentText"
            Layout.fillWidth: true
            text: root.percent + "%"
            color: root.achieved ? Theme.accentFillInk : Theme.inkStrong
            font.pixelSize: root.achieved ? 60 : 52
            font.family: Theme.fontFamilyData
            font.weight: Font.Bold
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            Layout.fillWidth: true
            text: root.goalTitle
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontXl
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }

        Text {
            objectName: "milestoneProgressText"
            Layout.fillWidth: true
            text: root.achieved
                  ? qsTr("累计投入 %1").arg(Duration.format(root.doneCount))
                  : qsTr("%1 / %2 番茄，还剩 %3 个")
                    .arg(root.doneCount).arg(root.targetCount)
                    .arg(Math.max(0, root.targetCount - root.doneCount))
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            horizontalAlignment: Text.AlignHCenter
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space8
            spacing: Theme.space8

            RewardButton {
                Layout.fillWidth: true
                text: qsTr("查看目标")
                implicitHeight: 44
                onClicked: root.viewGoalRequested()
            }

            RewardButton {
                Layout.fillWidth: true
                text: qsTr("继续")
                implicitHeight: 44
                accentAction: true
                onClicked: root.dismiss()
            }
        }
    }

    component RewardButton: Button {
        id: rewardButton

        property bool accentAction: false

        hoverEnabled: true
        background: Rectangle {
            color: rewardButton.accentAction
                   ? (rewardButton.down || rewardButton.hovered
                      ? Theme.accentFillStrong : Theme.accentFill)
                   : (rewardButton.down || rewardButton.hovered
                      ? Theme.glassHover : Theme.glassCard)
            border.color: rewardButton.accentAction ? Theme.accent : Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }
        contentItem: Text {
            text: rewardButton.text
            color: rewardButton.accentAction ? Theme.accentFillInk : Theme.ink
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
