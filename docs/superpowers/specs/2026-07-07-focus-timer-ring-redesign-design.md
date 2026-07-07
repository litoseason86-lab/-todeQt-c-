# 专注计时环重设计 — 设计文档

日期：2026-07-07
分支：ui-polish
状态：已批准 + 已按代码评审补齐硬点，待写实现计划

## 背景与目标

专注计时页（[qml/views/FocusView.qml](../../../qml/views/FocusView.qml)）番茄模式的计时环目前是一圈**扁平、等宽、单色**的焦糖棕描边，读感基础、缺乏质感，与用户偏好的 macOS 玻璃/通透美学不匹配。本次只做**视觉与材质升级**，把计时环重塑为一块「暖霞双色玻璃表盘」，并把过重的计时数字换成更秀气的排版，同时在设置里提供两种计时字体的切换。

**不改**状态机、按钮布局、模式切换、计时服务逻辑——延续代码中既有原则：「玻璃化只换材质、不动布局」。自由专注视图的**布局与逻辑**同样不动；唯一例外见「组件二 · 作用域钉死」。

## 视觉定稿（可视化伴随过程结论）

经浏览器伴随多轮筛选，用户依次确定：

1. 方向：**A · 玻璃质感环**。
2. 味型：**A3 · 暖霞双色玻璃**（进度弧从琥珀渐融到樱粉，呼应壁纸）。
3. 明度：**L2 · 通透**（解决「太暗压抑」）。
4. 数字排版：**T1 清瘦中黑(Medium 500)** 与 **T2 纤细(Light 300)** 两种都要，设置可切换；**默认 T2 纤细**。

---

## 组件一：玻璃计时环（FocusRing）

