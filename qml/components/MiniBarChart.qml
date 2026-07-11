pragma ComponentBehavior: Bound

import QtQuick
import ".."

// 迷你柱状图：纯 Rectangle 组合，无 Canvas；用于统计卡底部的近 N 天分布。
Item {
    id: root

    property var values: []
    property color barColor: Theme.accent

    readonly property real maxValue: {
        var peak = 1
        for (var i = 0; i < root.values.length; i++) {
            peak = Math.max(peak, Number(root.values[i]) || 0)
        }
        return peak
    }

    Row {
        anchors.fill: parent
        spacing: 3

        Repeater {
            model: root.values

            Item {
                id: barSlot

                required property var modelData
                required property int index

                width: (root.width - (root.values.length - 1) * 3) / Math.max(1, root.values.length)
                height: root.height

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    // 全 0 也保留 3px 短柱，空数据的日子在图上仍有落点。
                    height: Math.max(3, (Number(barSlot.modelData) || 0) / root.maxValue * parent.height)
                    radius: 2
                    color: root.barColor
                    // 最后一根是“今天”，实色高亮；历史柱子退为半透明。
                    opacity: barSlot.index === root.values.length - 1 ? 1.0 : 0.45
                }
            }
        }
    }
}
