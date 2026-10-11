import IPadCore
import SwiftUI

// 055-R4：设计稿第 3 版的公共样式。尺寸逐项取自定稿 CSS（.card 圆角 18、.start/.filter 胶囊高 36、
// .task 行高 64、页边距宽 32 窄 16、内容最宽 900），颜色一律走 ThemeColors，主题与明暗由令牌负责。
enum Design {
    static let cardRadius: CGFloat = 18
    static let contentMaxWidth: CGFloat = 900
    static func pagePadding(compact: Bool) -> CGFloat { compact ? 16 : 32 }
}

// 白卡片：定稿 .card（#fffef9、圆角 18、0 1px 3px 的浅投影）。
struct DesignCard<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets()
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
            .shadow(color: ThemeColors.shadow.opacity(0.08), radius: 1.5, y: 1)
    }
}

// 页头：大标题 34 粗 + 副标题 15。备忘录等没有副标题时只传标题。
struct PageHeader: View {
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(ThemeColors.inkStrong)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 浅色胶囊：定稿 .start / .filter（底 #f0e6d2、字 #7a4c1e、14 半粗、高 36）。
struct SoftPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ThemeColors.accentFillInk)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(ThemeColors.accentFill, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// 实心焦糖胶囊：选中态与主按钮（底 #8d5f2b、字 #fffef9）。深色令牌下自动换成浅焦糖底、深字。
struct ProminentPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ThemeColors.surface)
            .padding(.horizontal, 16).frame(minHeight: 40)
            .background(ThemeColors.accentInk, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

// 焦糖文字按钮：定稿 .newbtn / .pill（无底色、焦糖字、半粗）。
struct AccentTextButtonStyle: ButtonStyle {
    var size: CGFloat = 14
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(ThemeColors.accentInk)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// 卡片内分隔线：定稿 border-bottom 1px #f0e6d2。
struct CardDivider: View {
    var leading: CGFloat = 0
    var body: some View {
        Rectangle().fill(ThemeColors.borderSubtle).frame(height: 1).padding(.leading, leading)
    }
}

// 数字与单位混排：定稿里「1小时05分」「72天」数字大、单位小。只排版服务给出的数，不做换算。
struct MixedNumberText: View {
    let parts: [(text: String, isNumber: Bool)]
    var numberSize: CGFloat = 30
    var unitSize: CGFloat = 15
    // 字色由调用方给：外层 foregroundStyle 盖不过这里，选中态要换色时必须传进来。
    var color: Color = ThemeColors.inkStrong
    var body: some View {
        // iOS 26 已废弃 Text 的 + 拼接；用带字体属性的 AttributedString 拼成一个 Text。
        var string = AttributedString()
        for part in parts {
            var piece = AttributedString(part.text)
            piece.font = .system(size: part.isNumber ? numberSize : unitSize, weight: part.isNumber ? .bold : .semibold)
            string += piece
        }
        return Text(string)
            .monospacedDigit()
            .foregroundStyle(color)
    }

    // 把「1 小时 05 分」这类已格式化的文字按数字与非数字切段。
    static func split(_ text: String) -> [(text: String, isNumber: Bool)] {
        var parts: [(text: String, isNumber: Bool)] = []
        for character in text where character != " " {
            let isNumber = character.isNumber || character == ":" || character == "."
            if let last = parts.last, last.isNumber == isNumber {
                parts[parts.count - 1].text.append(character)
            } else {
                parts.append((String(character), isNumber))
            }
        }
        return parts
    }
}

// 页面内容列：宽窗最宽 900 居中，左右页边距按宽窄取 32 / 16。
struct PageColumn<Content: View>: View {
    let compact: Bool
    var maxWidth: CGFloat = Design.contentMaxWidth
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, Design.pagePadding(compact: compact))
            .frame(maxWidth: .infinity)
    }
}

// 用 List 承载的卡片：每行按位置画圆角底，拼起来就是一张圆角 18 的卡片。
// List 才有系统滑动操作与拖动排序，所以卡片列表不改用 ScrollView。
enum CardRowPosition { case single, top, middle, bottom }

struct CardRowBackground: View {
    let position: CardRowPosition
    var fill: Color = ThemeColors.surface
    var body: some View {
        let r = Design.cardRadius
        let top = position == .single || position == .top
        let bottom = position == .single || position == .bottom
        UnevenRoundedRectangle(topLeadingRadius: top ? r : 0, bottomLeadingRadius: bottom ? r : 0,
                               bottomTrailingRadius: bottom ? r : 0, topTrailingRadius: top ? r : 0, style: .continuous)
            .fill(fill)
    }
}

extension View {
    // 卡片里的一行：圆角底、去掉系统分隔线（行内自己画 CardDivider）、零内边距由行自己控制。
    func cardRow(_ position: CardRowPosition, fill: Color = ThemeColors.surface, insets: EdgeInsets = EdgeInsets()) -> some View {
        listRowBackground(CardRowBackground(position: position, fill: fill))
            .listRowInsets(insets)
            .listRowSeparator(.hidden)
    }
    // 卡片之间的透明行：页头、间距、卡片外的说明。
    func plainRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        listRowBackground(Color.clear).listRowInsets(insets).listRowSeparator(.hidden)
    }
}

// 页面级 List：去掉系统底色，按宽窄留页边距并把内容限制在最宽 900 的居中列里。
// 宽窗侧栏浮在内容上方，用安全区让开；页边距要加在安全区之外（contentMargins 与安全区取较大者，
// 10-11 真机截图里左边距因此被侧栏吃掉），所以用 safeAreaPadding。
struct PageListModifier: ViewModifier {
    let geometry: GeometryProxy
    let compact: Bool
    var maxWidth: CGFloat = Design.contentMaxWidth
    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaPadding(.horizontal, Design.pageMargin(geometry: geometry, compact: compact, maxWidth: maxWidth))
            .environment(\.defaultMinListRowHeight, 1)
    }
}

extension Design {
    // 安全区之外的页边距：至少 32 / 16，可用宽度超过 maxWidth 时两边均分余量，让内容列居中。
    static func pageMargin(geometry: GeometryProxy, compact: Bool, maxWidth: CGFloat = contentMaxWidth) -> CGFloat {
        let available = geometry.size.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing
        return max(pagePadding(compact: compact), (available - maxWidth) / 2)
    }
}

// 进度条：高 8、圆角 4，底为浅焦糖、填充为焦糖（定稿今日目标与周概览）。
struct ProgressBar: View {
    let percent: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ThemeColors.accentFill)
                Capsule().fill(ThemeColors.accentInk)
                    .frame(width: geometry.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 8)
    }
}

// 工具栏里的「图标 + 文字」按钮（定稿「✎ 记一笔」「+ 新增目标」）。iPadOS 26 的工具栏只画 Label 的图标，
// 10-11 真机截图里文字都被省掉了，所以标签写成自己排的一行。
struct ToolbarTextLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .medium))
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(ThemeColors.accentInk)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// 页内推入的子页（窄窗知识缺口详情、备忘录纸面等）不经过外壳的页面修饰，单独铺同一份主题底与壁纸。
struct PageBackground: ViewModifier {
    @Environment(ShellStore.self) private var shell
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(shell.selectedTheme != nil ? .hidden : .visible)
            .background { WallpaperBackground(theme: shell.snapshot.backgroundTheme, enabled: shell.wallpaperVisible) }
    }
}
