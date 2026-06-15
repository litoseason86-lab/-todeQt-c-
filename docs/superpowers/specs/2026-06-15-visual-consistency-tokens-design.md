# 整体视觉一致性 · 设计令牌化（Theme 单例）设计

- 日期：2026-06-15
- 范围：UI 视觉一致性
- 目标尺度：统一令牌 + 适度精调（不改暖纸主题风格，不重排布局）

## 背景与问题

全量扫描 `qml/` 后发现：暖纸质主题在**理念上**统一，但在**执行上**已漂移，且**没有任何主题/设计令牌单例**——所有数值硬编码、散落在 21 个 qml 文件里。

具体漂移：

- **强调色**：同一个「焦糖棕」写成了 9 个近似值（`#d4a574` ×51、`#d9a574`、`#c99666` ×7、`#c9956e`、`#c8955f`、`#be8568`、`#b9854f` 等）。
- **文字色**：6 种近似墨色（`#3d3327` `#5d4e37` `#6d5e47` `#7a5544` `#8b7355` `#9d7556`）。
- **背景**：7 种近似纸面色（`#fffef9` `#fffaf1` `#faf8f3` `#faf6ee` `#f5ede3` `#f5f0e6` 等）。
- **边框**：6 种近似边框色（`#e8dfc8` ×63 为主，另有 `#eee2c9` `#ede5d4` `#f0e6d2` `#ded1b5` `#ddd4bb`）。
- **字号**：11 个零散 `pixelSize`（10/11/12/13/14/15/16/18/20/24/28），其中 13/14/15 几乎等效。
- **圆角**：8 个值（1/2/3/4/5/6/8/10）。
- **间距**：17 个值（2/3/4/5/6/8/10/12/14/16/18/20/24/26/28/30）。
- **冷灰侵入**：`#777777` `#bdbdbd` `#e0e0e0` `#000000` 等冷灰与暖纸主题不协调。

后果：维护时「改一处漏一处」，同级元素颜色/大小对不齐，视觉一致性随迭代持续退化。

## 目标 / 非目标

**目标**

- 引入一个 QML 单例 `Theme`，把散落的颜色/字号/间距/圆角收敛成一套**命名的设计令牌**，全应用引用同一来源。
- 迁移过程中顺手修掉明显不协调处（适度精调）。
- 保持暖纸主题整体观感不变。

**非目标（本次不做）**

- 不重新设计调色板、不改整体风格。
- 不重排布局、不加新动效、不改交互逻辑。
- 不碰 `src/services` / `src/models` 业务分层。
- 不收敛「数据色」：饼图系列色、用户自定义分类色保持原样。

## 令牌定义

### 颜色（16 个语义令牌）

| 令牌 | 取值 | 用途 / 合并来源 |
|---|---|---|
| `surface` | `#fffef9` | 主内容区底色 |
| `surfaceRaised` | `#faf6ee` | 卡片 / 浮起块（合并 `#faf8f3` `#fffaf1`） |
| `surfaceSunken` | `#f5ede3` | 输入框 / 次级容器（合并 `#f5f0e6`） |
| `border` | `#e8dfc8` | 主分隔线 / 边框（最常用） |
| `borderSubtle` | `#f0e6d2` | 更弱的分隔（合并 `#eee2c9` `#ede5d4` `#ddd4bb` `#ded1b5`） |
| `inkStrong` | `#3d3327` | 标题 / 强调文字 |
| `ink` | `#5d4e37` | 正文（最常用） |
| `inkSoft` | `#8b7355` | 次要文字 |
| `inkMuted` | `#a0896b` | 占位 / 禁用（替换冷灰 `#777` `#bdbdbd` `#e0e0e0`，合并 `#9d7556`） |
| `accent` | `#d4a574` | 主强调（合并那 9 个近似焦糖棕） |
| `accentStrong` | `#c99666` | hover / 按下 深一档 |
| `accentSoft` | `#f0e6d2` | 强调色淡底 / 选中态 |
| `success` | `#4caf50` | 完成 / 正向趋势 |
| `danger` | `#b24f3d` | 错误文字（暖陶土红） |
| `dangerBorder` | `#c46f5f` | 错误输入框边框 |
| `shadow` | `#00000020` | 投影（替换裸 `#000000` + 透明度） |

> 注：`accentSoft` 与 `borderSubtle` 当前同为 `#f0e6d2`，语义不同（一个是强调淡底、一个是弱分隔），保留为两个令牌，便于将来独立微调。

### 数据色（不收敛，保留为数组 / 用户数据）

- `chartColors`：`["#d4a574", "#8b7355", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"]`——饼图系列色（[ChartPie.qml:17](../../qml/components/ChartPie.qml)）。前两项可引用 `accent` / `inkSoft`，后四项为专用数据色。
- 用户自定义**分类色**（存数据库）完全不动。

### 字号（6 档 + 1 特例）

