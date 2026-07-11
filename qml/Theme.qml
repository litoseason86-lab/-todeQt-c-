pragma Singleton
import QtQuick

// 全应用设计令牌的唯一来源。各 qml 通过相对目录导入后用 Theme.xxx 引用。
// 颜色为暖纸主题；字号/间距/圆角为收敛后的比例阶梯。
QtObject {
    // —— 纸面 Surface ——
    readonly property color surface: "#fffef9"        // 主内容区底色
    readonly property color surfaceRaised: "#faf6ee"  // 卡片/浮起块
    readonly property color surfaceSunken: "#f5ede3"  // 输入框/次级容器

    // —— 边框 Border ——
    readonly property color border: "#e8dfc8"         // 主分隔线
    readonly property color borderSubtle: "#f0e6d2"   // 更弱的分隔

    // —— 文字 Ink ——
    readonly property color inkStrong: "#3d3327"      // 标题/强调
    readonly property color ink: "#5d4e37"            // 正文
    readonly property color inkSoft: "#8b7355"        // 次要文字
    readonly property color inkMuted: "#a0896b"       // 占位/禁用

    // —— 强调 Accent（焦糖棕）——
    readonly property color accent: "#d4a574"         // 基础态
    readonly property color accentStrong: "#c99666"   // 悬停/按下 深一档
    // accentSoft 当前与 borderSubtle 恰好同值（#f0e6d2），但语义不同：
    // 一个是“强调淡底/选中态”，一个是“更弱的分隔线”。保留为两个独立令牌，
    // 将来想单独微调其一时不会牵连另一个，改色前请确认改的是哪个角色。
    readonly property color accentSoft: "#f0e6d2"     // 强调淡底/选中态
    // accent 作前景文字仅 2.2:1，远不达 WCAG。accentInk 是它的“可读文字版”——
    // 压深到在 surface/glassCard 上过 AA 正文 4.5:1，专供数字英雄与强调文字；
    // 装饰用途（环形进度、按钮填充、marker）仍用 accent。tst_theme_tokens 守门对比度。
    readonly property color accentInk: "#9c6a34"      // 强调文字/数字（AA 达标）

    // —— 语义 Semantic ——
    // success 沿用界面里既有的 Material 绿（#4caf50），本次只做令牌收敛、
    // 不调整其色相；若日后要把它调成更贴合暖纸的色调，改这一处即可全局生效。
    readonly property color success: "#4caf50"        // 完成/正向趋势
    readonly property color danger: "#b24f3d"         // 错误文字（暖陶土红）
    readonly property color dangerBorder: "#c46f5f"   // 错误输入框边框
    // 删除按钮专用：比 danger 更柔和的陶土色，用于“删除”这类不该过分刺眼的破坏性操作提示。
    readonly property color dangerSoft: "#b37562"

    // —— 投影 ——（纯黑；透明度由各效果自身属性控制）
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

    // —— 数据色：饼图系列配色（值不变，集中管理）——
    readonly property var chartColors: [
        "#d4a574", "#8b7355", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"
    ]

    // —— 专注页休息态强调色 ——
    // 直接复用 chartColors 的第 4 色（苔绿），不新增色相；语义是“休息强调色”，
    // 和图表配色场景无关，只是恰好复用同一个色值，避免专注页里出现裸索引 [3]。
    readonly property color focusBreakAccent: chartColors[3]

    // —— 专注计时环（玻璃表盘）——
    // 进度弧双色霞光渐变：只用于专注进行态；休息/完成态退化为状态语义单色。
    readonly property color focusRingArcStart: "#f1bd7e"   // 琥珀
    readonly property color focusRingArcMid: "#f4d3ab"     // 柔金
    readonly property color focusRingArcEnd: "#f4c3bd"     // 樱粉
    readonly property color focusRingTrack: "#faf1e8"      // 底色轨道
    // 玻璃内盘径向渐变与顶部高光；落影色在绘制时另配低透明度。
    readonly property color focusGlassCenter: "#fffefb"
    readonly property color focusGlassEdge: "#fdf3ee"
    readonly property color focusGlassShadow: "#e2b9a6"
    readonly property color focusGlassHighlight: "#ffffff"
    // 冒号只弱化颜色，不弱化字重；Space Grotesk 当前只打包 300/500/700 三档。
    readonly property color focusColonMuted: "#e8bda6"

    // —— 玻璃令牌（背景主题：磨砂面板，均衡档定稿）——
    // 用“白 + alpha”而非灰色：面板叠在彩色壁纸上，白基半透明才能透出壁纸色相。
    readonly property color glassSidebar: Qt.rgba(1, 1, 252 / 255, 0.55)
    readonly property color glassCard: Qt.rgba(1, 1, 250 / 255, 0.68)
    readonly property color glassDialog: Qt.rgba(1, 254 / 255, 249 / 255, 0.985)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.65)

    // —— 背景壁纸主题定义（唯一来源：画廊缩略图与壁纸层都读这里）——
    // 首位必须是默认暖纸：BackgroundWallpaper 对未知 id 回落 backgroundThemes[0]。
    // blobs 的 cx/cy/rx/ry 是相对窗口宽/高的比例，光晕由中心色淡出到全透明。
    readonly property var backgroundThemes: [
        { id: "warmPaper", name: "暖纸", motif: "windowLight", base: "#faf2e4", blobs: [
            { cx: 0.18, cy: 0.15, rx: 0.90, ry: 0.70, color: "#fdf3e0" },
            { cx: 0.85, cy: 0.25, rx: 0.80, ry: 0.60, color: "#f6e2c8" },
            { cx: 0.55, cy: 0.95, rx: 1.00, ry: 0.80, color: "#f2ded2" } ] },
        { id: "sunset", name: "暮橙", motif: "sunsetPeaks", base: "#fdeadb", blobs: [
            { cx: 0.15, cy: 0.10, rx: 0.85, ry: 0.70, color: "#ffe3c2" },
            { cx: 0.88, cy: 0.30, rx: 0.90, ry: 0.65, color: "#fbc9ad" },
            { cx: 0.50, cy: 1.00, rx: 1.10, ry: 0.75, color: "#f9d5c4" } ] },
        { id: "celadon", name: "青瓷", motif: "orchid", base: "#edf5ee", blobs: [
            { cx: 0.20, cy: 0.12, rx: 0.85, ry: 0.65, color: "#ddefe2" },
            { cx: 0.85, cy: 0.35, rx: 0.80, ry: 0.70, color: "#cde7dd" },
            { cx: 0.45, cy: 1.00, rx: 1.00, ry: 0.80, color: "#e3f1e4" } ] },
        { id: "mist", name: "晨雾", motif: "moonMist", base: "#f0eff7", blobs: [
            { cx: 0.18, cy: 0.15, rx: 0.85, ry: 0.65, color: "#e4e4f4" },
            { cx: 0.85, cy: 0.28, rx: 0.85, ry: 0.70, color: "#d7e2f3" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#ebe4f2" } ] },
        { id: "sakura", name: "樱粉", motif: "fallingPetals", base: "#fdf0f1", blobs: [
            { cx: 0.20, cy: 0.12, rx: 0.85, ry: 0.65, color: "#fbdbe2" },
            { cx: 0.85, cy: 0.30, rx: 0.85, ry: 0.70, color: "#f8e2ea" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#fceaea" } ] },
        { id: "wheat", name: "麦浪", motif: "goldenWaves", base: "#fbf5e2", blobs: [
            { cx: 0.18, cy: 0.12, rx: 0.85, ry: 0.65, color: "#f8edc6" },
            { cx: 0.85, cy: 0.32, rx: 0.85, ry: 0.70, color: "#f3e3b4" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#f9f0d2" } ] }
    ]

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
            surface: "#fffdf6", surfaceRaised: "#fbf5e9", surfaceSunken: "#f6ecdc",
            border: "#ead9bd", borderSubtle: "#f2e6cf",
            inkStrong: "#52422e", ink: "#6b573d", inkSoft: "#9c8266", inkMuted: "#b09a7d",
            accent: "#dc9550", accentStrong: "#c98240", accentSoft: "#f7e5c8", accentInk: "#9a6524",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#dc9550", "#9c8266", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#f1bd7e", focusRingArcMid: "#f4d3ab", focusRingArcEnd: "#f4c3bd",
            focusRingTrack: "#faf1e8",
            focusGlassCenter: "#fffefb", focusGlassEdge: "#fdf3ee", focusGlassShadow: "#e2b9a6",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#e8bda6",
            glassSidebar: Qt.rgba(1, 250 / 255, 242 / 255, 0.55),
            glassCard: Qt.rgba(1, 252 / 255, 246 / 255, 0.70),
            glassDialog: Qt.rgba(1, 252 / 255, 246 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.65)
        },
        {
            id: "pink", name: "粉色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/pink.png"),
            base: "#efc4d0",
            surface: "#fffbfc", surfaceRaised: "#fdf3f6", surfaceSunken: "#f9e9ee",
            border: "#eed3dc", borderSubtle: "#f6e3e9",
            inkStrong: "#573f4b", ink: "#6d525f", inkSoft: "#a37f8f", inkMuted: "#b697a4",
            accent: "#e5638f", accentStrong: "#d1517d", accentSoft: "#fadbe6", accentInk: "#b03e66",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#e5638f", "#a37f8f", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#f3a0bc", focusRingArcMid: "#f8cbd9", focusRingArcEnd: "#f4c3bd",
            focusRingTrack: "#fbecf1",
            focusGlassCenter: "#fffcfd", focusGlassEdge: "#fdf0f4", focusGlassShadow: "#e3a8bd",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#edb7c8",
            glassSidebar: Qt.rgba(1, 242 / 255, 246 / 255, 0.55),
            glassCard: Qt.rgba(1, 250 / 255, 252 / 255, 0.70),
            glassDialog: Qt.rgba(1, 250 / 255, 252 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.65)
        },
        {
            id: "jiangnan", name: "烟雨江南", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/jiangnan.png"),
            base: "#dfe8e2",
            surface: "#fbfdfc", surfaceRaised: "#f2f8f5", surfaceSunken: "#e8f1ec",
            border: "#cfe0d7", borderSubtle: "#e0ece5",
            inkStrong: "#39473f", ink: "#54655c", inkSoft: "#84948a", inkMuted: "#9daba2",
            accent: "#5f9e85", accentStrong: "#4f8b73", accentSoft: "#dcece3", accentInk: "#3e7d63",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#5f9e85", "#84948a", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#8fc4ae", focusRingArcMid: "#c0ddd0", focusRingArcEnd: "#b7d3c8",
            focusRingTrack: "#eaf3ee",
            focusGlassCenter: "#fdfffe", focusGlassEdge: "#f0f7f3", focusGlassShadow: "#b6cfc2",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#b9d2c6",
            glassSidebar: Qt.rgba(248 / 255, 252 / 255, 250 / 255, 0.55),
            glassCard: Qt.rgba(252 / 255, 254 / 255, 253 / 255, 0.70),
            glassDialog: Qt.rgba(252 / 255, 254 / 255, 253 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.65)
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
            glassSidebar: Qt.rgba(20 / 255, 18 / 255, 42 / 255, 0.55),
            glassCard: Qt.rgba(32 / 255, 30 / 255, 62 / 255, 0.62),
            glassDialog: Qt.rgba(26 / 255, 24 / 255, 52 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.14)
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
            glassSidebar: Qt.rgba(16 / 255, 24 / 255, 38 / 255, 0.55),
            glassCard: Qt.rgba(26 / 255, 36 / 255, 52 / 255, 0.62),
            glassDialog: Qt.rgba(22 / 255, 31 / 255, 45 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.14)
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
            glassSidebar: Qt.rgba(12 / 255, 22 / 255, 38 / 255, 0.55),
            glassCard: Qt.rgba(20 / 255, 32 / 255, 50 / 255, 0.62),
            glassDialog: Qt.rgba(16 / 255, 27 / 255, 42 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.14)
        }
    ]
}