### 契约保持不变
`FocusRing` 现为 `Canvas`（[FocusView.qml:416](../../../qml/views/FocusView.qml#L416)）。保持其**属性驱动**契约与全部 `objectName` 不变，状态机零改动：公开属性 `progress`、`ringColor`、`showPreview`、`dimmed`；外部绑定源 `ringProgressFraction()`、`ringColorForState()`、`ringDimmed()`、`showPreview: root.state === "pomoIdle"` 全部不动。

### strokeWidth（次要问题·钉死）
`strokeWidth` 保持 **`readonly property real`（内部常量，不进外部契约）**；实现时其**数值**可从 16 调到 **14**（贴合 L2 定稿的较细弧）。即：值可微调，可见性与只读性不变，外部不得写入。

### onPaint 绘制层次（由内到外）
每一层用完即清理 Canvas 全局态（尤其 `shadowBlur`），避免污染后续描边/文字：

1. **磨砂玻璃内盘**：`ctx.save()` → 设 `shadowColor=focusGlassShadow`(见令牌，含 alpha)、`shadowBlur=14`、`shadowOffsetY=7`；用 `createRadialGradient`（中心偏上：`focusGlassCenter` → `focusGlassEdge`）填圆；`ctx.restore()` 清除阴影。
2. **顶部高光**：盘顶一条极淡椭圆白渐变（`focusGlassHighlight` 从 alpha .85 → 0），`shadowBlur` 已清零后单独画。
3. **底色轨道**：完整一圈 `focusRingTrack`，`lineWidth=strokeWidth`。
4. **进度弧发光底**：同弧路径，`lineWidth=strokeWidth+6`、`globalAlpha≈0.35`，用下面的弧渐变。（用加宽低透明底层做辉光，**不**用 Canvas 阴影，规避全局态污染。）
5. **进度弧实弧**：从 12 点（-90°）顺时针 `progress` 比例，`lineCap="round"`，描边用**沿弧起→弧末的线性渐变**（`createLinearGradient`）三停：`focusRingArcStart` → `focusRingArcMid` → `focusRingArcEnd`。

### 状态语义映射（沿用现有，不新增状态）
- **`showPreview`（pomoIdle 待机，次要问题·钉死）**：待机态**同样绘制玻璃内盘 + 顶部高光**（层 1、2），保证待机/运行材质一致、切换不跳变；差异**仅在弧**——待机只画极淡完整轨道 + 顶部约 15° 强调弧预告，**不画进度弧**（跳过层 4、5）。
- **`dimmed`（暂停）**：整体 `opacity` 降到约 0.38（保留 `Behavior on opacity`）。
- **休息态**：`ringColor` 经 `ringColorForState()` 切成 `focusBreakAccent`；此时弧渐变**退化为该单色**（双色霞光仅用于专注进行态，避免语义混淆）。
- **完成态**：`ringProgressFraction()` 返回 1，弧合拢为满环，颜色 `Theme.success`（保留「三环合拢」庆祝语义）。

### 新增 Theme 令牌（最终精确色值，集中于 [qml/Theme.qml](../../../qml/Theme.qml) 「专注页」区）
| 令牌 | 值 | 角色 |
|---|---|---|
| `focusRingArcStart` | `#f1bd7e` | 进度弧渐变·起（琥珀） |
| `focusRingArcMid` | `#f4d3ab` | 进度弧渐变·中（柔金） |
| `focusRingArcEnd` | `#f4c3bd` | 进度弧渐变·末（樱粉） |
| `focusRingTrack` | `#faf1e8` | 底色轨道 |
| `focusGlassCenter` | `#fffefb` | 玻璃盘径向渐变·中心 |
| `focusGlassEdge` | `#fdf3ee` | 玻璃盘径向渐变·边缘 |
| `focusGlassShadow` | `#e2b9a6` | 盘落影色（绘制时配 alpha≈0.15） |
| `focusGlassHighlight` | `#ffffff` | 顶部高光基色（绘制时配 alpha 渐变） |
| `focusColonMuted` | `#e8bda6` | 计时冒号淡化色（见组件二） |

> `focusColonMuted` 语义是「冒号弱化」，与 accent 系无关，独立令牌便于单独微调。

---

## 组件二：计时数字排版 + 设置切换

### 冒号弱化的实现方式（硬点·钉死）
现状 `focusRingTimeText` 是**单个 `Text` + `textFormat: Text.PlainText`**（[FocusView.qml:671](../../../qml/views/FocusView.qml#L671)），单 PlainText 无法让冒号单独变化。定案：

- **仍是单个 `Text`，`objectName: "focusRingTimeText"` 保留在这同一个 Text 上**（不拆 RowLayout、不迁移 objectName）。这样 `test_timeNumeralsUseClockFamily`（读 `ringText.font.family`）与未来测试都锚在同一层，不分裂。
- 将 `textFormat` 改为 **`Text.StyledText`**；`text` 由新 helper **`ringTimeMarkup()`** 生成：把 `primaryTimeText()`（番茄语境恒为单冒号 `MM:SS`）在 `":"` 处切开，包成 `parts[0] + '<font color="' + Theme.focusColonMuted + '">:</font>' + parts[1]`。
- **转义/防注入（评审补点）**：`ringTimeMarkup()` 先用 `/^[0-9:]+$/` 校验入参；不匹配、或不含恰好一个冒号，则**回落返回原始纯字符串**（不拼任何标签）。杜绝未来 `primaryTimeText()` 文案变化把 StyledText 搞出标签注入或显示异常。
- **冒号只弱化「颜色」，不弱化「字重」**。理由：Space Grotesk 仅打包 300/500/700 三档，向 StyledText span 请求中间字重会触发 Qt 合成，跨字体不可靠、且难自动守门；「更淡」的颜色已达到视觉上「更细」的观感。此项为对评审「更淡更细」的显式收敛。
- `font.family` 与 `font.weight` 仍作用于**整个 Text**（见下），故家族/字重测试不受 StyledText 影响。

### 两种字体样式（字重来源）
计时数字家族仍为 `Theme.fontFamilyClock`（"Space Grotesk"），通过整 Text 的 `font.weight` 选择已注册 ttf：
- **T1 · 清瘦中黑**：`Font.Medium`(500)，字距微收，冒号淡。已打包。
- **T2 · 纤细**：`Font.Light`(300)，字号略放大、字距略松，冒号淡。**需新增打包** `SpaceGrotesk-Light.ttf`。

`focusRingTimeText` 现有 `font.bold: true` 改为 `font.weight: root.settings && root.settings.slimClockFont ? Font.Light : Font.Medium`（移除 `font.bold`）。数字主色维持 `primaryTimeColor()`（`accentInk` 级，AA 达标）——只降字重不降对比。

### slimClockFont 作用域（硬点·钉死）
应用中有两个计时数字：番茄环 `focusRingTimeText`（[671](../../../qml/views/FocusView.qml#L671)）与自由专注 `focusFreeTimeText`（[635](../../../qml/views/FocusView.qml#L635)）。定案：

- **`slimClockFont` 同时决定两者的 `font.weight`**（Light↔Medium），使两个计时数字字重一致、不割裂。这是本项对「自由专注不动」的**唯一且明确的例外**：`focusFreeTimeText` 仅改一行 `font.weight`（同样把 `font.bold: true` 换成上面的三元），**其布局、颜色、`textFormat`、objectName 全不动**。
- **玻璃盘、顶部高光、双色弧、冒号弱化（StyledText）仅作用于番茄环**，不带入自由专注（自由专注为 `HH:MM:SS` 双冒号，且不在环内，保持 PlainText）。

### 字体资源打包
- 新增 `resources/fonts/SpaceGrotesk-Light.ttf`。
- 在 [resources/fonts.qrc](../../../resources/fonts.qrc) 注册 alias。
- 在 [src/main.cpp:31](../../../src/main.cpp#L31) `bundledFonts` 列表加入该路径。
- 同一家族名下 300/500/700 共存，QML 请求对应 `font.weight` 取到对应字重。

### AppSettings 新增属性
`slimClockFont`（bool，`QSettings` 持久化，带 `NOTIFY`），**默认 `true`（T2 纤细）**：
- [AppSettings.h](../../../src/services/AppSettings.h)：`Q_PROPERTY` + getter/setter + `slimClockFontChanged()`。
- [AppSettings.cpp](../../../src/services/AppSettings.cpp)：新增 key（如 `appearance/slimClockFont`），getter `value(key, true).toBool()`，setter 变更时 `setValue` 并发信号（沿用现有 soundEnabled 写法）。

### SettingsDialog 开关（硬点·钉死 objectName 契约）
复用现有 `PreferenceSwitchRow` 组件（[SettingsDialog.qml:421](../../../qml/components/SettingsDialog.qml#L421)）——它已内建「点整行 / 点开关都只切一次」的修复，避免重踩偏好点击坑。在「偏好」分组（`settingsPreferenceGroup`）内，减少动效行之后，加一条 `RowDivider` + 一行：

```qml
PreferenceSwitchRow {
    label: "纤细计时字体"
    caption: "更秀气的表盘数字；关闭则用更清晰的中黑"
    switchName: "settingsSlimClockFontSwitch"
    checkedValue: root.appSettingsRef ? root.appSettingsRef.slimClockFont : true
    onToggledTo: function (value) {
        if (root.appSettingsRef) { root.appSettingsRef.slimClockFont = value }
    }
}
```

该 `switchName` 经组件自动派生并**必须存在**以下 objectName（与 sound/motion 同模式）：
`settingsSlimClockFontSwitchRow`、`settingsSlimClockFontSwitchCaption`、`settingsSlimClockFontSwitch`(Switch 本体)、`settingsSlimClockFontSwitchTrack`、`settingsSlimClockFontSwitchThumb`。
同时新增分隔线 `objectName: "settingsPreferenceDividerSlimClock"`。

---

## 范围与约束

**In scope**：`FocusRing.onPaint` 玻璃绘制；9 个新 Theme 令牌；`focusRingTimeText` 改 StyledText + `ringTimeMarkup()` + 字重绑定；`focusFreeTimeText` 仅改字重一行；`AppSettings.slimClockFont`（.h/.cpp）；SettingsDialog 开关行 + 分隔线；打包 `SpaceGrotesk-Light.ttf`（qrc + main.cpp + FontAssets 守门）。

**明确不动**：FocusView 状态机、按钮/模式标签布局、自由专注布局/逻辑/颜色/textFormat、FocusTimer 服务逻辑。

**约束**：所有颜色走 Theme 令牌禁硬编码；数字维持 AA 对比；reduceMotion 不受影响（本次不新增动画，辉光/高光为静态绘制）；保留全部 `objectName`，既有 QML 测试须继续绿。

---

## 测试

### 既有须保持绿
`tst_focus_view`（含 `test_timeNumeralsUseClockFamily` 读 `focusRingTimeText.font.family`、`test_freeTimeNumeralUsesReadableInk`）、`tst_theme_tokens`、`tst_settings_dialog`、`FontAssetsTests`。

### 新增守门
1. **字重自动守门（硬点·钉死）**：现 [FontAssetsTests.cpp](../../../tests/FontAssetsTests.cpp) 只校验 family 名，错误的 Regular/Medium 文件只要 family 叫「Space Grotesk」也假绿。新增用例 `spaceGroteskLightRegistersAsSpaceGroteskLight()`：注册 `:/fonts/SpaceGrotesk-Light.ttf` → 取 `applicationFontFamilies(id)` 得**资源自身的 family**。**证据链主次（评审补点）**：以 `applicationFontFamilies(id)` 确认资源 family + `QFontInfo(QFont(resourceFamily, ptSize, QFont::Light)).weight()` 落在 Light 档为**主证据**；`QFontDatabase::styles(family)` 含 `"Light"` 仅作**辅助**，不作唯一证据——因为它查的是全局家族，开发机若已装系统版 Space Grotesk Light 会掩盖 qrc 塞错文件的问题（沿用本文件既有「用 id 作用域避免全局假绿」的原则）。
2. **Theme 令牌**：`tst_theme_tokens` 新增对 9 个新令牌存在性断言；对 `focusColonMuted` 与数字色不做对比度硬性要求（装饰性），但对数字主色维持既有 accentInk 断言。
3. **设置开关（硬点·钉死）**：`tst_settings_dialog` 新增：mock `slimClockFont`；(a) `mouseClick(settingsSlimClockFontSwitchRow, 8, h/2)` → `slimClockFont` 翻一次；(b) `mouseClick(settingsSlimClockFontSwitch)` → 再翻一次；(c) 缺 appSettings 时点击不崩不写。
4. **AppSettings 往返**：新增覆盖 `slimClockFont` 读写与**默认值 `true`**。

### 项目规则
不断言 `item.visible===true`（本沙箱下不可靠、会级联）。

---

## 风险与取舍
- **Canvas 阴影污染**：`shadowBlur` 是全局态；盘落影用 `save/restore` 包裹，弧辉光改用「加宽低透明底层」而非阴影，双重规避。绘制顺序与清零点在实现计划里逐条落。
- **渐变方向近似**：Canvas 线性渐变沿弧起→弧末直线取色，非严格 conic；对本弧长与配色视觉足够、实现更简单可测。
- **Light 家族名一致性**：`SpaceGrotesk-Light.ttf` family 名须为「Space Grotesk」，否则 `Font.Light` 取不到；新增的字重守门测试即为此兜底，打包后仍需实机确认落到 300 而非合成回退。
- **StyledText 兼容**：`focusRingTimeText` 转 StyledText 后仅 ring 语境使用（恒单冒号），markup 简单可控；自由专注保持 PlainText 不受影响。
