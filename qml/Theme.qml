pragma Singleton
import QtQuick

// 全应用设计令牌的唯一来源。各 qml 通过相对目录导入后用 Theme.xxx 引用。
// 颜色为暖纸主题（固定不随壁纸变化）；字号/间距/圆角为收敛后的比例阶梯。
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

    // —— 玻璃令牌（磨砂面板，均衡档定稿）——
    // 用“白 + alpha”而非灰色：面板叠在彩色壁纸上，白基半透明才能透出壁纸色相。
    readonly property color glassSidebar: Qt.rgba(1, 1, 252 / 255, 0.55)
    readonly property color glassCard: Qt.rgba(1, 1, 250 / 255, 0.68)
    readonly property color glassDialog: Qt.rgba(1, 254 / 255, 249 / 255, 0.985)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.65)

    // ══ 背景壁纸主题（只换壁纸，UI 色值永远保持上方暖纸令牌）══
    // themes[0] 必须是默认 warm：resolveTheme 对未知 id 回落首位。
    // wallpaperScrim 是压在壁纸上的暖白纱：明亮壁纸 18% 防抢戏，
    // 暗色壁纸 30%——暖纸半透明面板叠在深色图上需要更多提亮保可读。
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

    readonly property var themes: [
        {
            id: "warm", name: "暖色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/warm.png"),
            base: "#f3e3cf",
            wallpaperScrim: Qt.rgba(1, 254 / 255, 249 / 255, 0.18)
        },
        {
            id: "pink", name: "粉色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/pink.png"),
            base: "#efc4d0",
            wallpaperScrim: Qt.rgba(1, 254 / 255, 249 / 255, 0.18)
        },
        {
            id: "jiangnan", name: "烟雨江南", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/jiangnan.png"),
            base: "#dfe8e2",
            wallpaperScrim: Qt.rgba(1, 254 / 255, 249 / 255, 0.18)
        },
        {
            id: "starry", name: "星空", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/starry.png"),
            base: "#12102a",
            wallpaperScrim: Qt.rgba(1, 254 / 255, 249 / 255, 0.30)
        },
        {
            id: "rainy", name: "雨夜窗景", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/rainy.png"),
            base: "#0f1622",
            wallpaperScrim: Qt.rgba(1, 254 / 255, 249 / 255, 0.30)
        },
        {
            id: "moon", name: "月夜山影", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/moon.png"),
            base: "#0d1626",
            wallpaperScrim: Qt.rgba(1, 254 / 255, 249 / 255, 0.30)
        }
    ]
}
