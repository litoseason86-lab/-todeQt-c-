# 排版身份（数字英雄字体系统）设计文档

日期：2026-07-07
状态：视觉方向经可视化伴随多屏确认（分工 A′：冷时钟 + 暖数据）；含一处对 mockup 的诚实修正

## 背景

frontend-design 设计主导视角审整体 UI 得出：app 的**色彩系统讲究**（暖纸 + 焦糖棕 + 玻璃 + 六张壁纸），但**排版零身份**——全用系统默认字，包括专注时要盯 25 分钟的 64px 计时数字。把仅剩的一处"大胆"押在排版上，是把"又一个暖色模板"变成"这个专属自习桌"的关键。

已确认方向（分工 A′）：

- **计时数字 → Space Grotesk（冷·几何无衬线）**：每秒跳动的倒计时是一块精确冷静的表盘；等宽数字不因字宽跳动。
- **统计数字 → Bricolage Grotesque（暖·当代无衬线）**：累积的努力与成果，暖的。
- **中文正文/标题 → 苹方（系统默认）不变**。
- 概念：**暖的自习桌 + 冷静精确的钟**，冷暖对比本身成为记忆点。

## 诚实修正：拉丁字体只对数字/拉丁字母可见

Bricolage / Space Grotesk 都是**纯拉丁字体，无中文字形**。给中文标题（"今日任务"）设这些字族，中文会回退到苹方、等于不生效——它们**只在数字和拉丁字母上可见**。

因此 mockup 里"页面大标题用 Bricolage"**不落地**：中文标题保持苹方。这套排版身份**由数字独家承载**——恰好回到最初"把英雄押在数字上"的主张，范围反而更收敛、风险更低。中文标题的存在感靠既有字号 + 字重（苹方 Semibold/Bold），不引入中文显示字库（避免 5–15MB 包体与授权问题）。

## 字体资产与加载

**打包字体**（均 SIL OFL，可商用嵌入；随源附 OFL 授权文件）。字重严格对齐既有应用位点的实际字重（下方核实），**不多打包一个用不上的字重、不改任何位点字重**：

| 文件 | 字重 | 服务于（该位点既有字重） |
| --- | --- | --- |
| `resources/fonts/SpaceGrotesk-Medium.ttf` | 500 | 侧栏专注状态时间（Sidebar 现为 `Font.Medium`） |
| `resources/fonts/SpaceGrotesk-Bold.ttf` | 700 | 专注页计时大字（FocusView 现为 `font.bold: true`） |
| `resources/fonts/BricolageGrotesque-Bold.ttf` | 700 | 统计卡数值 + 倒计时天数（现均为 `Font.Bold`） |

授权文件 `resources/fonts/OFL-SpaceGrotesk.txt`、`OFL-Bricolage.txt` 随仓库存档（不进 qrc）。**取消 ExtraBold**（无位点使用，删除避免"资产与用法矛盾"）。字体来源：Google Fonts 静态实例（OFL），实施时下载对应静态 ttf。

**资源打包**：新建 `resources/fonts.qrc`（独立于 qml.qrc，便于测试目标单独链接），内容原文：

```xml
<RCC>
    <qresource prefix="/">
        <file alias="fonts/SpaceGrotesk-Medium.ttf">fonts/SpaceGrotesk-Medium.ttf</file>
        <file alias="fonts/SpaceGrotesk-Bold.ttf">fonts/SpaceGrotesk-Bold.ttf</file>
        <file alias="fonts/BricolageGrotesque-Bold.ttf">fonts/BricolageGrotesque-Bold.ttf</file>
    </qresource>
</RCC>
```

`fonts.qrc` 同时加入 app 目标（`PomodoroTodo`，与 qml.qrc 并列）与字体守门测试目标（见测试策略）。

**加载机制**：`src/main.cpp` 在 `QGuiApplication` 构造后、`engine.load` 前，`#include <QFontDatabase>`，用 `QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/SpaceGrotesk-Medium.ttf"))` 等逐一注册三个 ttf；注册后全应用可按字族名引用。

注册失败（文件缺失/损坏）时 `addApplicationFont` 返回 -1：main.cpp 记一条 `qWarning` 但**不阻断启动**——字族名解析不到时 Qt 自动回退系统字，数字仍可读，只是失去身份（降级不开天窗）。

