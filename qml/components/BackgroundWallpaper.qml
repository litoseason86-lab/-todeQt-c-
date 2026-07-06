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

        function paintMotif(ctx, motif) {
            lastPaintedMotif = ""
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
                return
            }
            lastPaintedMotif = motif
            motifPaintCount += 1
        }

        function paintWindowLight(ctx) {
        }

        function paintSunsetPeaks(ctx) {
        }

        function paintOrchid(ctx) {
        }

        function paintMoonMist(ctx) {
        }

        function paintFallingPetals(ctx) {
        }

        function paintGoldenWaves(ctx) {
        }
    }

}
