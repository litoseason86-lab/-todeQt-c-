import QtQuick
import ".."

// 极简单色线性图标，Canvas 绘制（与 FocusRing/ChartPie 同一套技术）。
// 全部在 24×24 坐标里作画，按 size 缩放；描边宽度按缩放反算，保证视觉粗细恒定。
Canvas {
    id: root

    property string name: ""
    property color color: Theme.inkSoft
    property real size: 18
    property real lineW: 1.8

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    antialiasing: true

    onColorChanged: requestPaint()
    onNameChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var s = width / 24
        ctx.scale(s, s)
        ctx.strokeStyle = root.color
        ctx.fillStyle = root.color
        ctx.lineWidth = root.lineW / s
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        function stroke() { ctx.stroke() }
        function begin() { ctx.beginPath() }
        function circle(cx, cy, r) { ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke() }
        function dot(cx, cy, r) { ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.fill() }
        function line(x1, y1, x2, y2) { ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke() }
        function poly(pts, close) {
            ctx.beginPath()
            ctx.moveTo(pts[0], pts[1])
            for (var i = 2; i < pts.length; i += 2)
                ctx.lineTo(pts[i], pts[i + 1])
            if (close) ctx.closePath()
            ctx.stroke()
        }
        function roundRect(x, y, w, h, r) {
            ctx.beginPath()
            ctx.moveTo(x + r, y)
            ctx.arcTo(x + w, y, x + w, y + h, r)
            ctx.arcTo(x + w, y + h, x, y + h, r)
            ctx.arcTo(x, y + h, x, y, r)
            ctx.arcTo(x, y, x + w, y, r)
            ctx.closePath()
            ctx.stroke()
        }

        switch (root.name) {
        case "appearance": // 明暗对比圆
            circle(12, 12, 9)
            line(12, 3, 12, 21)
            break
        case "focus": // 时钟
            circle(12, 12, 9)
            begin(); ctx.moveTo(12, 7.5); ctx.lineTo(12, 12); ctx.lineTo(15.5, 13.5); stroke()
            break
        case "general": // 滑块
            line(4, 8.5, 20, 8.5)
            line(4, 15.5, 20, 15.5)
            ctx.fillStyle = Theme.surface
            ctx.beginPath(); ctx.arc(9, 8.5, 2.7, 0, Math.PI * 2); ctx.fill(); ctx.stroke()
            ctx.beginPath(); ctx.arc(15, 15.5, 2.7, 0, Math.PI * 2); ctx.fill(); ctx.stroke()
            ctx.fillStyle = root.color
            break
        case "data": // 数据盘（圆柱）
            ctx.beginPath(); ctx.ellipse(4, 4, 16, 6); ctx.stroke()
            line(4, 7, 4, 17); line(20, 7, 20, 17)
            ctx.beginPath(); ctx.ellipse(4, 14, 16, 6, 0, 0, Math.PI); ctx.stroke()
            break
        case "about": // 信息
            circle(12, 12, 9)
            dot(12, 8, 1.05)
            line(12, 11, 12, 16.5)
            break
        case "spark": // 减少动效：四角星
            poly([12, 3.5, 13.7, 10.3, 20.5, 12, 13.7, 13.7, 12, 20.5, 10.3, 13.7, 3.5, 12, 10.3, 10.3], true)
            break
        case "layers": // 减少透明度：叠层
            poly([12, 3, 20.5, 8, 12, 13, 3.5, 8], true)
            poly([3.5, 12, 12, 17, 20.5, 12], false)
            poly([3.5, 16, 12, 21, 20.5, 16], false)
            break
        case "target": // 专注时长：靶心
            circle(12, 12, 8.5)
            circle(12, 12, 4)
            dot(12, 12, 1.1)
            break
        case "pause": // 休息时长：暂停
            roundRect(8.2, 6.5, 2.6, 11, 1.2)
            roundRect(13.2, 6.5, 2.6, 11, 1.2)
            break
        case "moon": // 长休息：月牙
            ctx.beginPath()
            ctx.arc(12, 12, 8.5, Math.PI * 0.5, Math.PI * 1.5, false)
            ctx.arc(14.5, 12, 9, Math.PI * 1.5, Math.PI * 0.5, true)
            ctx.closePath(); ctx.stroke()
            break
        case "hash": // 长休息间隔：#
            line(9.5, 4.5, 8, 19.5); line(16, 4.5, 14.5, 19.5)
            line(4.5, 9.5, 19.5, 9.5); line(4.5, 14.5, 19.5, 14.5)
            break
        case "play": // 自动开始休息：播放
            poly([9, 6.5, 18, 12, 9, 17.5], true)
            break
        case "next": // 自动开始下一个：快进
            poly([6, 6.5, 14, 12, 6, 17.5], true)
            line(16.5, 6.5, 16.5, 17.5)
            break
        case "bell": // 提示音：铃铛
            ctx.beginPath()
            ctx.moveTo(7, 16.5)
            ctx.lineTo(7, 11)
            ctx.arc(12, 11, 5, Math.PI, 0)
            ctx.lineTo(17, 16.5)
            ctx.closePath(); ctx.stroke()
            line(4.5, 16.5, 19.5, 16.5)
            ctx.beginPath(); ctx.arc(12, 18.5, 1.9, 0, Math.PI); ctx.stroke()
            break
        case "front": // 窗口置前：置于最前
            line(4.5, 5, 19.5, 5)
            roundRect(6.5, 9, 11, 10, 2)
            ctx.beginPath(); ctx.moveTo(12, 15.5); ctx.lineTo(12, 11); stroke()
            poly([9.5, 13, 12, 10.5, 14.5, 13], false)
            break
        case "person": // 昵称
            circle(12, 8.5, 3.6)
            ctx.beginPath(); ctx.arc(12, 21, 7.5, Math.PI * 1.15, Math.PI * 1.85, false); ctx.stroke()
            break
        case "sunrise": // 一天开始于：日出
            line(3.5, 18.5, 20.5, 18.5)
            ctx.beginPath(); ctx.arc(12, 18.5, 5, Math.PI, 0, true); ctx.stroke()
            line(12, 4.5, 12, 8); line(6, 7, 7.6, 9); line(18, 7, 16.4, 9)
            break
        case "calendar": // 每日例行
            roundRect(4, 5.5, 16, 15, 2.2)
            line(4, 10, 20, 10)
            line(8.5, 3.5, 8.5, 7); line(15.5, 3.5, 15.5, 7)
            break
        case "grid": // 科目管理
            roundRect(4.5, 4.5, 6, 6, 1.4)
            roundRect(13.5, 4.5, 6, 6, 1.4)
            roundRect(4.5, 13.5, 6, 6, 1.4)
            roundRect(13.5, 13.5, 6, 6, 1.4)
            break
        case "export": // 数据导出
            begin(); ctx.moveTo(12, 4); ctx.lineTo(12, 15); stroke()
            poly([8, 8, 12, 4, 16, 8], false)
            begin(); ctx.moveTo(4.5, 14); ctx.lineTo(4.5, 19); ctx.lineTo(19.5, 19); ctx.lineTo(19.5, 14); stroke()
            break
        default:
            break
        }
    }
}
