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
}
