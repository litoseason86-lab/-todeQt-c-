import SwiftUI

// 计时数字：等宽数字避免跳动，整串绘制避免每次 tick 改变文本树。
struct FocusClockText: View {
    var text: String
    var size: CGFloat
    var slim: Bool
    var color: Color

    var body: some View {
        // iOS 26 已废弃 Text 的 + 拼接；保持等宽整串绘制，避免每次 tick 触发不同的文本树。
        Text(text).foregroundStyle(color)
        .scaledSystemFont(size: size, weight: slim ? .light : .medium, design: .rounded).monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityLabel(text)
    }
}
