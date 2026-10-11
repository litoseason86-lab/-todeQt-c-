import IPadCore
import SwiftUI
import UIKit

// 数值来自颜色资源，浅深自动随系统切换；ipad_theme_gate.py 与 Theme.qml 比对实际资源。
enum ThemeColors {
    // UIKit 的动态颜色读取本窗口的主题特征；系统外观用原生语义色，主题外观才取日/夜资源。
    // 颜色仍由同一入口消费，页面不保存第二份明暗状态，也不需要改其它计划的内容页。
    private static func semantic(_ name: String, system: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            if traits[IPadThemeTrait.self].isEmpty { return system.resolvedColor(with: traits) }
            return UIColor(named: name, in: .main, compatibleWith: traits)?.resolvedColor(with: traits)
                ?? system.resolvedColor(with: traits)
        })
    }
    static func themeBase(_ id: String) -> Color {
        Color("themeBase_" + SettingsAvailability.theme(id).id, bundle: .main)
    }

    static var surface: Color { semantic("surface", system: .secondarySystemGroupedBackground) }
    static var surfaceRaised: Color { semantic("surfaceRaised", system: .secondarySystemBackground) }
    // 弹出表单的底：主题外观取浮起暖底（定稿补录表单 #faf6ee），系统外观保留系统分组表单底。
    static var sheetBackground: Color { semantic("surfaceRaised", system: .systemGroupedBackground) }
    static var surfaceSunken: Color { semantic("surfaceSunken", system: .tertiarySystemBackground) }
    static var border: Color { semantic("border", system: .separator) }
    static var borderSubtle: Color { semantic("borderSubtle", system: .separator) }
    static var inkStrong: Color { semantic("inkStrong", system: .label) }
    static var ink: Color { semantic("ink", system: .label) }
    static var inkSoft: Color { semantic("inkSoft", system: .secondaryLabel) }
    static var inkMuted: Color { semantic("inkMuted", system: .tertiaryLabel) }
    static var inputInk: Color { semantic("inputInk", system: .label) }
    static var inputPlaceholderInk: Color { semantic("inputPlaceholderInk", system: .placeholderText) }
    static var inputSelection: Color { Color("inputSelection", bundle: .main) }
    static var inputSelectedInk: Color { Color("inputSelectedInk", bundle: .main) }
    static var inputPopupSurface: Color { semantic("inputPopupSurface", system: .secondarySystemBackground) }
    static var inputPopupBorder: Color { semantic("inputPopupBorder", system: .separator) }
    static var inputPopupHighlight: Color { Color("inputPopupHighlight", bundle: .main) }
    static var controlSurface: Color { semantic("controlSurface", system: .secondarySystemBackground) }
    static var controlInk: Color { semantic("controlInk", system: .label) }
    static var accent: Color { Color("accent", bundle: .main) }
    static var accentStrong: Color { Color("accentStrong", bundle: .main) }
    static var accentFill: Color { Color("accentFill", bundle: .main) }
    static var accentFillStrong: Color { Color("accentFillStrong", bundle: .main) }
    static var accentFillInk: Color { Color("accentFillInk", bundle: .main) }
    static var accentSoft: Color { Color("accentSoft", bundle: .main) }
    static var accentInk: Color { Color("accentInk", bundle: .main) }
    static var accentForeground: Color { Color("accentForeground", bundle: .main) }
    static var focusRing: Color { Color("focusRing", bundle: .main) }
    static var success: Color { Color("success", bundle: .main) }
    static var successInk: Color { Color("successInk", bundle: .main) }
    static var danger: Color { Color("danger", bundle: .main) }
    static var dangerBorder: Color { Color("dangerBorder", bundle: .main) }
    static var dangerSoft: Color { Color("dangerSoft", bundle: .main) }
    static var shadow: Color { Color("shadow", bundle: .main) }
    static var modalScrim: Color { Color("modalScrim", bundle: .main) }
    static var dialogScrim: Color { Color("dialogScrim", bundle: .main) }
    static var heatmapEmptyTrack: Color { Color("heatmapEmptyTrack", bundle: .main) }
    static var focusBreakAccent: Color { Color("focusBreakAccent", bundle: .main) }
    static var focusBreakInk: Color { Color("focusBreakInk", bundle: .main) }
    static var focusRingArcStart: Color { Color("focusRingArcStart", bundle: .main) }
    static var focusRingArcMid: Color { Color("focusRingArcMid", bundle: .main) }
    static var focusRingArcEnd: Color { Color("focusRingArcEnd", bundle: .main) }
    static var focusRingTrack: Color { Color("focusRingTrack", bundle: .main) }
    static var focusGlassCenter: Color { Color("focusGlassCenter", bundle: .main) }
    static var focusGlassEdge: Color { Color("focusGlassEdge", bundle: .main) }
    static var focusGlassShadow: Color { Color("focusGlassShadow", bundle: .main) }
    static var focusGlassHighlight: Color { Color("focusGlassHighlight", bundle: .main) }
    static var focusColonMuted: Color { Color("focusColonMuted", bundle: .main) }
    static var glassSidebar: Color { semantic("glassSidebar", system: .systemGroupedBackground) }
    static var glassCard: Color { semantic("glassCard", system: .secondarySystemGroupedBackground) }
    static var glassHover: Color { semantic("glassHover", system: .tertiarySystemFill) }
    static var glassHoverIdle: Color { semantic("glassHoverIdle", system: .quaternarySystemFill) }
    static var glassAccent: Color { Color("glassAccent", bundle: .main) }
    static var glassDialog: Color { semantic("glassDialog", system: .secondarySystemBackground) }
    static var glassDialogSoft: Color { semantic("glassDialogSoft", system: .tertiarySystemBackground) }
    static var glassBorder: Color { semantic("glassBorder", system: .separator) }
    static var glassTrack: Color { semantic("glassTrack", system: .tertiarySystemFill) }
    static var glassThumb: Color { semantic("glassThumb", system: .secondarySystemBackground) }
    static var glassSolidCard: Color { semantic("glassSolidCard", system: .secondarySystemGroupedBackground) }
    static var glassSolidHover: Color { semantic("glassSolidHover", system: .tertiarySystemBackground) }
    static var glassSolidAccent: Color { Color("glassSolidAccent", bundle: .main) }
    static var glassSolidSidebar: Color { semantic("glassSolidSidebar", system: .systemGroupedBackground) }
    static var glassSolidTrack: Color { semantic("glassSolidTrack", system: .tertiarySystemFill) }
    static var glassSolidThumb: Color { semantic("glassSolidThumb", system: .secondarySystemBackground) }
    static var chartColors0: Color { Color("chartColors0", bundle: .main) }
    static var chartColors1: Color { Color("chartColors1", bundle: .main) }
    static var chartColors2: Color { Color("chartColors2", bundle: .main) }
    static var chartColors3: Color { Color("chartColors3", bundle: .main) }
    static var chartColors4: Color { Color("chartColors4", bundle: .main) }
    static var chartColors5: Color { Color("chartColors5", bundle: .main) }
    static var heatmapBandColors0: Color { Color("heatmapBandColors0", bundle: .main) }
    static var heatmapBandColors1: Color { Color("heatmapBandColors1", bundle: .main) }
    static var heatmapBandColors2: Color { Color("heatmapBandColors2", bundle: .main) }
    static var heatmapBandColors3: Color { Color("heatmapBandColors3", bundle: .main) }
}
