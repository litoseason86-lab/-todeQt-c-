pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 列表卡只消费 GoalService 已聚合好的 map，不在组件内部查服务。
// 这样列表、网格和后续详情页共享同一份进度事实，避免刷新时出现不同口径。
AbstractButton {
    id: root

    property var goal: ({})
    readonly property int goalId: Number(root.goal.id || -1)
    readonly property int doneCount: Math.max(0, Number(root.goal.doneCount || 0))
    readonly property int targetCount: Math.max(0, Number(root.goal.targetPomodoros || 0))
    readonly property int percent: Math.max(0, Math.min(100, Number(root.goal.percent || 0)))
    readonly property bool achieved: Boolean(root.goal.achieved)
    readonly property int forecastDays: Number(root.goal.forecastDays === undefined ? -1
                                                                            : root.goal.forecastDays)
    readonly property string secondaryText: {
        if (root.achieved) {
            var achievedAt = root.goal.achievedAt
            var dateText = achievedAt ? Qt.formatDate(achievedAt, "M月d日") : ""
            return dateText.length > 0 ? qsTr("已达成 · %1").arg(dateText) : qsTr("已达成")
        }
        var progress = qsTr("%1 / %2 番茄").arg(root.doneCount).arg(root.targetCount)
        return root.forecastDays > 0
                ? progress + qsTr(" · 照此速度还需 %1 天").arg(root.forecastDays)
                : progress
    }

    implicitWidth: 560
    implicitHeight: 76
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

    contentItem: RowLayout {
        spacing: Theme.space12

        Item {
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48

            Canvas {
                id: ring

                anchors.centerIn: parent
                width: 44
                height: 44
                antialiasing: true

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.lineWidth = 4
                    ctx.lineCap = "round"
                    ctx.strokeStyle = Theme.borderSubtle
                    ctx.beginPath()
                    ctx.arc(22, 22, 18, 0, Math.PI * 2)
                    ctx.stroke()
                    if (root.percent > 0) {
                        ctx.strokeStyle = root.achieved ? Theme.accentInk : Theme.accent
                        ctx.beginPath()
                        ctx.arc(22, 22, 18, -Math.PI / 2,
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
                color: Theme.ink
                font.pixelSize: Theme.fontXs
                font.family: Theme.fontFamilyData
                font.weight: Font.Bold
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                Layout.fillWidth: true
                text: String(root.goal.title || qsTr("未命名目标"))
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: root.secondaryText
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
            }
        }

        Rectangle {
            Layout.preferredWidth: statusText.implicitWidth + Theme.space16
            Layout.preferredHeight: 28
            radius: height / 2
            color: root.achieved ? "transparent" : Theme.accentFill
            border.color: root.achieved ? Theme.accentInk : "transparent"
            border.width: root.achieved ? 1 : 0

            Text {
                id: statusText
                anchors.centerIn: parent
                text: root.achieved ? qsTr("已达成") : qsTr("进行中")
                color: Theme.accentFillInk
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
            }
        }
    }
}
