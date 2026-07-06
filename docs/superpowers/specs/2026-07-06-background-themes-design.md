# 背景主题（壁纸 + 磨砂面板 + 设置弹窗）设计文档

日期：2026-07-06
状态：视觉方案经可视化伴随逐屏确认，技术架构已确认

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
- 用 Canvas 绘制（FocusRing 已有 Canvas 先例）：`createRadialGradient` 只支持正圆，椭圆光晕通过 `ctx.save()` + `ctx.scale()` 变换实现；仅在窗口尺寸变化时重画，无每帧开销。
- 组件对外接口：`property string themeId`，内部按 id 从 Theme 取定义；未知 id 回落默认暖纸定义。

### 2. 磨砂层（Theme 新增玻璃令牌，无模糊管线）

关键简化：壁纸是低频柔和渐变，对其做背景模糊与不做在视觉上几乎无差别（模糊只对高频细节可见）。因此**面板直接用半透明白 + 细白描边即可得到 mockup 效果，不引入 ShaderEffectSource/MultiEffect 模糊管线**——零性能负担、零测试环境风险。

[Theme.qml](../../../qml/Theme.qml) 新增令牌（均衡档定稿值）：

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| `glassSidebar` | `Qt.rgba(1, 1, 252/255, 0.55)` | 侧栏底色 |
| `glassCard` | `Qt.rgba(1, 1, 250/255, 0.68)` | 视图顶层区块/卡片 |
| `glassDialog` | `Qt.rgba(1, 254/255, 249/255, 0.94)` | 弹窗面板（近实心，保证弹窗可读性） |
| `glassBorder` | `Qt.rgba(1, 1, 1, 0.65)` | 玻璃面板细白描边 |

### 3. 内容层改造（最终观感 = 区块浮在壁纸上）

- 侧栏（[Sidebar.qml](../../../qml/components/Sidebar.qml)）底色 → `glassSidebar` + `glassBorder` 描边。
- 六个视图根背景改透明；各视图的**顶层区块**（今日任务卡、专注计时区、统计卡片区等）底色 → `glassCard` + `glassBorder` 描边，区块之间露出壁纸。
- 各弹窗（AddTask/EditTask/Category/Countdown/Routine/Export/Settings）面板 → `glassDialog`。
- 区块**内部**的小元素（输入框、chip、次级容器、TaskItem 行）保持现有暖纸令牌不动——它们坐在玻璃卡片上观感成立，改动范围收住。
- Toast、CountdownBanner 本期不动。
- main.qml 窗口 `color: Theme.surface` 保留作壁纸未加载时的兜底色。

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

- 骨架同 AddTaskDialog（居中 Popup、磨砂面板 `glassDialog`、进出场动画、`pragma ComponentBehavior: Bound`）；
- 标题"设置"，栏目标签"背景主题"，2×3 画廊：每格 = 渐变缩略图（CSS 同源的三光晕渐变，Canvas 小尺寸绘制或直接复用 BackgroundWallpaper 缩小实例）+ 迷你磨砂条示意 + 名称；
- 选中态：焦糖描边（`Theme.accent`）+ 右上角对勾徽标；
- 点击缩略图 → `appSettings.backgroundTheme = id`（即切即存），无确认按钮，仅"关闭"；
- `property var appSettingsRef`，缺失时（测试/降级）画廊照常渲染、点击不写入。

**侧栏齿轮**：Sidebar 底部固定齿轮按钮，`signal settingsClicked`，MainWindow 接线打开弹窗。

## 错误处理

- 未知主题 id（将来删壁纸/手改配置文件）：BackgroundWallpaper 按 id 查不到定义时回落暖纸定义；AppSettings 不参与校验（避免 C++/QML 两处维护主题列表）。
- Canvas 在窗口 resize 时 `requestPaint()`；组件尺寸为 0 时跳过绘制（初始化瞬间的防御）。
- appSettings 上下文属性缺失（qmltestrunner 环境）：所有引用走 `typeof appSettings !== "undefined"` 守卫或 ref 注入，与现有模式一致。

## 测试策略

**C++（ServiceTests，AppSettings 部分）**：

- `backgroundTheme` 默认值为 `"warmPaper"`；
- set 后 get 返回新值且发 `backgroundThemeChanged`；
- 持久化：重建 AppSettings 实例后值保留。

**QML**：

- 主题定义完整性：`Theme.backgroundThemes` 恰 6 项、id 唯一、每项含 name/base/3 个 blob 且字段齐全；
- BackgroundWallpaper：`themeId` 设合法 id 后内部解析出的定义（暴露 `readonly property var resolvedTheme`）匹配；设非法 id 回落暖纸；
- SettingsDialog：画廊 Repeater 数量 = 6；点击第 n 格 → mock appSettings 收到正确 id；选中态绑定源（`appSettingsRef.backgroundTheme === modelData.id`）断言；
- 纪律：断言驱动属性，不断言 `visible === true`（项目既有教训）。

## 影响面与拆分建议

- C++：AppSettings（一个属性）。
- QML：Theme（令牌 + 主题定义）、新增 BackgroundWallpaper、新增 SettingsDialog、Sidebar（齿轮 + 玻璃化）、MainWindow（壁纸层 + 弹窗接线 + 主容器透明化）、六视图顶层区块玻璃化、六个既有弹窗面板换 `glassDialog`。
- 实施计划拆两份：
  - **计划一（基础设施 + 可切换壁纸）**：AppSettings 属性 → Theme 令牌与主题定义 → BackgroundWallpaper → MainWindow 接壁纸层 + 主容器过渡为整块 `glassCard` → Sidebar 玻璃化 + 齿轮 → SettingsDialog + 接线。独立可交付：壁纸可切换、侧栏与主面板已是玻璃。
  - **计划二（视图与弹窗玻璃化）**：主容器改透明，六视图根透明 + 顶层区块 `glassCard` 描边，六弹窗 `glassDialog`。交付最终"区块浮在壁纸上"观感。
