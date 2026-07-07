import QtQuick
import ".."

// 环形进度盘：番茄模式下的可视化核心。只负责画“轨道 + 剩余弧”，
// 进度/颜色/暂停/预览态全部由外部属性驱动，自身不读取 root 状态——
// 保持可复用、可测试（测试直接断言这几个绑定属性，不做像素级检查）。
Canvas {
    id: ring

    property real progress: 1.0       // 剩余时间占比：1=刚开始/已合拢，0=时间耗尽
    property color ringColor: Theme.accent
    property bool showPreview: false  // 待机态：只画一圈虚线预览，不画进度弧
    property bool dimmed: false       // 暂停态：整体降低不透明度，转由灰色轨道提示
    readonly property real strokeWidth: 14

    opacity: dimmed ? 0.38 : 1
    antialiasing: true

    Behavior on opacity {
        NumberAnimation { duration: 150 }
    }

    onProgressChanged: requestPaint()
    onRingColorChanged: requestPaint()
    onShowPreviewChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0) {
            return
        }

        function withAlpha(colorValue, alpha) {
            return Qt.rgba(colorValue.r, colorValue.g, colorValue.b, alpha)
        }

        var centerX = width / 2
        var centerY = height / 2
        var radius = Math.max(0, Math.min(width, height) / 2 - ring.strokeWidth / 2 - 2)
        var discR = Math.max(0, radius - ring.strokeWidth / 2 - 6)
        ctx.lineCap = "round"

        // 玻璃内盘：落影只包在 save/restore 里，避免 Canvas 全局阴影污染轨道和进度弧。
        ctx.save()
        ctx.shadowColor = withAlpha(Theme.focusGlassShadow, 0.15)
        ctx.shadowBlur = 14
        ctx.shadowOffsetY = 7
        var disc = ctx.createRadialGradient(centerX, centerY - discR * 0.16, discR * 0.1,
                                            centerX, centerY, discR)
        disc.addColorStop(0, Theme.focusGlassCenter)
        disc.addColorStop(1, Theme.focusGlassEdge)
        ctx.beginPath()
        ctx.fillStyle = disc
        ctx.arc(centerX, centerY, discR, 0, Math.PI * 2, false)
        ctx.fill()
        ctx.restore()

        // 顶部高光：单独绘制，不参与状态语义，只负责玻璃受光质感。
        ctx.save()
        ctx.beginPath()
        ctx.ellipse(centerX - discR * 0.10, centerY - discR * 0.55,
                    discR * 0.82, discR * 0.28, 0, 0, Math.PI * 2, false)
        var highlight = ctx.createLinearGradient(0, centerY - discR * 0.78, 0, centerY - discR * 0.22)
        highlight.addColorStop(0, withAlpha(Theme.focusGlassHighlight, 0.85))
        highlight.addColorStop(1, withAlpha(Theme.focusGlassHighlight, 0))
        ctx.fillStyle = highlight
        ctx.fill()
        ctx.restore()

        if (ring.showPreview) {
            // 待机态沿用同一块玻璃盘，只把弧层降级为极淡轨道 + 顶部小段提示。
            ctx.beginPath()
            ctx.setLineDash([])
            ctx.lineWidth = ring.strokeWidth
            ctx.strokeStyle = Theme.borderSubtle
            ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
            ctx.stroke()

            // 顶部约 15° 的强调弧：暗示正式计时会从正上方开始消退。
            ctx.beginPath()
            ctx.globalAlpha = 0.45
            ctx.strokeStyle = Theme.accent
            ctx.arc(centerX, centerY, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI / 12, false)
            ctx.stroke()
            ctx.globalAlpha = 1
            return
        }

        // 底色轨道：完整一圈，衬出前景弧的长度对比。
        ctx.beginPath()
        ctx.setLineDash([])
        ctx.lineWidth = ring.strokeWidth
        ctx.strokeStyle = Theme.focusRingTrack
        ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
        ctx.stroke()

        // 进度弧从正上方（-90°）顺时针画出“剩余”部分——消退式核心视觉，
        // progress 越小画出的弧越短，直到耗尽时完全消失。
        var clamped = Math.max(0, Math.min(1, ring.progress))
        if (clamped <= 0) {
            return
        }
        var start = -Math.PI / 2
        var end = start + clamped * Math.PI * 2

        var arcStroke
        if (Qt.colorEqual(ring.ringColor, Theme.accent)) {
            var grad = ctx.createLinearGradient(centerX, centerY - radius,
                                                centerX + radius, centerY + radius)
            grad.addColorStop(0, Theme.focusRingArcStart)
            grad.addColorStop(0.5, Theme.focusRingArcMid)
            grad.addColorStop(1, Theme.focusRingArcEnd)
            arcStroke = grad
        } else {
            arcStroke = ring.ringColor
        }

        // 辉光底：用加宽低透明描边模拟发光，不使用 shadow，避免状态泄漏到后续绘制。
        ctx.save()
        ctx.globalAlpha = 0.35
        ctx.beginPath()
        ctx.lineWidth = ring.strokeWidth + 6
        ctx.strokeStyle = arcStroke
        ctx.arc(centerX, centerY, radius, start, end, false)
        ctx.stroke()
        ctx.restore()

        ctx.beginPath()
        ctx.lineWidth = ring.strokeWidth
        ctx.strokeStyle = arcStroke
        ctx.arc(centerX, centerY, radius, start, end, false)
        ctx.stroke()
    }
}
