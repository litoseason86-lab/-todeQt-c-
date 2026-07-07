# 专注计时环重设计 — 设计文档

日期：2026-07-07
分支：ui-polish
状态：已批准，待实现

## 背景与目标

专注计时页（[qml/views/FocusView.qml](../../../qml/views/FocusView.qml)）番茄模式的计时环目前是一圈**扁平、等宽、单色**的焦糖棕描边，读感基础、缺乏质感，与用户偏好的 macOS 玻璃/通透美学不匹配。本次只做**视觉与材质升级**，把计时环重塑为一块「暖霞双色玻璃表盘」，并把过重的计时数字换成更秀气的排版，同时在设置里提供两种计时字体的切换。

**不改**状态机、按钮布局、模式切换、自由专注视图、计时服务逻辑——延续代码中既有原则：「玻璃化只换材质、不动布局」。

## 视觉定稿（可视化伴随过程结论）

经浏览器伴随多轮筛选，用户依次确定：

1. 方向：**A · 玻璃质感环**（相对 B 流光扫弧 / C 极简光晕）。
2. 精修味型：**A3 · 暖霞双色玻璃**（进度弧从琥珀渐融到樱粉，呼应壁纸）。
3. 明度档位：**L2 · 通透**（在 L1 微提亮 / L3 晨光之间的轻盈平衡点，解决「太暗压抑」）。
4. 数字排版：**T1 清瘦中黑(Medium 500)** 与 **T2 纤细(Light 300)** 两种都要，设置里可切换；**默认 T2 纤细**。

## 组件一：玻璃计时环（FocusRing）

