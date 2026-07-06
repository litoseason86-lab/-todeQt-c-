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

**打包字体**（均 SIL OFL，可商用嵌入；随源附 OFL 授权文件）：

| 文件 | 用途 |
| --- | --- |
| `resources/fonts/SpaceGrotesk-Medium.ttf`（500） | 计时数字（环内待机/较小态） |
| `resources/fonts/SpaceGrotesk-Bold.ttf`（700） | 计时数字（专注页大字/侧栏状态） |
| `resources/fonts/BricolageGrotesque-Bold.ttf`（700） | 统计数字常规 |
| `resources/fonts/BricolageGrotesque-ExtraBold.ttf`（800） | 统计数字强调（大号） |
| `resources/fonts/OFL-SpaceGrotesk.txt` / `OFL-Bricolage.txt` | 授权文件（不进 qrc，随仓库存档） |

**加载机制**：`src/main.cpp` 在 `QGuiApplication` 构造后、`engine.load` 前，用 `QFontDatabase::addApplicationFont(":/fonts/<file>")` 逐一注册；注册后全应用可按字族名引用。四个 ttf 加进 [resources/qml.qrc](../../../resources/qml.qrc)（`<qresource prefix="/">` 下，alias `fonts/<file>`）。

注册失败（文件缺失/损坏）时 `addApplicationFont` 返回 -1：main.cpp 记一条 `qWarning` 但**不阻断启动**——字族名解析不到时 Qt 自动回退系统字，数字仍可读，只是失去身份（背景永不开天窗式的降级）。

## Theme 字族令牌（唯一来源）

[Theme.qml](../../../qml/Theme.qml) 新增（字族名 = 字体家族名，非文件名）：

```qml
// 数字英雄字体（纯拉丁，仅对数字/拉丁可见；中文回退苹方，见设计文档）。
readonly property string fontFamilyClock: "Space Grotesk"     // 冷·计时数字
readonly property string fontFamilyData: "Bricolage Grotesque" // 暖·统计数字
```

不新增字重令牌：字重继续用 `font.weight: Font.Bold` 等既有内联写法（80 处，不重构）；字号继续用既有 `Theme.fontXxx`。

## 应用位点（精确映射，表外不动）

| 文件:行 | 元素 | 现状 | 改为 |
| --- | --- | --- | --- |
| [FocusView.qml:623-628](../../../qml/views/FocusView.qml#L623) | 自由专注大字 `primaryTimeText` | 苹方 fontDisplay Bold accent | 加 `font.family: Theme.fontFamilyClock` |
| [FocusView.qml:654-664](../../../qml/views/FocusView.qml#L654) | 环内计时读数 `primaryTimeText` | 苹方 (42/56/64) Bold | 加 `font.family: Theme.fontFamilyClock` |
| [Sidebar.qml:331](../../../qml/components/Sidebar.qml#L331) | 侧栏专注状态时间 `statusTimeText` | 苹方 fontSm accent | 加 `font.family: Theme.fontFamilyClock` |
| [StatCard.qml:85-91](../../../qml/components/StatCard.qml#L85) | 统计卡数值 `valueText`（value 与单位是**两个独立 Text**，无混排） | 苹方 fontXxl Bold | 加 `font.family: Theme.fontFamilyData` |
| [CountdownView.qml:124-131](../../../qml/views/CountdownView.qml#L124) | 倒计时天数大字（已核实文本 = `Math.abs(daysRemaining)`，**纯数字**） | 苹方 fontDisplay | 加 `font.family: Theme.fontFamilyData` |

**明确不动**（避免中文回退带来的不一致）：

- 所有页面中文标题（TodayTaskView:217、WeekPlanView:177、CountdownView:42 等 fontXxl 中文标题）、月/年混合标签（MonthGoalView:235）、任务文本；
- [CountdownBanner.qml:92](../../../qml/components/CountdownBanner.qml#L92) 天数横幅——已核实文本 = `dayText()` 返回 `"128天"`/`"已过期 128天"`，**含中文**，套拉丁字族会数字/汉字割裂，排除，留苹方；
- [WeekPlanView.qml:388](../../../qml/views/WeekPlanView.qml#L388) 的 `font.family: "Menlo"` 日期（既有等宽账本意图，本次不并入，保持独立）。

## 错误处理

- 字体注册失败：qWarning + 系统字回退，不阻断启动；
- 数字 Text 混入中文单位：拉丁字族只渲染数字段，中文自动回退苹方——同一 Text 内混排可接受（如"128"Bricolage +"分钟"苹方，StatCard 本就把数值与单位分成两个 Text，天然无混排问题）。

## 测试策略

**QML（驱动属性断言，不做像素/字体渲染检查）**：

- Theme 令牌：`fontFamilyClock === "Space Grotesk"`、`fontFamilyData === "Bricolage Grotesque"`（扩展 `tst_theme_tokens.qml`）；
- 应用位点：`tst_focus_view.qml` 断言计时 Text 的 `font.family === Theme.fontFamilyClock`；StatCard 测试（`tst_glass_components.qml` 已实例化 StatCard）断言 `valueText.font.family === Theme.fontFamilyData`；Sidebar 状态时间同理；
- 说明：`font.family` 是绑定属性，字体是否真正加载/渲染由 main.cpp 注册决定，测试只验证令牌被正确应用（字体注册与观感靠真机冒烟）。

**真机冒烟**：`cmake --build build && open /Applications/番茄Todo.app`——专注页计时数字呈 Space Grotesk 冷感、统计卡数字呈 Bricolage 暖感、中文标题仍苹方；启动无字体缺失告警。

## 影响面与拆分

- C++：main.cpp（注册四字体）。
- 资源：resources/fonts/（四 ttf + 两授权）、resources/qml.qrc（四条注册）。
- QML：Theme（两令牌）、FocusView（计时）、Sidebar（计时）、StatCard（数据）、CountdownView（数据，纯数字天数）。CountdownBanner 排除。
- **单份实施计划**：Task 1 字体资产 + 注册 + qrc（真机可见字体生效）→ Task 2 Theme 令牌 → Task 3 计时数字套 clock 字族（FocusView + Sidebar）→ Task 4 统计/倒计时数字套 data 字族（StatCard + CountdownView）→ Task 5 全量回归 + 冒烟。每个数字批次含真机视觉确认。
