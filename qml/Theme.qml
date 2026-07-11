pragma Singleton
import QtQuick

// 全应用设计令牌的唯一来源。各 qml 通过相对目录导入后用 Theme.xxx 引用。
// 颜色 token 绑定当前主题色板（palette）；字号/间距/圆角为收敛后的比例阶梯。
QtObject {
    // —— 以下颜色 token 全部绑定当前主题色板（palette）；属性名保持不变，
    // 存量组件零改动跟随换色。palette 定义见文件下方主题系统 v2。——
    readonly property color surface: palette.surface
    readonly property color surfaceRaised: palette.surfaceRaised
    readonly property color surfaceSunken: palette.surfaceSunken

    readonly property color border: palette.border
    readonly property color borderSubtle: palette.borderSubtle

    readonly property color inkStrong: palette.inkStrong
    readonly property color ink: palette.ink
    readonly property color inkSoft: palette.inkSoft
    readonly property color inkMuted: palette.inkMuted

    readonly property color accent: palette.accent
    readonly property color accentStrong: palette.accentStrong
    readonly property color accentSoft: palette.accentSoft
    readonly property color accentInk: palette.accentInk

    readonly property color success: palette.success
    readonly property color danger: palette.danger
    readonly property color dangerBorder: palette.dangerBorder
    readonly property color dangerSoft: palette.dangerSoft

    // 投影恒为纯黑；透明度由各效果自身属性控制，不随主题。
    readonly property color shadow: "#000000"

    // —— 字号 Type Scale ——
    readonly property int fontXs: 11
    readonly property int fontSm: 12
    readonly property int fontMd: 13
    readonly property int fontLg: 15
    readonly property int fontXl: 18
    readonly property int fontXxl: 24
    readonly property int fontDisplay: 64

    // —— 字族（数字英雄；纯拉丁，仅对数字/拉丁可见，中文回退苹方）——
    // 字族名必须与打包 ttf 的家族名一致，FontAssetsTests 用 id 作用域守门。
    readonly property string fontFamilyClock: "Space Grotesk"      // 冷·计时数字
    readonly property string fontFamilyData: "Bricolage Grotesque" // 暖·统计/倒计时数字

    // —— 间距 Spacing（4/8 栅格）——
    readonly property int hairline: 2
    readonly property int space4: 4
    readonly property int space8: 8
    readonly property int space12: 12
    readonly property int space16: 16
    readonly property int space24: 24
    readonly property int space32: 32

    // —— 圆角 Radius ——
    readonly property int radiusSm: 4
    readonly property int radiusMd: 6
    readonly property int radiusLg: 8

    readonly property var chartColors: palette.chartColors
    readonly property color focusBreakAccent: chartColors[3]

    readonly property color focusRingArcStart: palette.focusRingArcStart
    readonly property color focusRingArcMid: palette.focusRingArcMid
    readonly property color focusRingArcEnd: palette.focusRingArcEnd
    readonly property color focusRingTrack: palette.focusRingTrack
    readonly property color focusGlassCenter: palette.focusGlassCenter
    readonly property color focusGlassEdge: palette.focusGlassEdge
    readonly property color focusGlassShadow: palette.focusGlassShadow
    readonly property color focusGlassHighlight: palette.focusGlassHighlight
    readonly property color focusColonMuted: palette.focusColonMuted

    readonly property color glassSidebar: palette.glassSidebar
    readonly property color glassCard: palette.glassCard
    readonly property color glassDialog: palette.glassDialog
    readonly property color glassBorder: palette.glassBorder

    // ══ 主题系统 v2：壁纸图片 + 每主题一套完整色板 ══
    // activeThemeId 由 MainWindow 绑定设置注入；palette 为当前主题对象。
    // themes[0] 必须是默认 warm：resolveTheme 对未知 id 回落首位。
    property string activeThemeId: "warm"

    // 旧 Canvas 主题 id → 新主题 id。旧主题全为浅色，迁移目标一律浅色款，
    // 不把老用户突然切进暗色界面。
    readonly property var legacyThemeMap: ({
        warmPaper: "warm", sunset: "warm", wheat: "warm",
        celadon: "jiangnan", mist: "jiangnan",
        sakura: "pink"
    })

    function migrateThemeId(themeId) {
        return legacyThemeMap[themeId] || themeId
    }

    function resolveTheme(themeId) {
        var target = migrateThemeId(themeId)
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === target) {
                return themes[i]
            }
        }
        return themes[0]
    }

    readonly property var palette: resolveTheme(activeThemeId)

    readonly property var themes: [
        {
            id: "warm", name: "暖色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/warm.png"),
            base: "#f3e3cf",
            surface: "#fffcf5", surfaceRaised: "#fdf6ea", surfaceSunken: "#f7ecd9",
            border: "#e4c9a0", borderSubtle: "#f0dfc2",
            inkStrong: "#52422e", ink: "#6b573d", inkSoft: "#9c8266", inkMuted: "#b09a7d",
            accent: "#dc9550", accentStrong: "#c98240", accentSoft: "#f6dfb9", accentInk: "#9a6524",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#dc9550", "#9c8266", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#f1bd7e", focusRingArcMid: "#f4d3ab", focusRingArcEnd: "#f4c3bd",
            focusRingTrack: "#faf1e8",
            focusGlassCenter: "#fffefb", focusGlassEdge: "#fdf3ee", focusGlassShadow: "#e2b9a6",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#e8bda6",
            glassSidebar: Qt.rgba(252 / 255, 244 / 255, 230 / 255, 0.72),
            glassCard: Qt.rgba(1, 253 / 255, 248 / 255, 0.92),
            glassDialog: Qt.rgba(1, 253 / 255, 248 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.85),
            wallpaperScrim: Qt.rgba(1, 252 / 255, 246 / 255, 0.16)
        },
        {
            id: "pink", name: "粉色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/pink.png"),
            base: "#efc4d0",
            surface: "#fffbfd", surfaceRaised: "#fdf4f8", surfaceSunken: "#f9e7ee",
            border: "#e8b7cc", borderSubtle: "#f3d3e0",
            inkStrong: "#573f4b", ink: "#6d525f", inkSoft: "#a37f8f", inkMuted: "#b697a4",
            accent: "#e5638f", accentStrong: "#d1517d", accentSoft: "#f8cfdd", accentInk: "#b03e66",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#e5638f", "#a37f8f", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#f3a0bc", focusRingArcMid: "#f8cbd9", focusRingArcEnd: "#f4c3bd",
            focusRingTrack: "#fbecf1",
            focusGlassCenter: "#fffcfd", focusGlassEdge: "#fdf0f4", focusGlassShadow: "#e3a8bd",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#edb7c8",
            glassSidebar: Qt.rgba(252 / 255, 238 / 255, 244 / 255, 0.72),
            glassCard: Qt.rgba(1, 251 / 255, 253 / 255, 0.92),
            glassDialog: Qt.rgba(1, 251 / 255, 253 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.85),
            wallpaperScrim: Qt.rgba(1, 250 / 255, 252 / 255, 0.16)
        },
        {
            id: "jiangnan", name: "烟雨江南", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/jiangnan.png"),
            base: "#dfe8e2",
            surface: "#fafdfb", surfaceRaised: "#f1f8f4", surfaceSunken: "#e7f1eb",
            border: "#b7d3c6", borderSubtle: "#d5e6dc",
            inkStrong: "#39473f", ink: "#54655c", inkSoft: "#84948a", inkMuted: "#9daba2",
            accent: "#5f9e85", accentStrong: "#4f8b73", accentSoft: "#cfe6da", accentInk: "#3e7d63",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#5f9e85", "#84948a", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#8fc4ae", focusRingArcMid: "#c0ddd0", focusRingArcEnd: "#b7d3c8",
            focusRingTrack: "#eaf3ee",
            focusGlassCenter: "#fdfffe", focusGlassEdge: "#f0f7f3", focusGlassShadow: "#b6cfc2",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#b9d2c6",
            glassSidebar: Qt.rgba(238 / 255, 246 / 255, 241 / 255, 0.72),
            glassCard: Qt.rgba(250 / 255, 253 / 255, 251 / 255, 0.92),
            glassDialog: Qt.rgba(250 / 255, 253 / 255, 251 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.85),
            wallpaperScrim: Qt.rgba(251 / 255, 253 / 255, 252 / 255, 0.16)
        },
        {
            id: "starry", name: "星空", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/starry.png"),
            base: "#12102a",
            surface: "#1b1936", surfaceRaised: "#232048", surfaceSunken: "#131126",
            border: "#3a3668", borderSubtle: "#2b2852",
            inkStrong: "#eceafb", ink: "#c6c2e0", inkSoft: "#8f8ab0", inkMuted: "#6f6a94",
            accent: "#8f7ff0", accentStrong: "#7b6ae0", accentSoft: "#35316b", accentInk: "#b9adff",
            success: "#6fcf73", danger: "#e0705a", dangerBorder: "#d97f6c", dangerSoft: "#cc8a76",
            chartColors: ["#8f7ff0", "#6f8fd8", "#d97f9c", "#7fb89a", "#c9a86a", "#9f8ad0"],
            focusRingArcStart: "#9b8cf5", focusRingArcMid: "#b6aaf8", focusRingArcEnd: "#d8a8c8",
            focusRingTrack: "#2a2650",
            focusGlassCenter: "#262254", focusGlassEdge: "#1d1a40", focusGlassShadow: "#0c0a20",
            focusGlassHighlight: "#4a4488", focusColonMuted: "#6a5fae",
            glassSidebar: Qt.rgba(20 / 255, 18 / 255, 42 / 255, 0.65),
            glassCard: Qt.rgba(32 / 255, 30 / 255, 62 / 255, 0.74),
            glassDialog: Qt.rgba(26 / 255, 24 / 255, 52 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.22),
            wallpaperScrim: Qt.rgba(18 / 255, 16 / 255, 42 / 255, 0.32)
        },
        {
            id: "rainy", name: "雨夜窗景", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/rainy.png"),
            base: "#0f1622",
            surface: "#17202e", surfaceRaised: "#1e2938", surfaceSunken: "#101823",
            border: "#33404f", borderSubtle: "#26313f",
            inkStrong: "#f0ebe2", ink: "#c9c3b6", inkSoft: "#8f8c84", inkMuted: "#6e6c66",
            accent: "#e8a34e", accentStrong: "#d9923c", accentSoft: "#3a3222", accentInk: "#f0b869",
            success: "#6fcf73", danger: "#e0705a", dangerBorder: "#d97f6c", dangerSoft: "#cc8a76",
            chartColors: ["#e8a34e", "#6f91b6", "#d97f6c", "#7fb89a", "#b9a0d0", "#8f8c84"],
            focusRingArcStart: "#efb268", focusRingArcMid: "#f4cfa0", focusRingArcEnd: "#d8a8a0",
            focusRingTrack: "#263143",
            focusGlassCenter: "#223040", focusGlassEdge: "#1a2534", focusGlassShadow: "#0b1119",
            focusGlassHighlight: "#3d4f63", focusColonMuted: "#8a7a5e",
            glassSidebar: Qt.rgba(16 / 255, 24 / 255, 38 / 255, 0.65),
            glassCard: Qt.rgba(26 / 255, 36 / 255, 52 / 255, 0.74),
            glassDialog: Qt.rgba(22 / 255, 31 / 255, 45 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.22),
            wallpaperScrim: Qt.rgba(15 / 255, 22 / 255, 34 / 255, 0.32)
        },
        {
            id: "moon", name: "月夜山影", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/moon.png"),
            base: "#0d1626",
            surface: "#14202f", surfaceRaised: "#1b2a3c", surfaceSunken: "#0e1722",
            border: "#2e415a", borderSubtle: "#223349",
            inkStrong: "#e9eff7", ink: "#c0cbd9", inkSoft: "#8494a6", inkMuted: "#64768c",
            accent: "#7fa8d9", accentStrong: "#6a94c8", accentSoft: "#27374e", accentInk: "#a8c8ec",
            success: "#6fcf73", danger: "#e0705a", dangerBorder: "#d97f6c", dangerSoft: "#cc8a76",
            chartColors: ["#7fa8d9", "#8494a6", "#d97f6c", "#7fb89a", "#b9a0d0", "#c9a86a"],
            focusRingArcStart: "#8fb4de", focusRingArcMid: "#b6cee8", focusRingArcEnd: "#c8b8d8",
            focusRingTrack: "#223349",
            focusGlassCenter: "#1f3044", focusGlassEdge: "#182636", focusGlassShadow: "#0a121c",
            focusGlassHighlight: "#37516b", focusColonMuted: "#5f7e9e",
            glassSidebar: Qt.rgba(12 / 255, 22 / 255, 38 / 255, 0.65),
            glassCard: Qt.rgba(20 / 255, 32 / 255, 50 / 255, 0.74),
            glassDialog: Qt.rgba(16 / 255, 27 / 255, 42 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.22),
            wallpaperScrim: Qt.rgba(13 / 255, 22 / 255, 38 / 255, 0.32)
        }
    ]
}
