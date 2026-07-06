import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property var dataPoints: []
    property var categoryData: []
    property string title: ""
    property string emptyText: "暂无分布数据"

    readonly property var chartData: normalizeData(sourceData())
    readonly property real totalValue: calculateTotalValue()
    readonly property bool showEmptyState: chartData.length === 0
    readonly property bool showInvalidData: chartData.length > 0 && totalValue <= 0
    // 系列配色集中管理于 Theme.chartColors，值不变。
    readonly property var palette: Theme.chartColors

    implicitWidth: 560
    implicitHeight: 260
    radius: Theme.radiusMd
    color: Theme.glassCard
    border.color: Theme.glassBorder
    border.width: 1

    onChartDataChanged: pieCanvas.requestPaint()
    onTotalValueChanged: pieCanvas.requestPaint()

    function sourceData() {
        // dataPoints 是新接口，categoryData 保留给旧统计视图。
        if (root.dataPoints && root.dataPoints.length > 0) {
            return root.dataPoints
        }
        return root.categoryData || []
    }

    function finiteNumber(value) {
        // 画布绘制角度必须来自非负有效数字，避免弧线计算失效。
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
            var label = item.label || item.name || "未分类"
            result.push({
                label: String(label || "未分类"),
                value: root.finiteNumber(value),
                displayValue: item.displayValue || "",
                color: item.color || root.palette[i % root.palette.length]
            })
        }
        return result
    }

    function calculateTotalValue() {
        var total = 0
        for (var i = 0; i < root.chartData.length; i++) {
            total += root.finiteNumber(root.chartData[i].value)
        }
        return total
    }

    function segmentSweep(indexValue) {
        // 每个扇区用总量占比换算成角度。
        if (root.totalValue <= 0 || indexValue < 0 || indexValue >= root.chartData.length) {
            return 0
        }
        return root.chartData[indexValue].value * 360 / root.totalValue
    }

    function percentage(value) {
        if (root.totalValue <= 0) {
            return "0%"
        }
        return Math.round(root.finiteNumber(value) * 100 / root.totalValue) + "%"
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
            Layout.minimumHeight: 160

            RowLayout {
                anchors.fill: parent
                spacing: 16
                visible: !root.showEmptyState

                Item {
                    Layout.preferredWidth: Math.min(parent.width * 0.42, parent.height)
                    Layout.fillHeight: true

                    Canvas {
                        id: pieCanvas

                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height)
                        height: width
                        antialiasing: true
                        visible: !root.showInvalidData

                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()

                        onPaint: {
                            // 画布不会自动清掉上一帧，重绘前必须手动清空。
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            if (root.totalValue <= 0) {
                                return
                            }

                            var radius = Math.max(0, Math.min(width, height) / 2 - 3)
                            var centerX = width / 2
                            var centerY = height / 2
                            var start = -Math.PI / 2

                            for (var i = 0; i < root.chartData.length; i++) {
                                var sweep = root.segmentSweep(i) * Math.PI / 180
                                if (sweep <= 0) {
                                    continue
                                }

                                ctx.beginPath()
                                ctx.moveTo(centerX, centerY)
                                ctx.arc(centerX, centerY, radius, start, start + sweep, false)
                                ctx.closePath()
                                ctx.fillStyle = root.chartData[i].color
                                ctx.fill()
                                ctx.strokeStyle = Theme.surface
                                ctx.lineWidth = 2
                                ctx.stroke()
                                start += sweep
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height) * 0.46
                        height: width
                        radius: width / 2
                        color: Theme.surfaceRaised
                        border.color: Theme.border
                        border.width: root.showInvalidData ? 0 : 1
                        visible: !root.showInvalidData
                    }

                    Text {
                        id: invalidDataLabel
                        objectName: "invalidDataLabel"

                        anchors.centerIn: parent
                        width: Math.min(parent.width - 16, 150)
                        visible: root.showInvalidData
                        text: "暂无有效数据"
                        font.pixelSize: Theme.fontSm
                        color: Theme.inkSoft
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Theme.space8

                    Repeater {
                        model: root.chartData

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space8

                            Rectangle {
                                Layout.preferredWidth: 11
                                Layout.preferredHeight: 11
                                radius: Theme.hairline
                                color: modelData.color
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.hairline

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.space8

                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.label
                                        font.pixelSize: Theme.fontMd
                                        color: Theme.ink
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        text: root.percentage(modelData.value)
                                        font.pixelSize: Theme.fontSm
                                        color: Theme.inkSoft
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.displayValue.length > 0
                                          ? modelData.displayValue
                                          : String(modelData.value)
                                    font.pixelSize: Theme.fontXs
                                    color: Theme.inkSoft
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 5
                                    radius: Theme.hairline
                                    color: Theme.accentSoft

                                    Rectangle {
                                        width: parent.width * (root.totalValue > 0 ? modelData.value / root.totalValue : 0)
                                        height: parent.height
                                        radius: Theme.hairline
                                        color: modelData.color
                                    }
                                }
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
