import SwiftUI

// 计时数字：等宽数字避免跳动，整串绘制避免每次 tick 改变文本树。
struct FocusClockText: View {
    var text: String
    var size: CGFloat
    var slim: Bool
    var color: Color
    private var font: Font { .system(size: size, weight: slim ? .light : .medium, design: .rounded).monospacedDigit() }

    var body: some View {
        // iOS 26 已废弃 Text 的 + 拼接；保持等宽整串绘制，避免每次 tick 触发不同的文本树。
        Text(text).foregroundStyle(color)
        .font(font)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityLabel(text)
    }
}
