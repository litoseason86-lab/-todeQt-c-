import QtQuick
import QtQuick.Layouts
import ".."

// 今日专注总时长 + 每日目标进度卡（仪表盘专注面板内）。
// 纯展示组件：秒数与目标由外部注入；点「目标 N 小时」就地展开步进器调整，
// 通过 goalAdjusted 信号回写，组件自身不碰设置存储。
GlassPanel {
    id: root

    property int totalSeconds: 0
    property int goalHours: 3
    // 就地编辑态：点目标行切换，不弹对话框。
    property bool editing: false
    // qmllint disable unqualified
    property bool reduceMotionActive: typeof appSettings !== "undefined" && appSettings && appSettings.reduceMotion
    // qmllint enable unqualified

    signal goalAdjusted(int hours)

    readonly property int goalSeconds: Math.max(1, root.goalHours) * 3600
    readonly property int percent: Math.min(100,
        Math.floor(Math.max(0, root.totalSeconds) * 100 / root.goalSeconds))
    readonly property bool goalReached: root.percent >= 100

    readonly property string hoursText: root.twoDigits(Math.floor(root.safeSeconds / 3600))
    readonly property string minutesText: root.twoDigits(Math.floor((root.safeSeconds % 3600) / 60))
    readonly property string secondsText: root.twoDigits(root.safeSeconds % 60)
    readonly property string clockText: root.hoursText + ":" + root.minutesText + ":" + root.secondsText
    readonly property int safeSeconds: Math.max(0, Number(root.totalSeconds || 0))

    function twoDigits(value) {
        return (value < 10 ? "0" : "") + value
    }

    implicitHeight: contentColumn.implicitHeight + Theme.space24
    // 嵌在专注面板玻璃上，关落影防止阴影堆叠发灰。
    panelShadowEnabled: false

    ColumnLayout {
        id: contentColumn

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.space12
        anchors.rightMargin: Theme.space12
        spacing: Theme.space4

        Text {
            text: "今日专注总时长"
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
        }

        RowLayout {
            spacing: 2

            // 冒号弱化为暖色淡阶，与专注页表盘同语言；数字用计时字族。
            Repeater {
                model: [
                    { value: root.hoursText, colon: false },
                    { value: ":", colon: true },
                    { value: root.minutesText, colon: false },
                    { value: ":", colon: true },
                    { value: root.secondsText, colon: false }
                ]

                Text {
                    id: clockSegment

                    required property var modelData

                    text: clockSegment.modelData.value
                    textFormat: Text.PlainText
                    font.pixelSize: 28
                    font.family: Theme.fontFamilyClock
                    font.weight: Font.Medium
                    color: clockSegment.modelData.colon ? Theme.focusColonMuted : Theme.inkStrong
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Text {
                id: goalLabel
                objectName: "focusGoalLabel"

                text: "目标 " + root.goalHours + " 小时 ›"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: goalArea.containsMouse || root.editing ? Theme.accentInk : Theme.inkSoft

                MouseArea {
                    id: goalArea

                    anchors.fill: parent
                    anchors.margins: -Theme.space4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.editing = !root.editing
                }
            }

            Item {
                Layout.fillWidth: true
            }

            Text {
                objectName: "focusGoalPercent"

                text: root.goalReached ? "目标达成" : root.percent + "%"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamilyData
                font.weight: Font.Bold
                color: root.goalReached ? Theme.focusBreakAccent : Theme.accentInk
            }
        }

        DurationStepper {
            objectName: "focusGoalStepper"

            Layout.topMargin: Theme.space4
            visible: root.editing
            from: 1
            to: 12
            value: root.goalHours
            namePrefix: "focusGoal"

            onAdjusted: function (newValue) {
                root.goalAdjusted(newValue)
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space4
            implicitHeight: 6
            radius: 3
            color: Theme.surfaceSunken
            border.color: Theme.borderSubtle
            border.width: 1

            Rectangle {
                id: goalFill
                objectName: "focusGoalFill"

                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * root.percent / 100
                radius: 3
                // 达成后整体切苔绿（休息强调色），给安静的完成感。
                gradient: root.goalReached ? null : fillGradient
                color: root.goalReached ? Theme.focusBreakAccent : "transparent"

                Gradient {
                    id: fillGradient

                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Theme.accent }
                    GradientStop { position: 1.0; color: Theme.accentStrong }
                }

                Behavior on width {
                    enabled: !root.reduceMotionActive
                    NumberAnimation {
                        duration: 300
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }
}
