import IPadCore
import SwiftUI
import UIKit

// 数值来自颜色资源，浅深自动随系统切换；ipad_theme_gate.py 与 Theme.qml 比对实际资源。
// 每个令牌只建一次（static let）：动态颜色按对象判断相等，每次现建一个新对象，SwiftUI 会认为颜色每次都变了，
// 用到它的控件在父视图每次重算时都得跟着重画（10-12 真机采样：开一次表单里光解析颜色就占约 20 毫秒）。
// 颜色本身仍是动态的，按所在窗口的明暗与主题特征现解析，只建一次不影响切换外观。
enum ThemeColors {
    // UIKit 的动态颜色读取本窗口的主题特征；系统外观用原生语义色，主题外观才取日/夜资源。
    // 颜色仍由同一入口消费，页面不保存第二份明暗状态，也不需要改其它计划的内容页。
    private static func semantic(_ name: String, system: UIColor) -> Color {
        // 颜色资源只按明暗提供变体；保留动态资源对象，再按所在窗口的 traits（明暗、主题特征）解析。
        // 每次解析都重新按名查资源会让首开表单和页面布局重复经过资源目录，不能缓存最终颜色，否则切主题会失效。
        let themed = ThemeColorResource(name: name)
        return Color(uiColor: UIColor { traits in
            if traits[IPadThemeTrait.self].isEmpty { return system.resolvedColor(with: traits) }
            return themed.value()?.resolvedColor(with: traits)
                ?? system.resolvedColor(with: traits)
        })
    }
    static func themeBase(_ id: String) -> Color {
        Color("themeBase_" + SettingsAvailability.theme(id).id, bundle: .main)
    }