| 令牌 | 取值 | 用途 / 合并来源 |
|---|---|---|
| `fontXs` | 11 | 标签 / 角标 / 时间戳 |
| `fontSm` | 12 | 次要说明 |
| `fontMd` | 13 | 正文（默认，最常用） |
| `fontLg` | 15 | 小标题 / 强调（合并 14） |
| `fontXl` | 18 | 区块标题（合并 16 / 20） |
| `fontXxl` | 24 | 页面标题（合并 28） |
| `fontDisplay` | 64 | 倒计时大数字（特例，按原值） |

### 间距（6 档 + 1 特例，4/8 栅格）

| 令牌 | 取值 | 合并来源 |
|---|---|---|
| `space4` | 4 | — |
| `space8` | 8 | 合并 6 |
| `space12` | 12 | 合并 10 / 14 |
| `space16` | 16 | 最常用，合并 18 / 20 |
| `space24` | 24 | 合并 26 / 28 / 30 |
| `space32` | 32 | 大区块留白 |
| `hairline` | 2 | 仅用于 1~2px 极细分隔 |

### 圆角（3 档）

| 令牌 | 取值 | 用途 / 合并来源 |
|---|---|---|
| `radiusSm` | 4 | 小元素（合并 1 / 2 / 3 / 5） |
| `radiusMd` | 6 | 卡片 / 按钮 |
| `radiusLg` | 8 | 大卡片（合并 10） |

## 架构

- 新建 `qml/Theme.qml`：`pragma Singleton` 的 `QtObject`，以 `readonly property` 暴露上述全部令牌及 `chartColors` 数组。
- **注册**（计划阶段最终敲定）：新建 `qml/qmldir`，内容 `singleton Theme Theme.qml`，把 `qml/qmldir` 与 `qml/Theme.qml` 一并加入 `resources/qml.qrc`。各 qml 通过**相对目录导入**使用：组件/视图 `import ".."`、`qml/` 根下文件 `import "."`、测试 `import "../../qml"`。
  - 之所以不用 `main.cpp` 里的 `qmlRegisterSingletonType`：QML 测试由 `qmltestrunner` 运行（见 [CMakeLists.txt](../../CMakeLists.txt) 的 `PomodoroTodoQmlTests`），不经过 `main.cpp`，C++ 注册对测试与被测组件不可见。相对导入 + qmldir 对应用（走 qrc）和测试（走文件系统）都生效，且 `main.cpp` 完全不用改。
- 使用方式：`color: Theme.accent`、`font.pixelSize: Theme.fontMd`、`radius: Theme.radiusMd`、`spacing: Theme.space16`。
- 令牌全部是 UI 常量，留在 QML 层，**不进入 C++ 业务分层**。

## 分阶段迁移

遵守 AGENTS.md「先框架 → 逐模块 → 统一检查」。每个阶段独立可编译、可运行，互不混入。

1. **阶段一 · 骨架**：创建 `Theme.qml`（仅令牌定义）+ main.cpp 注册 + 加入 qrc。不改任何视图，确认能编译、`import App` 可用。
2. **阶段二 · 基础组件**：迁移 StatCard / TaskItem / Sidebar / ColorPicker / AddTaskDialog / CategoryDialog / CountdownDialog / ExportDialog / CountdownBanner / CountdownItem。
3. **阶段三 · 视图**：迁移 TodayTaskView / FocusView / WeekPlanView / MonthGoalView / StatisticsView / CountdownView。
4. **阶段四 · 主壳与图表**：迁移 MainWindow.qml + ChartBar / ChartPie（含 `chartColors`）。
5. **阶段五 · 统一检查**：`grep` 残留硬编码色号 → qmllint → 构建 → 跑测试。

## 适度精调清单（迁移时顺手修，不改暖纸风格）

- 趋势下降的纯红 `#f44336` → 暖陶土 `danger #b24f3d`，与其它错误色统一（红绿趋势区分保留，仅红变暖）。
- 冷灰 `#777` / `#bdbdbd` / `#e0e0e0` → 暖 `inkMuted` / `border`，消除发冷的违和感。
- 同级文字中 13/14/15 混用处对齐到同一档。
- 间距中的一次性值（26/28/30 等）对齐到栅格。

## 验证

- **构建**：`cmake --build build` 通过。
- **测试**：`ctest --test-dir build --output-on-failure` 全绿（现有 C++ 与 QML UI 测试不回归）。
- **静态检查**：`pyside6-qmllint` 对迁移过的文件无新增告警。
- **残留扫描**：阶段五用 `grep` 确认 chrome 色号（accent/ink/border/surface 系）已无硬编码残留；数据色（chartColors、分类色）按设计保留。
- **人工目测**：六个视图 + 各对话框逐屏对照，确认观感与迁移前一致（仅精调项有预期内的细微变化）。

## 风险与边界

- **观感漂移**：合并近似背景/边框会让个别区域颜色有极细微变化，属预期；阶段五人工目测兜底。
- **单例注册**：qrc + 无 qml 模块 URI 的环境下，QML 单例注册有版本差异，实施时以 Qt 6.9.0 实际行为为准并验证 `import App` 可用。
- **数据色误伤**：迁移时须区分「chrome 色」与「数据色」，`chartColors` 和分类色不得被令牌替换。
