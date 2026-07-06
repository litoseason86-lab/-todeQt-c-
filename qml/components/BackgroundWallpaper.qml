import QtQuick
import ".."

// 背景壁纸层：底色 + 三个椭圆径向光晕 + 噪点颗粒。
// 主题定义唯一来源是 Theme.backgroundThemes；未知 id 在这里回落首位暖纸。
Item {
    id: root

    property string themeId: "warmPaper"
    property alias paintCount: canvas.paintCount

    readonly property var resolvedTheme: {
        var themes = Theme.backgroundThemes
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === root.themeId) {
                return themes[i]
            }
        }
        return themes[0]
    }

    onThemeIdChanged: canvas.requestPaint()

    Canvas {
        id: canvas

        property int paintCount: 0

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
            ctx.fillStyle = theme.base
            ctx.fillRect(0, 0, width, height)

            for (var i = 0; i < theme.blobs.length; i++) {
                var blob = theme.blobs[i]
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

            paintCount += 1
        }
    }

    Image {
        // 纸感噪点随壁纸整层走；计划二会移除 MainWindow 里的旧噪点层，避免双重颗粒。
        anchors.fill: parent
        opacity: 0.03
        fillMode: Image.Tile
        source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='noise'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23noise)'/></svg>"
    }
}