## Theme 字族令牌（唯一来源）

[Theme.qml](../../../qml/Theme.qml) 新增（字族名 = 字体家族名，非文件名）：

```qml
// 数字英雄字体（纯拉丁，仅对数字/拉丁可见；中文回退苹方，见设计文档）。
readonly property string fontFamilyClock: "Space Grotesk"     // 冷·计时数字
readonly property string fontFamilyData: "Bricolage Grotesque" // 暖·统计数字
```

不新增字重令牌：字重继续用 `font.weight: Font.Bold` 等既有内联写法（80 处，不重构）；字号继续用既有 `Theme.fontXxx`。

## 应用位点（精确映射，表外不动）

每处除加 `font.family` 外，还须**新增 objectName**（现有多为内部 `id` 或函数文本，外部 QML 测试用 `findChild` 找不到——测试入口必须先有名）：

| 文件:行 | 元素 | 新增 objectName | 现状字重 | 改为 |
| --- | --- | --- | --- | --- |
| [FocusView.qml:620-628](../../../qml/views/FocusView.qml#L620) | 自由专注大字 | `focusFreeTimeText` | `font.bold`(700) | 加 `font.family: Theme.fontFamilyClock` |
| [FocusView.qml:654-664](../../../qml/views/FocusView.qml#L654) | 环内计时读数 | `focusRingTimeText` | `font.bold`(700) | 加 `font.family: Theme.fontFamilyClock` |
| [Sidebar.qml:336-343](../../../qml/components/Sidebar.qml#L336) | 侧栏专注状态时间 | 已有 `sidebarStatus-<marker>`（专注项 marker=`专`→`sidebarStatus-专`），无需新增 | `Font.Medium`(500) | 加 `font.family: Theme.fontFamilyClock` |
| [StatCard.qml:84-91](../../../qml/components/StatCard.qml#L84) | 统计卡数值（value 与单位是**两个独立 Text**，无混排） | `statCardValue` | `Font.Bold`(700) | 加 `font.family: Theme.fontFamilyData` |
| [CountdownView.qml:124-131](../../../qml/views/CountdownView.qml#L124) | 倒计时天数大字（已核实 = `Math.abs(daysRemaining)` 纯数字） | `countdownHeroDays` | `Font.Bold`(700) | 加 `font.family: Theme.fontFamilyData` |

字重维持不变——上表"现状字重"正是打包三个 ttf 覆盖的字重集合（Space Grotesk 500+700、Bricolage 700），一一对应无缺无余。

**明确不动**（避免中文回退带来的不一致）：

- 所有页面中文标题（TodayTaskView:217、WeekPlanView:177、CountdownView:42 等 fontXxl 中文标题）、月/年混合标签（MonthGoalView:235）、任务文本；
- [CountdownBanner.qml:92](../../../qml/components/CountdownBanner.qml#L92) 天数横幅——已核实文本 = `dayText()` 返回 `"128天"`/`"已过期 128天"`，**含中文**，套拉丁字族会数字/汉字割裂，排除，留苹方；
- [WeekPlanView.qml:388](../../../qml/views/WeekPlanView.qml#L388) 的 `font.family: "Menlo"` 日期（既有等宽账本意图，本次不并入，保持独立）。

## 错误处理

- 字体注册失败：qWarning + 系统字回退，不阻断启动；
- 数字 Text 混入中文单位：拉丁字族只渲染数字段，中文自动回退苹方——同一 Text 内混排可接受（如"128"Bricolage +"分钟"苹方，StatCard 本就把数值与单位分成两个 Text，天然无混排问题）。

## 测试策略

**① C++ 字体资源自动守门（新目标 `FontAssetsTests`）**——堵住"qrc alias 写错 / ttf 漏进资源 / addApplicationFont 路径错 / 字族名与 Theme 令牌不符"这些 QML 测试与真机之外的盲区：

- 新增 `tests/FontAssetsTests.cpp`，`#include <QGuiApplication>`（QFontDatabase 需 GUI 实例；ServiceTests 是 QCoreApplication，不能复用）、`QTEST_MAIN` 用 QGuiApplication，`add_test` 环境设 `QT_QPA_PLATFORM=offscreen`（无弹窗）；
- 目标链接 `resources/fonts.qrc` + `Qt6::Gui Qt6::Test`；
- 断言，逐个字体：`QFile(":/fonts/SpaceGrotesk-Bold.ttf").exists()` 为真；`QFontDatabase::addApplicationFont(":/fonts/…")` 返回值 `!= -1`；
- **字族名一致性**：注册后 `QFontDatabase::families()` 必须包含 `"Space Grotesk"` 与 `"Bricolage Grotesque"`——直接钉死"ttf 实际家族名 == Theme 令牌字符串"，防止令牌写了 `"Space Grotesk"` 而字体家族其实是别的名字导致真机静默回退。

**② QML 令牌与应用（驱动属性断言，不做像素/渲染检查）**：

- Theme 令牌：`fontFamilyClock === "Space Grotesk"`、`fontFamilyData === "Bricolage Grotesque"`（扩展 `tst_theme_tokens.qml`）；
- 计时位点：`tst_focus_view.qml` 用 `findChild(view, "focusFreeTimeText")`/`"focusRingTimeText"` 断言 `font.family === Theme.fontFamilyClock`；
- 侧栏位点：`tst_sidebar_ui_optimization.qml` 用 `findChild(sidebar, "sidebarStatus-专")` 断言 `font.family === Theme.fontFamilyClock`（该 Text 恒存在，绑定与文本是否为空无关）；
- 数据位点：`tst_glass_components.qml`（已实例化 StatCard）用 `findChild(statCard, "statCardValue")` 断言 `font.family === Theme.fontFamilyData`；`tst_countdown_ui.qml`（若实例化 CountdownView）用 `findChild(..., "countdownHeroDays")` 断言 `=== Theme.fontFamilyData`；
- 说明：`font.family` 是绑定属性，QML 测试只验证令牌被正确应用；字体是否真加载由 ① 守门 + 真机确认。

## 无弹窗边界与真机验收

- **自动流程只跑无头命令**：`cmake --build build` + `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build`（AGENTS.md 已定"后台测试不弹窗"）。计划里所有自动步骤不得含 `open`。
- **人工视觉验收（仅当用户要求/需人眼确认时手动执行）**：`open /Applications/番茄Todo.app`（`cmake --build build` 已自动部署到 /Applications）。确认：专注页计时数字呈 Space Grotesk 冷感、统计卡与倒计时天数呈 Bricolage 暖感、中文标题仍苹方；启动日志无字体缺失 `qWarning`。
- **等宽不抖验收（人工，回应"Space Grotesk 非显式等宽"）**：让计时从 `25:00` 递减若干秒，观察数字**无左右抖动**。Space Grotesk 数字为表格数字设计（等宽），预期不抖；若真机观察到抖动，则给计时 Text 加 `font.features: { "tnum": 1 }`（Qt 6.9 支持）作为兜底——此项列为实施计划中"带条件的兜底步骤"。

## 影响面与拆分

- C++：main.cpp（注册三字体）、新增 `tests/FontAssetsTests.cpp`。
- 资源：`resources/fonts/`（三 ttf + 两授权）、新增 `resources/fonts.qrc`。
- 构建：CMakeLists——`fonts.qrc` 加入 app 目标；新增 `FontAssetsTests` 可执行 + `add_test`（Qt6::Gui/Test，环境 offscreen）。
- QML：Theme（两令牌）、FocusView（计时，两 objectName）、Sidebar（计时，复用现有 objectName）、StatCard（数据，一 objectName）、CountdownView（数据，一 objectName，纯数字天数）。CountdownBanner 排除。
- **单份实施计划**：Task 1 字体资产 + `fonts.qrc` + CMake 接线 + `FontAssetsTests` 守门（TDD：先红后绿）→ Task 2 main.cpp 注册三字体 → Task 3 Theme 两令牌 → Task 4 计时数字套 clock 字族（FocusView + Sidebar，加 objectName + QML 断言）→ Task 5 数据数字套 data 字族（StatCard + CountdownView，加 objectName + QML 断言）→ Task 6 全量无头回归 +（人工）真机视觉/等宽验收。
