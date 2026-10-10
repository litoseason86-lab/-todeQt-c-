import Foundation

public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general = "通用", categories = "科目", routines = "每日例行", sidebar = "侧栏顺序"
    case sync = "同步与日志", backup = "备份与恢复", export = "导出", appearance = "外观"
    public var id: String { rawValue }
}
public enum SettingsFeature: CaseIterable, Sendable {
    case workMinutes, breakMinutes, longBreak, quickStart, autoAdvance, freeTimerWarning, sound, nickname, dayStart
    case categories, routines, sidebar, sync, backup, export, wallpaper, backgroundTheme, slimClockFont, dashboardTimer
    case externalAI, bringWindowFront, globalHotkey, customShortcuts, closeToMenuBar, reduceMotion, reduceTransparency
}
public enum SettingsAvailability {
    public static let hidden: Set<SettingsFeature> = [.externalAI, .bringWindowFront, .globalHotkey,
        .customShortcuts, .closeToMenuBar, .reduceMotion, .reduceTransparency]
    // 平台入口表同时驱动导航与测试；系统辅助功能没有应用内副本。
    public static func features(in section: SettingsSection) -> [SettingsFeature] {
        switch section {
        case .general: return [.workMinutes, .breakMinutes, .longBreak, .quickStart, .autoAdvance,
            .freeTimerWarning, .sound, .nickname, .dayStart]
        case .categories: return [.categories]
        case .routines: return [.routines]
        case .sidebar: return [.sidebar]
        case .sync: return [.sync]
        case .backup: return [.backup]
        case .export: return [.export]
        case .appearance: return [.wallpaper, .backgroundTheme, .slimClockFont, .dashboardTimer]
        }
    }
    public static var sections: [SettingsSection] { SettingsSection.allCases.filter { !features(in: $0).isEmpty } }
    // ThemeGate 核对这份展示选项与 Theme.qml，避免外观选择器与壁纸资产漂移。
    public static let themes: [(id: String, title: String)] = [
        ("warm", "暖色"), ("pink", "粉色"), ("jiangnan", "烟雨江南"), ("sword", "雪岭剑影"),
        ("starry", "星空"), ("rainy", "雨夜窗景"), ("moon", "月夜山影")]
}
