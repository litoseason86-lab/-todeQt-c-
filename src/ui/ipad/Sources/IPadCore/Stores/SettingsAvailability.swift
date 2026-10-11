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
        case .appearance: return [.wallpaper, .backgroundTheme, .slimClockFont]
        }
    }
    public static var sections: [SettingsSection] { SettingsSection.allCases.filter { !features(in: $0).isEmpty } }
    // ThemeGate 核对这份展示选项与 Theme.qml，避免外观选择器与壁纸资产漂移。
    public struct Theme: Sendable {
        public let id: String
        public let title: String
        public let mode: String
        public let base: String
    }
    public static let themes: [Theme] = [
        Theme(id: "warm", title: "暖色", mode: "light", base: "#f3e3cf"),
        Theme(id: "pink", title: "粉色", mode: "light", base: "#efc4d0"),
        Theme(id: "jiangnan", title: "烟雨江南", mode: "light", base: "#dfe8e2"),
        Theme(id: "sword", title: "雪岭剑影", mode: "light", base: "#ccd4e6"),
        Theme(id: "starry", title: "星空", mode: "dark", base: "#12102a"),
        Theme(id: "rainy", title: "雨夜窗景", mode: "dark", base: "#0f1622"),
        Theme(id: "moon", title: "月夜山影", mode: "dark", base: "#0d1626")]
    public static func theme(_ id: String) -> Theme { themes.first { $0.id == id } ?? themes[0] }
}