### 契约保持不变
`FocusRing` 现为 `Canvas`（[FocusView.qml:416](../../../qml/views/FocusView.qml#L416)）。保持其**属性驱动**契约与全部 `objectName` 不变，状态机与测试零改动：

- 公开属性：`progress`、`ringColor`、`showPreview`、`dimmed`、`strokeWidth`（可微调）。
- 外部绑定源不变：`ringProgressFraction()`、`ringColorForState()`、`ringDimmed()`、`showPreview: root.state === "pomoIdle"`。
- `objectName: "focusRing"`、内部 `focusRingTimeText` / `ringCaptionText` 保留。

### 仅重写 onPaint 的绘制层次（由内到外）
1. **磨砂玻璃内盘**：半径约 `min(w,h)/2 - stroke - 内缩` 的圆，`createRadialGradient`（中心偏上：近白 → 暖奶油），带柔和落影（`ctx.shadowColor/shadowBlur/shadowOffsetY`），把盘从页面上「浮」起来。绘制盘时用完再清零 shadow，避免污染后续描边。
2. **顶部高光**：盘顶一条极淡的椭圆白色渐变（`shadowBlur` 归零后单独画），做出「受光玻璃」。
3. **底色轨道**：完整一圈淡暖环（新 token `focusRingTrack`，约 `#faf1e8`）。
4. **进度弧（双色发光）**：
   - 先画一遍**发光底**：同一路径、`shadowBlur` 一定量、略降 `globalAlpha`。
   - 再画**实弧**：从 12 点（-90°）顺时针画 `progress` 比例，`lineCap="round"`，描边用**沿弧线的线性渐变** `createLinearGradient`（起点近似弧起点、终点近似弧末点），三停：琥珀 `#f1bd7e` → 柔金 `#f4d3ab` → 樱粉 `#f4c3bd`。

### 状态语义映射（沿用现有，不新增状态）
- `showPreview`（pomoIdle 待机）：只画极淡完整轨道 + 顶部约 15° 强调弧预告，**不画进度弧**（保留现逻辑）。
- `dimmed`（暂停）：整体 `opacity` 降到约 0.38（保留 `Behavior on opacity`）。
- 休息态：`ringColor` 由 `ringColorForState()` 切成 `focusBreakAccent`；渐变可退化为该单色的双停或直接单色（休息不强调双色霞光）。
- 完成态：`ringProgressFraction()` 返回 1，弧合拢为满环，颜色 `Theme.success`（保留「三环合拢」庆祝语义）。

> 双色霞光渐变仅用于**专注进行态**（accent 系）；休息/完成态维持既有单色语义，避免语义混淆。

### 新增 Theme 令牌（集中管理，不硬编码）
在 [qml/Theme.qml](../../../qml/Theme.qml) 「专注页」区新增（值以最终 L2 定稿为准）：
- `focusRingArcStart` = `#f1bd7e`
- `focusRingArcMid` = `#f4d3ab`
- `focusRingArcEnd` = `#f4c3bd`
- `focusRingTrack` = `#faf1e8`
- `focusGlassCenter` = 近白（如 `#fffef9`）
- `focusGlassEdge` = 暖奶油（如 `#fdf3ee`）
- `focusGlassShadow` = 暖影色（如 `#e2b9a6`，配合低透明度）

## 组件二：计时数字排版 + 设置切换

### 两种字体样式
计时数字家族仍为 `Theme.fontFamilyClock`（"Space Grotesk"），通过 `font.weight` 选择已注册的对应 ttf：

- **T1 · 清瘦中黑**：`Font.Medium`(500)，字距微收（约 -0.5），冒号一档更淡更细。已打包，直接可用。
- **T2 · 纤细**：`Font.Light`(300)，字号略放大、字距略松，冒号更淡。**需新增打包** `SpaceGrotesk-Light.ttf`。
- 两种样式的冒号都比数字更淡（用一个偏浅的暖色，如比 `accentInk` 浅的调）。

数字主色维持 `accentInk` 级别可读度（AA 达标）；只降**字重**不降对比。

### 字体资源打包
- 新增文件 `resources/fonts/SpaceGrotesk-Light.ttf`。
- 在 [resources/fonts.qrc](../../../resources/fonts.qrc) 注册 alias。
- 在 [src/main.cpp:31](../../../src/main.cpp#L31) `bundledFonts` 列表加入该路径。
- 同一家族名下 300/500/700 共存，QML 请求对应 `font.weight` 即取到对应字重。

### 设置项
- **AppSettings** 新增属性 `slimClockFont`（bool，`QSettings` 持久化，带 `NOTIFY`），**默认 `true`（T2 纤细）**。
  - [src/services/AppSettings.h](../../../src/services/AppSettings.h)：`Q_PROPERTY` + getter/setter + signal。
  - [src/services/AppSettings.cpp](../../../src/services/AppSettings.cpp)：读写 `QSettings`，默认值 `true`。
- **FocusView** 读取 `root.settings.slimClockFont` → 计时数字 `font.weight` 取 `Font.Light` 或 `Font.Medium`；字号/字距随之切换。
- **SettingsDialog**（[qml/components/SettingsDialog.qml](../../../qml/components/SettingsDialog.qml)）在「偏好」分组新增一行开关：标题 **「纤细计时字体」**，副说明一行（如「更秀气的表盘数字；关闭则用更清晰的中黑」），复用现有开关行样式。

## 范围与约束

**In scope**：`FocusRing.onPaint` 玻璃绘制；新 Theme 令牌；FocusView 数字字重/冒号处理；`AppSettings.slimClockFont`（.h/.cpp）；SettingsDialog 开关行；打包 `SpaceGrotesk-Light.ttf`（qrc + main.cpp）。

**明确不动**：FocusView 状态机、按钮/模式标签布局、自由专注视图、FocusTimer 服务逻辑。

**约束**：
- 所有颜色走 Theme 令牌，禁止硬编码。
- 数字维持 AA 对比（`accentInk` 级）。
- 减动效（reduceMotion）不受影响——本次不新增动画，发光/高光为静态绘制。
- 保留全部 `objectName`，既有 QML 测试须继续通过。

## 测试

- 既有 `tests/qml/tst_focus_view.qml`、`tst_theme_tokens.qml`、`tst_settings_dialog.qml` 保持绿。
- 新增：`tst_theme_tokens` 对新玻璃/弧令牌的存在与（数字色）对比度断言。
- 新增：`tst_settings_dialog` 对「纤细计时字体」开关行的断言（触发切换 → `slimClockFont` 变化）。
- 新增：AppSettings 往返测试覆盖 `slimClockFont` 读写与默认值。
- **项目规则**：不断言 `item.visible===true`（本沙箱下不可靠、会级联）。

## 风险与取舍

- **Canvas 阴影污染**：`shadowBlur` 是 Canvas 全局态，画完盘/发光后必须清零，否则轨道与文字会带阴影。绘制顺序与清零点在实现计划里逐条落。
- **渐变方向近似**：Canvas 线性渐变沿弧起→弧末的直线取色，非严格 conic；对本弧长与配色，视觉足够，且实现更简单可测。
- **新字体家族名一致性**：`SpaceGrotesk-Light.ttf` 的家族名须与现有「Space Grotesk」一致，否则 `font.weight` 取不到 Light；打包后需实机确认落到 300 而非回退。
