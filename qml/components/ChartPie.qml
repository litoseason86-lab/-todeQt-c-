pragma ComponentBehavior: Bound

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
    readonly property var chartColors: Theme.chartColors

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
                color: item.color || root.chartColors[i % root.chartColors.length]
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
            textFormat: Text.PlainText
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
                    // 饼图直径设上限，宽面板上也不至于撑得过大、与图例失衡。
                    readonly property real pieSize: Math.min(parent.width * 0.42, parent.height, 176)
                    Layout.preferredWidth: pieSize
                    Layout.preferredHeight: pieSize
                    Layout.alignment: Qt.AlignVCenter

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
                                // 不描白边：扇区之间靠颜色区分，避免玻璃卡上出现突兀的白色轮廓。
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
                    // 图例竖向居中,少量科目时不会挤在顶部留下大片空白。
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Theme.space12

                    Repeater {
                        model: root.chartData

                        RowLayout {
                            id: legendRow

                            required property var modelData

                            // 整条图例统一限宽,百分比对齐在占比条右端上方,不会飘到面板最右侧。
                            Layout.fillWidth: true
                            Layout.maximumWidth: 320
                            spacing: Theme.space8

                            Rectangle {
                                Layout.preferredWidth: 11
                                Layout.preferredHeight: 11
                                Layout.alignment: Qt.AlignTop
                                Layout.topMargin: 3
                                radius: 3
                                color: legendRow.modelData.color
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.hairline

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.space8

                                    Text {
                                        Layout.fillWidth: true
                                        text: legendRow.modelData.label
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontMd
                                        color: Theme.ink
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        text: root.percentage(legendRow.modelData.value)
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontSm
                                        color: Theme.inkSoft
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: legendRow.modelData.displayValue.length > 0
                                          ? legendRow.modelData.displayValue
                                          : String(legendRow.modelData.value)
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontXs
                                    color: Theme.inkSoft
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    // 占比条随文案块限宽,单一科目 100% 时不会拉成横贯整行的进度条。
                                    Layout.fillWidth: true
                                    Layout.topMargin: 2
                                    Layout.preferredHeight: 6
                                    radius: 3
                                    color: Theme.accentSoft

                                    Rectangle {
                                        width: parent.width * (root.totalValue > 0
                                                               ? legendRow.modelData.value / root.totalValue : 0)
                                        height: parent.height
                                        radius: 3
                                        color: legendRow.modelData.color
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
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
