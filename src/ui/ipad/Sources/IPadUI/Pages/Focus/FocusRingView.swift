import SwiftUI

// 自绘计时圆环（P4 约定里允许自绘的三处之一）：底轨加一段随剩余比例消退的弧。
// 颜色只用 ThemeColors；弧长变化的过渡在「减少动态效果」打开时关掉，直接跳到新值。
enum FocusRingTone { case work, rest, done }

struct FocusRingView<Center: View>: View {
    var progress: Double
    var tone: FocusRingTone
    var dimmed: Bool
    var reduceMotion: Bool
    var lineWidth: CGFloat = 14
    var glassFill = true
    @ViewBuilder var center: () -> Center

    private var arcStyle: AnyShapeStyle {
        switch tone {
        case .work:
            AnyShapeStyle(AngularGradient(colors: [ThemeColors.focusRingArcStart, ThemeColors.focusRingArcMid, ThemeColors.focusRingArcEnd],
                                          center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
        case .rest: AnyShapeStyle(ThemeColors.focusBreakAccent)
        case .done: AnyShapeStyle(ThemeColors.success)
        }
    }

    var body: some View {
        ZStack {
            if glassFill {
            Circle().fill(RadialGradient(colors: [ThemeColors.focusGlassCenter, ThemeColors.focusGlassEdge],
                                         center: .center, startRadius: 0, endRadius: 160))
            }
            Circle().stroke(ThemeColors.focusRingTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(arcStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(dimmed ? 0.45 : 1)
                // 每秒一个新值，线性过渡让弧匀速消退；减少动态效果时不做过渡。
                .animation(reduceMotion ? nil : .linear(duration: 1), value: progress)
            center()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }
}
