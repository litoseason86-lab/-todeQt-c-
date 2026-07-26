pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 网格瓦片与列表卡使用同一个 goal map，只缩短副文案，避免窄卡被预测文字撑坏。
AbstractButton {
    id: root

    property var goal: ({})
    readonly property int goalId: Number(root.goal.id || -1)
    readonly property int doneCount: Math.max(0, Number(root.goal.doneCount || 0))
    readonly property int targetCount: Math.max(0, Number(root.goal.targetPomodoros || 0))
    readonly property int percent: Math.max(0, Math.min(100, Number(root.goal.percent || 0)))
    readonly property bool achieved: Boolean(root.goal.achieved)
    readonly property string secondaryText: root.achieved
                                            ? qsTr("已达成")
                                            : qsTr("%1 / %2 番茄").arg(root.doneCount).arg(root.targetCount)

    implicitWidth: 160
    implicitHeight: 158
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.name: String(root.goal.title || qsTr("未命名目标")) + "，" + root.secondaryText

    background: Rectangle {
        color: root.down || root.hovered ? Theme.glassHover : Theme.glassCard
        border.color: root.activeFocus || root.hovered ? Theme.accent : Theme.glassBorder
        border.width: root.activeFocus ? 2 : 1
        radius: Theme.radiusLg

        Behavior on color {
            ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
        }
    }

    contentItem: ColumnLayout {
        spacing: Theme.space8

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 76
            Layout.preferredHeight: 76

            Canvas {
                id: ring

                anchors.centerIn: parent
                width: 72
                height: 72
                antialiasing: true

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.lineWidth = 6
                    ctx.lineCap = "round"
                    ctx.strokeStyle = Theme.borderSubtle
                    ctx.beginPath()
                    ctx.arc(36, 36, 30, 0, Math.PI * 2)
                    ctx.stroke()
                    if (root.percent > 0) {
                        ctx.strokeStyle = root.achieved ? Theme.accentInk : Theme.accent
                        ctx.beginPath()
                        ctx.arc(36, 36, 30, -Math.PI / 2,
                                -Math.PI / 2 + Math.PI * 2 * root.percent / 100)
                        ctx.stroke()
                    }
                }

                Connections {
                    target: Theme
                    function onDarkModeChanged() { ring.requestPaint() }
                }
                Connections {
                    target: root
                    function onPercentChanged() { ring.requestPaint() }
                    function onAchievedChanged() { ring.requestPaint() }
                }
            }

            Text {
                anchors.centerIn: parent
                text: root.percent + "%"
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.family: Theme.fontFamilyData
                font.weight: Font.Bold
            }
        }

        Text {
            Layout.fillWidth: true
            text: String(root.goal.title || qsTr("未命名目标"))
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontMd
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true
            text: root.secondaryText
            textFormat: Text.PlainText
            color: root.achieved ? Theme.accentInk : Theme.inkSoft
            font.pixelSize: Theme.fontSm
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }
}
