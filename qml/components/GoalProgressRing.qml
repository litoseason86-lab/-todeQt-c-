import QtQuick
import QtQuick.Shapes
import ".."

// 目标进度环：列表卡与网格瓦片共用，只有尺寸和字号不同。
// 用 Shape 避免 Canvas 的 JavaScript 绘制与纹理上传；进度变化仍会重建路径，
// 因此这里不做逐帧路径动画。列表启用了 delegate 复用，立即更新还能保证圆弧和
// 中央数字始终属于同一个目标，不会短暂混入上一个目标的进度。
Item {
    id: root

    property int percent: 0
    property bool achieved: false
    property int ringSize: 44
    property int strokeWidth: 4
    property int labelPixelSize: Theme.fontXs

    readonly property real clampedPercent: Math.max(0, Math.min(100, root.percent))
    readonly property real radius: (root.ringSize - root.strokeWidth) / 2

    implicitWidth: root.ringSize
    implicitHeight: root.ringSize
    // 环是标题旁的图形化重复，百分比文字已由卡片的 Accessible.name 播报。
    Accessible.ignored: true

    Shape {
        id: ringShape

        anchors.centerIn: parent
        width: root.ringSize
        height: root.ringSize
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: Theme.borderSubtle
            strokeWidth: root.strokeWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.ringSize / 2
                centerY: root.ringSize / 2
                radiusX: root.radius
                radiusY: root.radius
                startAngle: -90
                sweepAngle: 360
            }
        }

        ShapePath {
            strokeColor: root.achieved ? Theme.accentInk : Theme.accent
            strokeWidth: root.strokeWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                objectName: "goalProgressArc"

                centerX: root.ringSize / 2
                centerY: root.ringSize / 2
                radiusX: root.radius
                radiusY: root.radius
                startAngle: -90
                // 0% 时扫过 0 度：RoundCap 会留下一个圆点，这里靠 sweepAngle 归零规避。
                sweepAngle: 360 * root.clampedPercent / 100
            }
        }
    }

    Text {
        anchors.centerIn: parent
        text: root.clampedPercent + "%"
        textFormat: Text.PlainText
        color: Theme.inkStrong
        font {
            pixelSize: root.labelPixelSize
            family: Theme.fontFamilyData
            weight: Font.Bold
        }
    }
}
