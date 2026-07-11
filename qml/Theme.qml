pragma Singleton
import QtQuick

// 全应用设计令牌的唯一来源。各 qml 通过相对目录导入后用 Theme.xxx 引用。
// 色相永远是暖纸家族；暗色壁纸下切到"夜间版"（米白墨水 + 暗暖玻璃），
// 只翻转明暗、不换色相。字号/间距/圆角为收敛后的比例阶梯。
QtObject {
    // 当前壁纸主题 id，由 MainWindow 绑定设置注入；决定明暗版式。
    property string activeThemeId: "warm"
    readonly property bool darkMode: resolveTheme(activeThemeId).mode === "dark"

    // —— 纸面 Surface ——
    readonly property color surface: darkMode ? "#2a241c" : "#fffef9"        // 主内容区底色
    readonly property color surfaceRaised: darkMode ? "#332c22" : "#faf6ee"  // 卡片/浮起块
    readonly property color surfaceSunken: darkMode ? "#211c15" : "#f5ede3"  // 输入框/次级容器

    // —— 边框 Border ——
    readonly property color border: darkMode ? "#4d4433" : "#e8dfc8"         // 主分隔线
    readonly property color borderSubtle: darkMode ? "#3a3327" : "#f0e6d2"   // 更弱的分隔

    // —— 文字 Ink（夜间版为暖米白系）——
    readonly property color inkStrong: darkMode ? "#f3ead9" : "#3d3327"      // 标题/强调
    readonly property color ink: darkMode ? "#e0d4bd" : "#5d4e37"            // 正文
    readonly property color inkSoft: darkMode ? "#b3a68c" : "#8b7355"        // 次要文字
    readonly property color inkMuted: darkMode ? "#8c8069" : "#a0896b"       // 占位/禁用

    // —— 强调 Accent（焦糖棕，两种明暗下同一色相）——
    readonly property color accent: "#d4a574"         // 基础态
    readonly property color accentStrong: "#c99666"   // 悬停/按下 深一档
    // 强调淡底/选中态：夜间版换成暗暖底，保持"淡淡一层强调"的语义。
    readonly property color accentSoft: darkMode ? "#4a3d2b" : "#f0e6d2"
    // accent 作前景文字不达 AA；accentInk 是"可读文字版"——浅底压深、暗底提亮。
    readonly property color accentInk: darkMode ? "#e6b980" : "#9c6a34"

    // —— 语义 Semantic（夜间版提亮一档保对比）——
    readonly property color success: darkMode ? "#6fcf73" : "#4caf50"
    readonly property color danger: darkMode ? "#e0705a" : "#b24f3d"
    readonly property color dangerBorder: darkMode ? "#d97f6c" : "#c46f5f"
    readonly property color dangerSoft: darkMode ? "#cc8a76" : "#b37562"

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

    // —— 数据色：饼图系列配色（夜间版整体提亮）——
    readonly property var chartColors: darkMode
        ? ["#d4a574", "#b3a68c", "#d97f6c", "#a8bd7e", "#8aa9c0", "#c9a0b5"]
        : ["#d4a574", "#8b7355", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"]

    // —— 专注页休息态强调色 ——
    // 直接复用 chartColors 的第 4 色（苔绿），不新增色相；语义是"休息强调色"。
    readonly property color focusBreakAccent: chartColors[3]

    // —— 专注计时环（玻璃表盘；弧光两版共用暖金系，盘面随明暗）——
    readonly property color focusRingArcStart: "#f1bd7e"   // 琥珀
    readonly property color focusRingArcMid: "#f4d3ab"     // 柔金
    readonly property color focusRingArcEnd: "#f4c3bd"     // 樱粉
    readonly property color focusRingTrack: darkMode ? "#3a3327" : "#faf1e8" // 底色轨道
    readonly property color focusGlassCenter: darkMode ? "#332c22" : "#fffefb"
    readonly property color focusGlassEdge: darkMode ? "#2a241c" : "#fdf3ee"
    readonly property color focusGlassShadow: darkMode ? "#171310" : "#e2b9a6"
    readonly property color focusGlassHighlight: darkMode ? "#4d4433" : "#ffffff"
    // 冒号只弱化颜色，不弱化字重；Space Grotesk 当前只打包 300/500/700 三档。
    readonly property color focusColonMuted: darkMode ? "#8c7355" : "#e8bda6"

    // —— 玻璃令牌（透壁纸磨砂面板；夜间版为暗暖玻璃）——
    // 白/暗暖 + alpha：面板叠在壁纸上，半透明才能透出壁纸。
    readonly property color glassSidebar: darkMode
        ? Qt.rgba(30 / 255, 26 / 255, 20 / 255, 0.55)
        : Qt.rgba(1, 1, 252 / 255, 0.55)
    readonly property color glassCard: darkMode
        ? Qt.rgba(38 / 255, 33 / 255, 25 / 255, 0.45)
        : Qt.rgba(1, 1, 250 / 255, 0.42)
    // 卡片/按钮悬停态：比 glassCard 实一档，仍透出壁纸。
    readonly property color glassHover: darkMode
        ? Qt.rgba(48 / 255, 42 / 255, 32 / 255, 0.65)
        : Qt.rgba(1, 1, 250 / 255, 0.62)
    // 选中态/高亮底：夜间版为焦糖的半透明高光。
    readonly property color glassAccent: darkMode
        ? Qt.rgba(212 / 255, 165 / 255, 116 / 255, 0.28)
        : Qt.rgba(240 / 255, 230 / 255, 210 / 255, 0.55)
    readonly property color glassDialog: darkMode
        ? Qt.rgba(42 / 255, 36 / 255, 28 / 255, 0.985)
        : Qt.rgba(1, 254 / 255, 249 / 255, 0.985)
    readonly property color glassBorder: darkMode
        ? Qt.rgba(1, 1, 1, 0.18)
        : Qt.rgba(1, 1, 1, 0.65)

    // ══ 背景壁纸主题（壁纸原图直出；mode 决定上方令牌走日间/夜间版）══
    // themes[0] 必须是默认 warm：resolveTheme 对未知 id 回落首位。
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
            base: "#f3e3cf"
        },
        {
            id: "pink", name: "粉色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/pink.png"),
            base: "#efc4d0"
        },
        {
            id: "jiangnan", name: "烟雨江南", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/jiangnan.png"),
            base: "#dfe8e2"
        },
        {
            id: "starry", name: "星空", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/starry.png"),
            base: "#12102a"
        },
        {
            id: "rainy", name: "雨夜窗景", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/rainy.png"),
            base: "#0f1622"
        },
        {
            id: "moon", name: "月夜山影", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/moon.png"),
            base: "#0d1626"
        }
    ]
}
