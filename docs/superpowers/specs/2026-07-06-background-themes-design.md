# 背景主题（壁纸 + 磨砂面板 + 设置弹窗）设计文档

日期：2026-07-06
状态：视觉方案经可视化伴随逐屏确认；技术架构经用户审阅后修订（v2：补 qrc、定拆分边界、玻璃化映射表、验收测试加硬）

## 背景

当前 app 的"背景"是一块纯色（[main.qml:15](../../../qml/main.qml#L15) `color: Theme.surface`），侧栏与内容区全部为不透明色块，没有背景层概念。用户希望背景美观化，并新增设置入口内置多个背景主题可切换。

已确认的设计决策（可视化伴随三屏 + 终端问答）：

- **视觉方向**：壁纸铺满窗口 + 半透明磨砂面板浮于其上（否决：仅换底色渐变——冲击有限；完整多主题系统——工程翻倍，深色模式留待独立立项）。
- **设置入口**：侧栏底部齿轮 → 居中设置弹窗（同 AddTaskDialog 模式）。本期弹窗只有"背景主题"一栏，框架通用，将来其他设置逐步收进来（否决：独立设置页——为一个切换器开整页偏重）。
- **色系范围**：第一期全浅色系，磨砂面板统一白玻璃，现有深棕文字令牌全部不动（否决：含深色壁纸——需面板/文字双套联动，半个暗色模式工程）。
- **壁纸**：6 张全部内置（暖纸/暮橙/青瓷/晨雾/樱粉/麦浪），默认「暖纸」（现观感的渐变版，老用户无缝过渡）。
- **磨砂通透度**：均衡档——侧栏 55% 白、卡片 68% 白。
- **切换交互**：画廊缩略图即点即切即持久化，无确认按钮。

## 渲染架构：三层结构

### 1. 壁纸层（新组件 `qml/components/BackgroundWallpaper.qml`）

- 铺在 MainWindow 最底层；每张壁纸 = 底色 + 3 个椭圆径向渐变光晕。
- 用 Canvas 绘制（FocusRing 已有 Canvas 先例）：`createRadialGradient` 只支持正圆，椭圆光晕通过 `ctx.save()` + `ctx.scale()` 变换实现。
- **噪点颗粒（执行期修正：整体退役）**：原设计让壁纸组件内叠 `paperTextureLayer` 同款 SVG 噪点 Image 延续纸感，但真机验证发现 `Image.Tile` + feTurbulence SVG 在浅色壁纸上渲染成肉眼可见的柱状拼接块。噪点层从壁纸组件移除、MainWindow 旧噪点层随透明化删除，纸感颗粒纹理整体退役；`tst_background_wallpaper.qml` 的 `test_noTiledNoiseTextureLayer` 守护不回潮。
- **重绘时机（接口行为，三条都必须实现）**：
  - `onThemeIdChanged: requestPaint()`——切主题必须触发重绘；
  - `onWidthChanged`/`onHeightChanged: requestPaint()`——窗口 resize 重画；
  - 宽或高 ≤ 0 时 `onPaint` 直接返回（初始化瞬间防御）。
- 对外接口：
  - `property string themeId`；
  - `readonly property var resolvedTheme`——按 id 从 `Theme.backgroundThemes` 解析出的定义；查不到时回落暖纸定义（回落逻辑的唯一所在，见"状态与设置"）；
  - `readonly property int paintCount`——每次 `onPaint` 实际绘制后自增，供测试断言"切主题触发了重绘"（驱动属性，不做像素级检查）。

### 2. 磨砂层（Theme 新增玻璃令牌，无模糊管线）

关键简化：壁纸是低频柔和渐变，对其做背景模糊与不做在视觉上几乎无差别（模糊只对高频细节可见）。因此**面板直接用半透明白 + 细白描边即可得到 mockup 效果，不引入 ShaderEffectSource/MultiEffect 模糊管线**——零性能负担、零测试环境风险。

[Theme.qml](../../../qml/Theme.qml) 新增令牌（均衡档定稿值）：

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| `glassSidebar` | `Qt.rgba(1, 1, 252/255, 0.55)` | 侧栏底色 |
| `glassCard` | `Qt.rgba(1, 1, 250/255, 0.68)` | 视图顶层区块/卡片 |
| `glassDialog` | `Qt.rgba(1, 254/255, 249/255, 0.94)` | 弹窗面板（近实心，保证弹窗可读性） |
| `glassBorder` | `Qt.rgba(1, 1, 1, 0.65)` | 玻璃面板细白描边 |

### 3. 内容层玻璃化映射表（计划二的完整执行清单）

六个视图的根都是无底色 `Item`（"根透明"天然成立），页面底色实际来自 MainWindow 的 `mainContentBackground`。逐文件映射如下——**不在表内的元素一律不动**（输入框、chip、TaskItem 行、按钮、次级容器等坐在玻璃面板上观感成立）：

| 文件 | 目标（objectName / 位置） | 现状 | 改为 |
| --- | --- | --- | --- |
| MainWindow.qml | `mainContentBackground` | `Theme.surface` | `"transparent"` |
| MainWindow.qml | `paperTextureLayer`（噪点 Image） | opacity 0.03 常驻 | 整块删除（噪点纹理退役：SVG 瓦片在壁纸上呈柱状拼接块，见壁纸层小节） |
| MainWindow.qml | `mainContentDivider`（1px 竖线） | `Theme.border` | 不动（细线压在壁纸上无碍） |
| TodayTaskView.qml | `todayTaskListContainer` | `Theme.surface` + `Theme.border` | 底色 → `glassCard`，边框 → `glassBorder` |
| components/StatCard.qml | 组件根 Rectangle（[StatCard.qml:31](../../../qml/components/StatCard.qml#L31)） | `Theme.surface` + `Theme.border` | 底色 → `glassCard`，边框 → `glassBorder`（一处改动同时覆盖今日页 2 卡 + 统计页 3 卡） |
| FocusView.qml | 整页底板 Rectangle（[FocusView.qml:491](../../../qml/views/FocusView.qml#L491)，`anchors.fill` 全页） | `Theme.surfaceSunken` | 底色 → `glassCard`（整页一块玻璃底板，**不改内部布局**——专注页刚重构过且状态机复杂，不做"中央列包卡"的结构手术） |
| WeekPlanView.qml | 星期脊柱（[WeekPlanView.qml:360](../../../qml/views/WeekPlanView.qml#L360)，52px 日期标签柱） | 今天=`accent` / 周末=`surfaceSunken` / 工作日=`surfaceRaised` | **不动**——day row 本体是无底色 RowLayout（行透明天然成立），脊柱是承载今天/周末语义的色标签，玻璃化会消解区分 |
| WeekPlanView.qml | 空日子占位块（[WeekPlanView.qml:402](../../../qml/views/WeekPlanView.qml#L402)） | `Theme.surfaceRaised` + `borderSubtle` | 底色 → `glassCard`，边框 → `glassBorder`（占位应比内容更轻；TaskItem 内容卡保持暖纸材质，属有意的层级差） |
| WeekPlanView.qml | 滚动条轨道（[WeekPlanView.qml:330](../../../qml/views/WeekPlanView.qml#L330)） | `Theme.surface` | `"transparent"`（透明化后不透明轨道会变成压在壁纸上的白条） |
| MonthGoalView.qml | 时间线内滚动条轨道（[MonthGoalView.qml:691](../../../qml/views/MonthGoalView.qml#L691)） | `Theme.surface` | `"transparent"`（同上） |
| MonthGoalView.qml | `monthCalendarContainer` | `Theme.surface` 卡片 | 底色 → `glassCard`，边框 → `glassBorder` |
| MonthGoalView.qml | `focusTimelinePanel` | `Theme.surface` 卡片 | 底色 → `glassCard`，边框 → `glassBorder` |
| components/ChartBar.qml | 组件根 Rectangle（[ChartBar.qml:21](../../../qml/components/ChartBar.qml#L21)） | `Theme.surfaceRaised` + `Theme.border` | 底色 → `glassCard`，边框 → `glassBorder`（覆盖统计页趋势图） |
| components/ChartPie.qml | 组件根 Rectangle（[ChartPie.qml:23](../../../qml/components/ChartPie.qml#L23)） | `Theme.surfaceRaised` + `Theme.border` | 底色 → `glassCard`，边框 → `glassBorder`（覆盖统计页科目分配图） |
| components/CountdownItem.qml | 组件根 Rectangle（[CountdownItem.qml:26](../../../qml/components/CountdownItem.qml#L26)） | `Theme.surfaceRaised`；hover 时边框 `border → accent` | 底色 → `glassCard`；hover 边框行为保留（倒计时页无外层大容器，卡片即顶层区块） |
| 7 个弹窗 | 各自 `background: Rectangle` 面板 | `surface`（AddTask:140 / EditTask:203 / Countdown:155）或 `surfaceRaised`（Category:193 / Routine:183 / Export:169） | 底色 → `glassDialog`（描边保留现状；Settings 是新组件、生而 glass，属计划一） |
| TodayTaskView.qml | `rolloverBanner` | `Theme.accentSoft` + `Theme.accent` 边框 | **不动**——它是逾期提醒的强调横幅，焦糖底就是它的语义，玻璃化会消解提醒强度 |
| components/Toast.qml、CountdownBanner.qml | — | — | 本期不动 |

**侧栏玻璃化（计划一，单独列出因有灰闪约束）**：

| 目标 | 现状 | 改为 |
| --- | --- | --- |
| Sidebar 根 Rectangle | 垂直渐变 `surfaceRaised → surfaceSunken` | 去掉 `gradient`，`color: Theme.glassSidebar` |
| SidebarItem idle 底色/边框色 | 不透明 `surfaceRaised`（注释明言不能用 `transparent`：ColorAnimation 从黑基透明插值会闪灰） | `Qt.rgba(1, 1, 1, 0)`——**白基透明**，与 hover 白色插值时 RGB 恒为白、只动 alpha，不经过灰，既守住防灰闪约束又露出玻璃 |
| SidebarItem hover 底色 | 不透明 `surfaceRaised` | `Qt.rgba(1, 1, 1, 0.45)` |
| SidebarItem active 底色/边框 | `accentSoft` / `accent` | 不动 |

## 主题定义（唯一来源：Theme.qml）

`Theme.qml` 新增 `readonly property var backgroundThemes`，设置弹窗画廊与壁纸层读同一份定义，不会两处失同步。每项结构：`{ id, name, base, blobs: [{cx, cy, rx, ry, color}] }`，坐标/半径为窗口宽高的比例值。定稿数据（与 mockup 一致）：

| id | 名称 | 底色 | 光晕 1 | 光晕 2 | 光晕 3 |
| --- | --- | --- | --- | --- | --- |
| `warmPaper` | 暖纸（默认） | `#faf2e4` | (0.18, 0.15, 0.90, 0.70) `#fdf3e0` | (0.85, 0.25, 0.80, 0.60) `#f6e2c8` | (0.55, 0.95, 1.00, 0.80) `#f2ded2` |
| `sunset` | 暮橙 | `#fdeadb` | (0.15, 0.10, 0.85, 0.70) `#ffe3c2` | (0.88, 0.30, 0.90, 0.65) `#fbc9ad` | (0.50, 1.00, 1.10, 0.75) `#f9d5c4` |
| `celadon` | 青瓷 | `#edf5ee` | (0.20, 0.12, 0.85, 0.65) `#ddefe2` | (0.85, 0.35, 0.80, 0.70) `#cde7dd` | (0.45, 1.00, 1.00, 0.80) `#e3f1e4` |
| `mist` | 晨雾 | `#f0eff7` | (0.18, 0.15, 0.85, 0.65) `#e4e4f4` | (0.85, 0.28, 0.85, 0.70) `#d7e2f3` | (0.50, 1.00, 1.00, 0.80) `#ebe4f2` |
| `sakura` | 樱粉 | `#fdf0f1` | (0.20, 0.12, 0.85, 0.65) `#fbdbe2` | (0.85, 0.30, 0.85, 0.70) `#f8e2ea` | (0.50, 1.00, 1.00, 0.80) `#fceaea` |
| `wheat` | 麦浪 | `#fbf5e2` | (0.18, 0.12, 0.85, 0.65) `#f8edc6` | (0.85, 0.32, 0.85, 0.70) `#f3e3b4` | (0.50, 1.00, 1.00, 0.80) `#f9f0d2` |

光晕四元组含义：(cx, cy, rx, ry)，均为相对窗口宽/高的比例；渐变从中心色到全透明。

## 状态与设置

**AppSettings 新属性**（沿用现有 Q_PROPERTY 模式）：

- `Q_PROPERTY(QString backgroundTheme READ backgroundTheme WRITE setBackgroundTheme NOTIFY backgroundThemeChanged)`；
- QSettings 键 `appearance/backgroundTheme`，默认 `"warmPaper"`；
- C++ 侧**只存取字符串、不做合法性校验**——若在 C++ 维护合法 id 列表，会与 Theme.qml 的主题定义形成两处维护，将来加壁纸忘改其一就静默失效。回落逻辑收敛到 QML 单一来源：BackgroundWallpaper 按 id 查不到定义即用暖纸（见错误处理）。存了未知 id 时画廊无选中项、壁纸显示暖纸，行为良性。

**设置弹窗（新组件 `qml/components/SettingsDialog.qml`）**：

- 骨架同 AddTaskDialog（居中 Popup、面板 `glassDialog`、进出场动画）；
- 标题"设置"，栏目标签"背景主题"，2×3 画廊；
- **缩略图定死为复用 `BackgroundWallpaper` 小尺寸实例**（`themeId` 属性即插即用，天然与壁纸层同源；不另造 ThemePreview、不用独立小 Canvas），缩略图内叠一条迷你磨砂 Rectangle（`glassCard`）示意玻璃效果，下方名称文字；
- 选中态：焦糖描边（`Theme.accent`）+ 右上角对勾徽标，绑定源 `appSettingsRef.backgroundTheme === modelData.id`；
- 点击缩略图 → `appSettingsRef.backgroundTheme = id`（即切即存），无确认按钮，仅"关闭"；
- `property var appSettingsRef`，缺失时（测试/降级）画廊照常渲染、点击不写入。

**侧栏设置入口（位置定稿）**：在 [Sidebar.qml](../../../qml/components/Sidebar.qml) 底部工具组内，「数据导出」SidebarItem **之后**、「三阶段」文字标签**之前**，新增一个 SidebarItem（text「设置」，marker「设」，复用既有条目样式与 hover 行为，不做独立齿轮 icon）；新增 `signal settingsRequested`，MainWindow 接线打开弹窗。「三阶段」标签保留不动。

## 资源注册（qml.qrc）

新增 QML 文件必须注册进 [resources/qml.qrc](../../../resources/qml.qrc)（该工程逐文件显式注册，漏注册则打包后的 app 在运行时找不到组件）：

- `<file alias="qml/components/BackgroundWallpaper.qml">../qml/components/BackgroundWallpaper.qml</file>`
- `<file alias="qml/components/SettingsDialog.qml">../qml/components/SettingsDialog.qml</file>`

两条都在**计划一**完成（两个新组件均属计划一）；计划二无新文件。实施计划中 qrc 注册为独立步骤，紧跟组件创建。

## 错误处理

- 未知主题 id（将来删壁纸/手改配置文件）：BackgroundWallpaper 按 id 查不到定义时回落暖纸定义；AppSettings 不参与校验（避免 C++/QML 两处维护主题列表）。
- Canvas 宽或高 ≤ 0 时跳过绘制；`onThemeIdChanged`/resize 必触发 `requestPaint()`（接口行为，见壁纸层小节）。
- appSettings 上下文属性缺失（qmltestrunner 环境）：所有引用走 `typeof appSettings !== "undefined"` 守卫或 ref 注入，与现有模式一致。

## 代码质量约束

- 新增组件（BackgroundWallpaper、SettingsDialog）要求 qmllint 零警告；含内联组件或引用外层 id 时按既有惯例加 `pragma ComponentBehavior: Bound`（EditTaskDialog 先例）。既有组件不做 lint 整改，不扩大战线。
- 注释遵守 AGENTS.md：解释为什么/边界（如白基透明的防灰闪理由必须写成注释留在 Sidebar 里，替换原注释）。

## 测试策略

**C++（ServiceTests，AppSettings 部分）**：

- `backgroundTheme` 默认值为 `"warmPaper"`；
- set 后 get 返回新值且发 `backgroundThemeChanged`；
- 持久化：重建 AppSettings 实例后值保留。

**QML——数据与行为**：

- 主题定义完整性：`Theme.backgroundThemes` 恰 6 项、id 唯一、每项含 name/base/3 个 blob 且字段齐全；
- BackgroundWallpaper：设合法 id 后 `resolvedTheme.id` 匹配；设非法 id 回落 `resolvedTheme.id === "warmPaper"`；
- BackgroundWallpaper 重绘：记录当前 `paintCount`，改 `themeId` 后 `tryVerify(paintCount 增加)`——直接守护"切主题必须重绘"这条接口行为；
- SettingsDialog：画廊 Repeater 数量 = 6；点击第 n 格 → mock appSettings 收到正确 id；选中态绑定源断言。

**QML——视觉验收（守护"壁纸别被盖住"这类核心失败）**：

- 计划一：Sidebar 根 `color === Theme.glassSidebar` 且 `gradient === null`；
- 计划二：`mainContentBackground.color` 为透明（`color.a === 0`）；FocusView 整页底板 `color === Theme.glassCard`；`todayTaskListContainer.color === Theme.glassCard`；StatCard 根 `color === Theme.glassCard`——逐条断言驱动属性，任何一个视图"仍是不透明块"都会红；
- 纪律：断言驱动属性/颜色值，不断言 `visible === true`（项目既有教训）；不做像素抓取（沙盒环境不可靠）。

## 影响面与拆分建议

- C++：AppSettings（一个属性）。
- 资源：resources/qml.qrc（两条注册，计划一）。
- QML：Theme（令牌 + 主题定义）、新增 BackgroundWallpaper、新增 SettingsDialog、Sidebar（玻璃化 + 设置条目）、MainWindow（壁纸层 + 弹窗接线；计划二再动 `mainContentBackground`/噪点层）、映射表所列六视图与组件、7 个弹窗。
- 实施计划拆两份，**边界以 `mainContentBackground` 为界、只动一次**：
  - **计划一（基础设施 + 可切换壁纸）**：AppSettings 属性 → Theme 令牌与主题定义 → BackgroundWallpaper（含噪点与重绘行为）→ qrc 注册 → MainWindow 接壁纸层 → Sidebar 玻璃化 + 设置条目 → SettingsDialog + 接线。**主内容区（`mainContentBackground`）保持现状不动**：本阶段壁纸只在侧栏区域透出，这是明确的过渡状态，不是缺陷。独立可交付：设置弹窗全流程可用、壁纸可切换且持久化。
  - **计划二（内容层玻璃化）**：`mainContentBackground` 改透明 + 删旧噪点层 → 按映射表逐文件玻璃化六视图与组件卡片 → 7 弹窗 `glassDialog` → 视觉验收测试。交付最终"区块浮在壁纸上"观感。
