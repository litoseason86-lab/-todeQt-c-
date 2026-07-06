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

    // —— 玻璃令牌（背景主题：磨砂面板，均衡档定稿）——
    // 用“白 + alpha”而非灰色：面板叠在彩色壁纸上，白基半透明才能透出壁纸色相。
    readonly property color glassSidebar: Qt.rgba(1, 1, 252 / 255, 0.55)
    readonly property color glassCard: Qt.rgba(1, 1, 250 / 255, 0.68)
    readonly property color glassDialog: Qt.rgba(1, 254 / 255, 249 / 255, 0.94)
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
}