    static let surface = semantic("surface", system: .secondarySystemGroupedBackground)
    static let surfaceRaised = semantic("surfaceRaised", system: .secondarySystemBackground)
    // 弹出表单的底：主题外观取浮起暖底（定稿补录表单 #faf6ee），系统外观保留系统分组表单底。
    static let sheetBackground = semantic("surfaceRaised", system: .systemGroupedBackground)
    static let surfaceSunken = semantic("surfaceSunken", system: .tertiarySystemBackground)
    static let border = semantic("border", system: .separator)
    static let borderSubtle = semantic("borderSubtle", system: .separator)
    static let inkStrong = semantic("inkStrong", system: .label)
    static let ink = semantic("ink", system: .label)
    static let inkSoft = semantic("inkSoft", system: .secondaryLabel)
    static let inkMuted = semantic("inkMuted", system: .tertiaryLabel)
    static let inputInk = semantic("inputInk", system: .label)
    static let inputPlaceholderInk = semantic("inputPlaceholderInk", system: .placeholderText)
    static let inputSelection = Color("inputSelection", bundle: .main)
    static let inputSelectedInk = Color("inputSelectedInk", bundle: .main)
    static let inputPopupSurface = semantic("inputPopupSurface", system: .secondarySystemBackground)
    static let inputPopupBorder = semantic("inputPopupBorder", system: .separator)
    static let inputPopupHighlight = Color("inputPopupHighlight", bundle: .main)
    static let controlSurface = semantic("controlSurface", system: .secondarySystemBackground)
    static let controlInk = semantic("controlInk", system: .label)
    static let accent = Color("accent", bundle: .main)
    static let accentStrong = Color("accentStrong", bundle: .main)
    static let accentFill = Color("accentFill", bundle: .main)
    static let accentFillStrong = Color("accentFillStrong", bundle: .main)
    static let accentFillInk = Color("accentFillInk", bundle: .main)
    static let accentSoft = Color("accentSoft", bundle: .main)
    static let accentInk = Color("accentInk", bundle: .main)
    static let accentForeground = Color("accentForeground", bundle: .main)
    static let focusRing = Color("focusRing", bundle: .main)
    static let success = Color("success", bundle: .main)
    static let successInk = Color("successInk", bundle: .main)
    static let danger = Color("danger", bundle: .main)
    static let dangerBorder = Color("dangerBorder", bundle: .main)
    static let dangerSoft = Color("dangerSoft", bundle: .main)
    static let shadow = Color("shadow", bundle: .main)
    static let modalScrim = Color("modalScrim", bundle: .main)
    static let dialogScrim = Color("dialogScrim", bundle: .main)
    static let heatmapEmptyTrack = Color("heatmapEmptyTrack", bundle: .main)
    static let focusBreakAccent = Color("focusBreakAccent", bundle: .main)
    static let focusBreakInk = Color("focusBreakInk", bundle: .main)
    static let focusRingArcStart = Color("focusRingArcStart", bundle: .main)
    static let focusRingArcMid = Color("focusRingArcMid", bundle: .main)
    static let focusRingArcEnd = Color("focusRingArcEnd", bundle: .main)
    static let focusRingTrack = Color("focusRingTrack", bundle: .main)
    static let focusGlassCenter = Color("focusGlassCenter", bundle: .main)
    static let focusGlassEdge = Color("focusGlassEdge", bundle: .main)
    static let focusGlassShadow = Color("focusGlassShadow", bundle: .main)
    static let focusGlassHighlight = Color("focusGlassHighlight", bundle: .main)
    static let focusColonMuted = Color("focusColonMuted", bundle: .main)
    static let glassSidebar = semantic("glassSidebar", system: .systemGroupedBackground)
    static let glassCard = semantic("glassCard", system: .secondarySystemGroupedBackground)
    static let glassHover = semantic("glassHover", system: .tertiarySystemFill)
    static let glassHoverIdle = semantic("glassHoverIdle", system: .quaternarySystemFill)
    static let glassAccent = Color("glassAccent", bundle: .main)
    static let glassDialog = semantic("glassDialog", system: .secondarySystemBackground)
    static let glassDialogSoft = semantic("glassDialogSoft", system: .tertiarySystemBackground)
    static let glassBorder = semantic("glassBorder", system: .separator)
    static let glassTrack = semantic("glassTrack", system: .tertiarySystemFill)
    static let glassThumb = semantic("glassThumb", system: .secondarySystemBackground)
    static let glassSolidCard = semantic("glassSolidCard", system: .secondarySystemGroupedBackground)
    static let glassSolidHover = semantic("glassSolidHover", system: .tertiarySystemBackground)
    static let glassSolidAccent = Color("glassSolidAccent", bundle: .main)
    static let glassSolidSidebar = semantic("glassSolidSidebar", system: .systemGroupedBackground)
    static let glassSolidTrack = semantic("glassSolidTrack", system: .tertiarySystemFill)
    static let glassSolidThumb = semantic("glassSolidThumb", system: .secondarySystemBackground)
    static let chartColors0 = Color("chartColors0", bundle: .main)
    static let chartColors1 = Color("chartColors1", bundle: .main)
    static let chartColors2 = Color("chartColors2", bundle: .main)
    static let chartColors3 = Color("chartColors3", bundle: .main)
    static let chartColors4 = Color("chartColors4", bundle: .main)
    static let chartColors5 = Color("chartColors5", bundle: .main)
    static let heatmapBandColors0 = Color("heatmapBandColors0", bundle: .main)
    static let heatmapBandColors1 = Color("heatmapBandColors1", bundle: .main)
    static let heatmapBandColors2 = Color("heatmapBandColors2", bundle: .main)
    static let heatmapBandColors3 = Color("heatmapBandColors3", bundle: .main)
}

// 动态颜色的解析回调可能不在主线程，资源对象的惰性加载用锁隔离；系统外观不加载用不到的主题资源。
// 只保存未解析的 UIColor（仍包含明暗变体），每次绘制的最终颜色继续按调用方特征决定。
private final class ThemeColorResource: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var loaded = false
    private var color: UIColor?
    init(name: String) { self.name = name }
    func value() -> UIColor? {
        lock.withLock {
            if !loaded {
                color = UIColor(named: name, in: .main, compatibleWith: nil)
                loaded = true
            }
            return color
        }
    }
}
