import QtQuick
import ".."

// 迷你趋势图：近 N 天数据的平滑折线 + 渐变填充，用于统计卡底部。
// 静态绘制：只在数据/尺寸/颜色变化时重画一次，不做逐帧动画。
Canvas {
    id: chart

    property var values: []
    property color lineColor: Theme.accent

    antialiasing: true

    onValuesChanged: requestPaint()
    onLineColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)

        var data = chart.values || []
        if (width <= 0 || height <= 0 || data.length < 2) {
            return
        }

        var maxValue = 1
        for (var i = 0; i < data.length; i++) {
            maxValue = Math.max(maxValue, Number(data[i]) || 0)
        }

        // 上缘留 2px 呼吸空间；全 0 时贴底走平线，不至于图表消失。
        var stepX = width / (data.length - 1)
        var points = []
        for (var j = 0; j < data.length; j++) {
            var ratio = (Number(data[j]) || 0) / maxValue
            points.push({ x: j * stepX, y: height - 1.5 - ratio * (height - 4) })
        }

        function traceCurve() {
            // 相邻点取中点做二次贝塞尔，折线变成柔和曲线（审美基线：忌硬折角）。
            ctx.moveTo(points[0].x, points[0].y)
            for (var k = 1; k < points.length; k++) {
                var midX = (points[k - 1].x + points[k].x) / 2
                var midY = (points[k - 1].y + points[k].y) / 2
                ctx.quadraticCurveTo(points[k - 1].x, points[k - 1].y, midX, midY)
            }
            ctx.lineTo(points[points.length - 1].x, points[points.length - 1].y)
        }

        function withAlpha(colorValue, alpha) {
            return Qt.rgba(colorValue.r, colorValue.g, colorValue.b, alpha)
        }

        // 渐变填充：线下方淡出到透明，呼应壁纸的柔和氛围。
        var fill = ctx.createLinearGradient(0, 0, 0, height)
        fill.addColorStop(0, withAlpha(chart.lineColor, 0.30))
        fill.addColorStop(1, withAlpha(chart.lineColor, 0))
        ctx.beginPath()
        traceCurve()
        ctx.lineTo(points[points.length - 1].x, height)
        ctx.lineTo(points[0].x, height)
        ctx.closePath()
        ctx.fillStyle = fill
        ctx.fill()

        ctx.beginPath()
        traceCurve()
        ctx.lineWidth = 1.5
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.strokeStyle = chart.lineColor
        ctx.stroke()
    }
}
