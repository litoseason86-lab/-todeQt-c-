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
    // 底轨线宽；不给就和进度弧一样粗。专注页定稿是 2 的细底轨配 4 的进度弧。
    var trackWidth: CGFloat? = nil
    var glassFill = true
    // 定稿专注页：专注弧用焦糖单色、底轨用浅焦糖；沉浸页仍用渐变弧。
    var workColor: Color? = nil
    var trackColor: Color? = nil
    @ViewBuilder var center: () -> Center

    private var arcStyle: AnyShapeStyle {
        switch tone {
        case .work:
            if let workColor { return AnyShapeStyle(workColor) }
            return AnyShapeStyle(AngularGradient(colors: [ThemeColors.focusRingArcStart, ThemeColors.focusRingArcMid, ThemeColors.focusRingArcEnd],
                                          center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
        case .rest: return AnyShapeStyle(ThemeColors.focusBreakAccent)
        case .done: return AnyShapeStyle(ThemeColors.success)
        }
    }

    var body: some View {
        ZStack {
            if glassFill {
            Circle().fill(RadialGradient(colors: [ThemeColors.focusGlassCenter, ThemeColors.focusGlassEdge],
                                         center: .center, startRadius: 0, endRadius: 160))
            }
            // 底轨与进度弧画在同一条圆周上：两者线宽不同时都按较粗的那条内缩，细底轨正好落在弧的中线。
            let inset = max(lineWidth, trackWidth ?? lineWidth) / 2
            Circle().inset(by: inset).stroke(trackColor ?? ThemeColors.focusRingTrack, lineWidth: trackWidth ?? lineWidth)
            Circle().inset(by: inset)
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(arcStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // 进度为 0（自由计时、主动休息只留底轨）时整条弧不画；圆头线帽在 0.001 处会留下一个点。
                .opacity(progress <= 0 ? 0 : (dimmed ? 0.45 : 1))
                // 每秒一个新值，线性过渡让弧匀速消退；减少动态效果时不做过渡。
                .animation(reduceMotion ? nil : .linear(duration: 1), value: progress)
            center()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }
}
