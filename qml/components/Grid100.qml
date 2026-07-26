pragma ComponentBehavior: Bound

import QtQuick
import ".."

// 任意目标都归一化为 100 格：格子表示百分之一，而不是一个固定番茄。
// 所以 25/300 会点满 8 格并填充第 9 格的三分之一，让小步进展也能被看见。
// 第 25/50/75/100 格在尚未完整点亮时保留描边，作为下一档奖励的前瞻提示。
Item {
    id: root

    property int doneCount: 0
    property int targetCount: 0
    property real gap: 4
    readonly property real filledCells: root.targetCount > 0
                                                ? Math.min(100, Math.max(0,
                                                    root.doneCount / root.targetCount * 100))
                                                : 0
    readonly property int fullCells: Math.floor(root.filledCells)
    readonly property real partialFill: root.filledCells - root.fullCells
    readonly property real gridWidth: Math.min(360, Math.max(0, root.width))
    readonly property real cellSize: Math.max(0, (root.gridWidth - root.gap * 9) / 10)

    implicitWidth: 360
    implicitHeight: root.cellSize * 10 + root.gap * 9

    Grid {
        anchors.horizontalCenter: parent.horizontalCenter
        columns: 10
        columnSpacing: root.gap
        rowSpacing: root.gap

        Repeater {
            model: 100

            Rectangle {
                id: cell

                required property int index
                readonly property bool milestoneCell: cell.index === 24 || cell.index === 49
                                                       || cell.index === 74 || cell.index === 99
                readonly property real fillRatio: cell.index < root.fullCells ? 1
                                                   : (cell.index === root.fullCells
                                                      ? root.partialFill : 0)

                objectName: "grid100Cell-" + cell.index
                width: root.cellSize
                height: root.cellSize
                radius: Math.min(3, width / 4)
                color: Theme.darkMode ? Theme.surfaceSunken : Theme.border
                border.color: Theme.accent
                border.width: cell.milestoneCell && cell.fillRatio < 1 ? 1 : 0
                clip: true

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * cell.fillRatio
                    color: Theme.accent
                    radius: parent.radius
                }
            }
        }
    }
}
