import QtQuick
import ".."

// 背景壁纸层：底色 + 光晕 + 主题图案。
// 主题定义默认来自 Theme.backgroundThemes；测试可注入 themeSource，避免修改全局单例。
Item {
    id: root

    property string themeId: "warmPaper"
    property var themeSource: Theme.backgroundThemes
    property alias paintCount: canvas.paintCount
    readonly property alias lastPaintedMotif: canvas.lastPaintedMotif
    readonly property alias motifPaintCount: canvas.motifPaintCount
    readonly property var supportedMotifs: [
        "windowLight",
        "sunsetPeaks",
        "orchid",
        "moonMist",
        "fallingPetals",
        "goldenWaves"
    ]

    readonly property var resolvedTheme: {
        var themes = root.themeSource
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === root.themeId) {
                return themes[i]
            }
        }
        return themes[0]
    }

    onThemeIdChanged: canvas.requestPaint()
    onThemeSourceChanged: canvas.requestPaint()

    function forceRepaintForTest() {
        canvas.requestPaint()
    }

    Canvas {
        id: canvas

        property int paintCount: 0
        property int motifPaintCount: 0
        property string lastPaintedMotif: ""

        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            if (width <= 0 || height <= 0) {
                return
            }

            var ctx = getContext("2d")
            var theme = root.resolvedTheme

            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = theme.base || Theme.backgroundThemes[0].base
            ctx.fillRect(0, 0, width, height)

            var blobs = theme.blobs || []
            for (var i = 0; i < blobs.length; i++) {
                var blob = blobs[i]
                // createRadialGradient 只支持正圆；缩放坐标系后画单位圆即可得到椭圆光晕。
                ctx.save()
                ctx.translate(blob.cx * width, blob.cy * height)
                ctx.scale(blob.rx * width, blob.ry * height)
                var center = Qt.color(blob.color)
                var gradient = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
                gradient.addColorStop(0, blob.color)
                // 淡出到同色 alpha 0，避免透明黑/白参与插值时出现脏边。
                gradient.addColorStop(1, Qt.rgba(center.r, center.g, center.b, 0))
                ctx.fillStyle = gradient
                ctx.beginPath()
                ctx.arc(0, 0, 1, 0, Math.PI * 2)
                ctx.fill()
                ctx.restore()
            }

            paintMotif(ctx, theme.motif || "")
            paintCount += 1
        }

        // —— 绘制原语（比例坐标系内，供各 motif 复用）——
        function radialGlow(ctx, cx, cy, r, color, alpha) {
            // 从中心色淡出到全透明的软光；缩放坐标系里非等比会自然拉成椭圆。
            ctx.save()
            ctx.translate(cx, cy)
            ctx.scale(r, r)
            var c = Qt.color(color)
            var g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
            g.addColorStop(0, Qt.rgba(c.r, c.g, c.b, alpha))
            g.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0))
            ctx.fillStyle = g
            ctx.beginPath()
            ctx.arc(0, 0, 1, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
        }

        function solidCircle(ctx, cx, cy, r, color, alpha) {
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
        }

        function fillCurveBand(ctx, pts, color, alpha) {
            // pts 是一条起伏顶边的二次贝塞尔控制点，向下闭合到底边形成山/浪的整片色块。
            var points = pts || []
            if (points.length < 2) {
                return
            }
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.moveTo(points[0], points[1])
            for (var i = 2; i + 3 < points.length; i += 4) {
                ctx.quadraticCurveTo(points[i], points[i + 1], points[i + 2], points[i + 3])
            }
            ctx.lineTo(100, 62)
            ctx.lineTo(0, 62)
            ctx.closePath()
            ctx.fill()
            ctx.restore()
        }

        function fillEllipse(ctx, cx, cy, rx, ry, color, alpha) {
            ctx.save()
            ctx.translate(cx, cy)
            ctx.scale(rx, ry)
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.arc(0, 0, 1, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
        }

        function fillPolygon(ctx, pts, color, alpha) {
            // pts 是闭合多边形点列；点数不足时直接跳过，避免测试注入坏数据拖垮整张壁纸。
            var points = pts || []
            if (points.length < 4) {
                return
            }
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.moveTo(points[0], points[1])
            for (var i = 2; i + 1 < points.length; i += 2) {
                ctx.lineTo(points[i], points[i + 1])
            }
            ctx.closePath()
            ctx.fill()
            ctx.restore()
        }

        function strokeArc(ctx, cx, cy, r, color, lineWidth, alpha) {
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.strokeStyle = color
            ctx.lineWidth = lineWidth
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2)
            ctx.stroke()
            ctx.restore()
        }

        function strokeQuad(ctx, x0, y0, cx, cy, x1, y1, color, lineWidth, alpha) {
            // 一笔兰叶：二次贝塞尔描边，圆头收尾，模拟轻笔触而不是硬折线。
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.strokeStyle = color
            ctx.lineWidth = lineWidth
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.moveTo(x0, y0)
            ctx.quadraticCurveTo(cx, cy, x1, y1)
            ctx.stroke()
            ctx.restore()
        }

        function fillPetal(ctx, tx, ty, rotDeg, s, color, alpha) {
            // 花瓣用泪滴双弧闭合；旋转和缩放由调用处控制，保证同一基形能产生飘落差异。
            ctx.save()
            ctx.translate(tx, ty)
            ctx.rotate(rotDeg * Math.PI / 180)
            ctx.scale(s, s)
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.moveTo(0, -3)
            ctx.bezierCurveTo(1.8, -1.4, 1.8, 1.6, 0, 3)
            ctx.bezierCurveTo(-1.8, 1.6, -1.8, -1.4, 0, -3)
            ctx.closePath()
            ctx.fill()
            ctx.restore()
        }

        function paintMotif(ctx, motif) {
            lastPaintedMotif = ""
            ctx.save()
            ctx.scale(width / 100, height / 62)
            switch (motif) {
            case "windowLight":
                paintWindowLight(ctx)
                break
            case "sunsetPeaks":
                paintSunsetPeaks(ctx)
                break
            case "orchid":
                paintOrchid(ctx)
                break
            case "moonMist":
                paintMoonMist(ctx)
                break
            case "fallingPetals":
                paintFallingPetals(ctx)
                break
            case "goldenWaves":
                paintGoldenWaves(ctx)
                break
            default:
                // 未知图案保留底色和光晕；不计入 motifPaintCount，便于测试发现错误映射。
                ctx.restore()
                return
            }
            ctx.restore()
            lastPaintedMotif = motif
            motifPaintCount += 1
        }

        function paintWindowLight(ctx) {
            radialGlow(ctx, 22, 14, 17, "#ffffff", 0.55)
            radialGlow(ctx, 80, 50, 21, "#ffffff", 0.32)
            // 斜射入窗的柔光带。
            fillPolygon(ctx, [0, 32, 100, 6, 100, 15, 0, 42], "#ffffff", 0.10)
            // 圆心放在画布外下方，只露出右下角的极淡弧线。
            strokeArc(ctx, 93, 66, 18, "#dfc7a4", 0.5, 0.22)
            strokeArc(ctx, 93, 66, 25, "#dfc7a4", 0.5, 0.14)
        }

        function paintSunsetPeaks(ctx) {
            // 落日外晕和三层远山都在 100×62 坐标系中绘制，窗口缩放时保持构图比例。
            ctx.save()
            ctx.translate(70, 19)
            ctx.scale(15, 15)
            var sun = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
            sun.addColorStop(0, Qt.rgba(1, 0.965, 0.894, 0.7))
            sun.addColorStop(0.7, Qt.rgba(1, 0.886, 0.722, 0.35))
            sun.addColorStop(1, Qt.rgba(1, 0.886, 0.722, 0))
            ctx.fillStyle = sun
            ctx.beginPath()
            ctx.arc(0, 0, 1, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
            solidCircle(ctx, 70, 19, 8, "#fff3dd", 0.9)
            fillCurveBand(ctx, [0, 44, 18, 35, 34, 41, 50, 47, 66, 39, 84, 32, 100, 42], "#e8a17b", 0.24)
            fillCurveBand(ctx, [0, 50, 22, 41, 44, 47, 66, 53, 84, 46, 93, 43, 100, 46], "#d98a68", 0.28)
            fillCurveBand(ctx, [0, 56, 30, 49, 55, 53, 78, 57, 100, 52], "#c67857", 0.30)
        }

        function paintOrchid(ctx) {
            radialGlow(ctx, 78, 12, 15, "#ffffff", 0.4)
            // 左下角五笔兰叶由粗到细，透明度逐步降低，避免在任务文字后面形成强干扰。
            strokeQuad(ctx, 6, 62, 10, 42, 26, 30, "#6fa791", 1.1, 0.38)
            strokeQuad(ctx, 8, 62, 16, 48, 34, 42, "#6fa791", 1.0, 0.30)
            strokeQuad(ctx, 5, 62, 6, 44, 12, 34, "#6fa791", 0.9, 0.26)
            strokeQuad(ctx, 9, 62, 18, 54, 30, 52, "#6fa791", 0.8, 0.20)
            strokeQuad(ctx, 7, 62, 12, 50, 16, 40, "#6fa791", 0.7, 0.16)
            solidCircle(ctx, 27.5, 29, 1.1, "#8fbfae", 0.45)
            solidCircle(ctx, 30, 32, 0.8, "#8fbfae", 0.32)
        }

        function paintMoonMist(ctx) {
            radialGlow(ctx, 27, 13, 11, "#ffffff", 0.5)
            solidCircle(ctx, 27, 13, 5.5, "#ffffff", 0.7)
            // 三条横向雾带渐次下沉，底部远丘只保留低透明度轮廓。
            fillEllipse(ctx, 52, 33, 62, 4.5, "#ffffff", 0.22)
            fillEllipse(ctx, 28, 43, 52, 4, "#e9e9f8", 0.28)
            fillEllipse(ctx, 72, 52, 58, 5, "#dfe4f4", 0.30)
            fillCurveBand(ctx, [0, 50, 28, 44, 54, 48, 78, 52, 100, 46], "#b7bdd8", 0.16)
        }

        function paintFallingPetals(ctx) {
            radialGlow(ctx, 16, 12, 16, "#ffd9e4", 0.55)
            // 九片花瓣右上到左下飘落，近大远小、近实远虚。
            fillPetal(ctx, 62, 10, 24, 1.4, "#f29db5", 0.50)
            fillPetal(ctx, 74, 18, -38, 1.0, "#eeb0c4", 0.42)
            fillPetal(ctx, 86, 9, 64, 0.8, "#f29db5", 0.35)
            fillPetal(ctx, 90, 30, -15, 1.2, "#eeb0c4", 0.40)
            fillPetal(ctx, 80, 44, 40, 0.9, "#f2a5ba", 0.32)
            fillPetal(ctx, 68, 55, -58, 1.1, "#eeb0c4", 0.28)
            fillPetal(ctx, 38, 52, 18, 0.8, "#f2a5ba", 0.24)
            fillPetal(ctx, 50, 22, -30, 0.7, "#f5bccb", 0.30)
            fillPetal(ctx, 24, 34, 52, 0.9, "#f5bccb", 0.20)
        }

        function paintGoldenWaves(ctx) {
            radialGlow(ctx, 81, 11, 17, "#fff8dd", 0.55)
            // 三层起伏麦浪由浅入深铺满下沿，靠 alpha 控制存在感，避免压过前景文字。
            fillCurveBand(ctx, [0, 45, 15, 41, 30, 44, 45, 47, 60, 43, 80, 38, 100, 45], "#eccf8e", 0.32)
            fillCurveBand(ctx, [0, 52, 20, 47, 40, 50, 60, 53, 80, 49, 90, 47, 100, 50], "#e0bd72", 0.38)
            fillCurveBand(ctx, [0, 58, 25, 54, 50, 56, 75, 58, 100, 55], "#d4ad5e", 0.42)
        }
    }

}
