import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property var dataPoints: []
    property var weekData: []
    property string title: ""
    property string valueSuffix: ""
    property string emptyText: "暂无数据"

    readonly property var chartData: normalizeData(sourceData())
    readonly property real maxValue: calculateMaxValue()
    readonly property bool showEmptyState: chartData.length === 0

    implicitWidth: 560
    implicitHeight: 260
    radius: Theme.radiusMd
    color: Theme.glassCard
    border.color: Theme.glassBorder
    border.width: 1

    function sourceData() {
        // dataPoints 是新接口，weekData 保留给旧调用方。
        if (root.dataPoints && root.dataPoints.length > 0) {
            return root.dataPoints
        }
        return root.weekData || []
    }

    function finiteNumber(value) {
        // 图表高度不能接受“不是有效数字”的值或负数，否则柱体会消失或反向。
        var numberValue = Number(value || 0)
        return isFinite(numberValue) ? Math.max(0, numberValue) : 0
    }

    function normalizeData(items) {
        var result = []
        if (!items) {
            return result
        }

        for (var i = 0; i < items.length; i++) {
            var item = items[i] || {}
            var value = item.value !== undefined ? item.value : item.duration
            var label = item.label || item.name || root.labelFromDate(item.date, i)
            result.push({
                label: String(label || ""),
                value: root.finiteNumber(value),
                displayValue: item.displayValue || "",
                subtitle: item.subtitle || "",
                color: item.color || Theme.accent
            })
        }
        return result
    }

    function labelFromDate(dateValue, indexValue) {
        var fallback = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        if (!dateValue) {
            return fallback[indexValue % fallback.length]
        }

        var parsed = dateValue instanceof Date ? dateValue : new Date(dateValue)
        if (isNaN(parsed.getTime())) {
            return fallback[indexValue % fallback.length]
        }

        var weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return weekdays[parsed.getDay()]
    }

    function calculateMaxValue() {
        var max = 0
        for (var i = 0; i < root.chartData.length; i++) {
            max = Math.max(max, root.finiteNumber(root.chartData[i].value))
        }
        return max
    }

    function normalizedValue(value) {
        // 所有柱体都按当前最大值换算到 0 到 1，避免小数据被固定量级压扁。
        var max = root.finiteNumber(root.maxValue)
        if (max <= 0) {
            return 0
        }
        return Math.min(1, root.finiteNumber(value) / max)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space12
        spacing: Theme.space12

        Text {
            Layout.fillWidth: true
            visible: root.title.length > 0
            text: root.title
            font.pixelSize: Theme.fontLg
            font.bold: true
            color: Theme.ink
            elide: Text.ElideRight
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 148

            RowLayout {
                id: bars

                anchors.fill: parent
                anchors.topMargin: Theme.space8
                anchors.bottomMargin: 30
                spacing: 10
                visible: !root.showEmptyState

                Repeater {
                    model: root.chartData

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: Theme.space4

                            Text {
                                Layout.fillWidth: true
                                text: modelData.displayValue.length > 0
                                      ? modelData.displayValue
                                      : (modelData.value + root.valueSuffix)
                                font.pixelSize: Theme.fontXs
                                color: Theme.inkSoft
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.leftMargin: Theme.space8
                                    anchors.rightMargin: Theme.space8
                                    height: parent.height * root.normalizedValue(modelData.value)
                                    radius: Theme.radiusSm
                                    color: modelData.color
                                    border.color: Theme.accentStrong
                                    border.width: height > 0 ? 1 : 0
                                    visible: height > 0
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 1
                                    color: Theme.border
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: modelData.label
                                font.pixelSize: Theme.fontSm
                                color: Theme.ink
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }

            Text {
                id: emptyStateLabel
                objectName: "emptyStateLabel"

                anchors.centerIn: parent
                width: Math.min(parent.width - 24, 260)
                visible: root.showEmptyState
                text: root.emptyText
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
