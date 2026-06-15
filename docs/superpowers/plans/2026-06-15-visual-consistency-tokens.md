# 整体视觉一致性 · 设计令牌化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把散落在 21 个 qml 文件里的硬编码颜色/字号/间距/圆角，收敛为一个 `Theme` QML 单例的命名令牌，全应用引用同一来源，并顺手修掉明显的冷暖/层级不协调。

**Architecture:** 新建 `qml/Theme.qml`（`pragma Singleton` 的 `QtObject`）+ `qml/qmldir`（声明单例），两者都加入 `resources/qml.qrc`。各 qml 通过**相对目录导入**使用令牌（组件/视图 `import ".."`、`qml/` 根下文件 `import "."`、测试 `import "../../qml"`）。这样应用（走 qrc）和 `qmltestrunner`（走文件系统）都能解析，且无需改动 `main.cpp` 或 C++ 层。

**Tech Stack:** Qt 6.9 / Qt Quick(QML) / CMake / qmltestrunner（QML 测试）/ `pyside6-qmllint`（静态检查）。

> **注册机制说明：** 设计 spec 里曾设想在 `main.cpp` 用 `qmlRegisterSingletonType` 注册。落实计划时发现 QML 测试由 `qmltestrunner` 运行（[CMakeLists.txt:150](../../CMakeLists.txt)），不经过 `main.cpp`，C++ 注册对测试不可见。因此最终采用 `qmldir` + 相对导入的纯 QML 方案。spec 已把注册细节留到本阶段敲定，二者不冲突。

---

## 通用命令（每个任务都会用到）

- **配置**（仅首次或 CMake 文件变更后）：
  `cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`
- **构建**：`cmake --build build`
- **全部测试**：`ctest --test-dir build --output-on-failure`
- **仅 QML 测试**（读源码 qml，无需重新构建即可反映 qml 改动）：
  `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
- **QML 静态检查**：`pyside6-qmllint <file>...`

---

## 替换映射表（权威参考，所有迁移任务以此为准）

迁移的核心动作：把下列**硬编码值**替换为对应 `Theme.*` 令牌。每个文件改完后，用 `grep` 确认这些 chrome 值已无残留。

### 颜色

| 硬编码值 | → 令牌 | 备注 |
|---|---|---|
| `#fffef9` | `Theme.surface` | |
| `#faf8f3` `#fffaf1` `#faf6ee` | `Theme.surfaceRaised` | 三个近似纸面合并 |
| `#f5ede3` `#f5f0e6` | `Theme.surfaceSunken` | |
| `#e8dfc8` | `Theme.border` | 最常用分隔线 |
| `#f0e6d2` `#eee2c9` `#ede5d4` `#ddd4bb` `#ded1b5` | `Theme.borderSubtle` **或** `Theme.accentSoft` | **按上下文判断**：分隔/描边 → `borderSubtle`；选中态/强调淡底 → `accentSoft`（二者当前同为 `#f0e6d2`） |
| `#3d3327` | `Theme.inkStrong` | |
| `#5d4e37` | `Theme.ink` | 正文 |
| `#6d5e47` `#7a5544` | `Theme.ink` | 近似深墨色归并到 ink |
| `#8b7355` | `Theme.inkSoft` | |
| `#a0896b` `#9d7556` | `Theme.inkMuted` | |
| `#d4a574` | `Theme.accent` | 按钮/控件基础态 |
| `#d9a574`（悬停态）`#c99666`（按下态） | `Theme.accentStrong` | 统一为「交互时深一档」，详见下方说明 |
| `#4caf50` | `Theme.success` | |
| `#b24f3d` | `Theme.danger` | |
| `#c46f5f` | `Theme.dangerBorder` | 错误输入框边框 |
| `#000000`（仅 `shadowColor`） | `Theme.shadow` | 纯黑；透明度仍由各效果自身属性控制 |

### 精调项（替换时一并处理）

- **冷灰 → 暖色**：`#777777` → `Theme.inkMuted`；`#bdbdbd` → `Theme.inkMuted`；`#e0e0e0` → `Theme.border`。
- **趋势下降纯红 → 暖红**：[StatCard.qml:151](../../qml/components/StatCard.qml) 的 `#f44336` → `Theme.danger`（红绿趋势区分保留，仅红变暖）。
- **按钮交互态统一**：原先 base `#d4a574` / 悬停 `#d9a574`（偏亮）/ 按下 `#c99666`（偏暗）三态，统一为 base `Theme.accent` + 悬停/按下 `Theme.accentStrong`。悬停由「变亮」改为「变暗」，是预期内的一致化精调。

### 字号

| 原 `pixelSize` | → 令牌 |
|---|---|
| 10 11 | `Theme.fontXs`（11） |
| 12 | `Theme.fontSm` |
| 13 | `Theme.fontMd` |
| 14 15 | `Theme.fontLg`（15） |
| 16 18 20 | `Theme.fontXl`（18） |
| 24 28 | `Theme.fontXxl`（24） |
| 64 | `Theme.fontDisplay` |

### 间距（`spacing` / `*Margin` / `Layout.*Margin` 等）

| 原值 | → 令牌 |
|---|---|
| 2 | `Theme.hairline` |
| 4 5 | `Theme.space4` |
| 6 8 | `Theme.space8` |
| 10 12 14 | `Theme.space12` |
| 16 18 20 | `Theme.space16` |
| 24 26 28 30 | `Theme.space24` |
| （> 30 的大留白） | `Theme.space32` |

> 间距收敛会让个别留白有 ±2~6px 的细微变化，属预期。

### 圆角（`radius`）

| 原值 | → 令牌 |
|---|---|
| 1 2 3 4 5 | `Theme.radiusSm`（4） |
| 6 | `Theme.radiusMd` |
| 8 10 | `Theme.radiusLg`（8） |

### 绝对不碰（数据色，非 chrome）

- [ColorPicker.qml:9-11](../../qml/components/ColorPicker.qml) 的 `colors` 数组（用户分类色预设）与 `selectedColor` 默认值。
- [ChartPie.qml:17](../../qml/components/ChartPie.qml) 的系列配色数组（迁到 `Theme.chartColors` 引用，但值不变，见 Task 11）。
- 任何来自 `categoryManagerRef`/数据库的分类色（运行期数据）。

---

## Task 1：创建 Theme 单例 + 注册 + TDD 验证

**Files:**
- Create: `qml/Theme.qml`
- Create: `qml/qmldir`
- Modify: `resources/qml.qrc`
- Test: `tests/qml/tst_theme_tokens.qml`

- [ ] **Step 1：先写失败测试**

创建 `tests/qml/tst_theme_tokens.qml`：

```qml
import QtQuick
import QtTest
import "../../qml"

// 验证 Theme 单例可被解析（注册生效），且核心令牌取值正确。
TestCase {
    name: "ThemeTokens"

    function test_colorTokens() {
        verify(Qt.colorEqual(Theme.accent, "#d4a574"), "accent 取值不对")
        verify(Qt.colorEqual(Theme.accentStrong, "#c99666"), "accentStrong 取值不对")
        verify(Qt.colorEqual(Theme.surface, "#fffef9"), "surface 取值不对")
        verify(Qt.colorEqual(Theme.border, "#e8dfc8"), "border 取值不对")
        verify(Qt.colorEqual(Theme.ink, "#5d4e37"), "ink 取值不对")
        verify(Qt.colorEqual(Theme.danger, "#b24f3d"), "danger 取值不对")
    }

    function test_scaleTokens() {
        compare(Theme.fontMd, 13)
        compare(Theme.fontXxl, 24)
        compare(Theme.space16, 16)
        compare(Theme.radiusMd, 6)
    }

    function test_chartColorsIsArray() {
        compare(Theme.chartColors.length, 6)
    }
}
```

- [ ] **Step 2：运行测试，确认失败**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL —— 形如 `Theme is not a type` 或单例无法解析（因为 Theme.qml / qmldir 尚未创建）。
（若 `build/` 还没配置过，先执行通用命令里的「配置」+「构建」。）

- [ ] **Step 3：创建 `qml/Theme.qml`**

```qml
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
    readonly property color accentSoft: "#f0e6d2"     // 强调淡底/选中态

    // —— 语义 Semantic ——
    readonly property color success: "#4caf50"
    readonly property color danger: "#b24f3d"
    readonly property color dangerBorder: "#c46f5f"

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
}
```

- [ ] **Step 4：创建 `qml/qmldir`**

```
singleton Theme Theme.qml
```

- [ ] **Step 5：把两个新文件加入 `resources/qml.qrc`**

在 `<qresource prefix="/">` 内、`main.qml` 那一行之前，加入：

```xml
        <file alias="qml/qmldir">../qml/qmldir</file>
        <file alias="qml/Theme.qml">../qml/Theme.qml</file>
```

- [ ] **Step 6：重新配置并构建（qrc 变更需要重新配置）**

Run:
```bash
cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos
cmake --build build
```
Expected: 构建成功，无报错。

- [ ] **Step 7：运行测试，确认通过**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS（含新的 `ThemeTokens` 用例，且原有 QML 测试不回归）。

- [ ] **Step 8：qmllint 新单例**

Run: `pyside6-qmllint qml/Theme.qml`
Expected: 无错误。

- [ ] **Step 9：提交**

```bash
git add qml/Theme.qml qml/qmldir resources/qml.qrc tests/qml/tst_theme_tokens.qml
git commit -m "新增 Theme 设计令牌单例与注册"
```

---

## Task 2：迁移基础组件 A —— Sidebar / StatCard / ColorPicker

**Files:**
- Modify: `qml/components/Sidebar.qml`
- Modify: `qml/components/StatCard.qml`
- Modify: `qml/components/ColorPicker.qml`

- [ ] **Step 1：三个文件顶部加导入**

在每个文件已有 `import` 之后，加一行：

```qml
import ".."
```

- [ ] **Step 2：按映射表替换 chrome 值**

逐个文件，将颜色/字号/间距/圆角的硬编码值替换为对应 `Theme.*`（见上方映射表）。
- StatCard：注意 `#f44336` → `Theme.danger`（精调项）。
- ColorPicker：**只改 chrome**（如 [ColorPicker.qml:30](../../qml/components/ColorPicker.qml) 的 `#5d4e37`→`Theme.ink`、[:51](../../qml/components/ColorPicker.qml) 的 `#e8dfc8`→`Theme.border`、[:76](../../qml/components/ColorPicker.qml) 的 `#fffef9`→`Theme.surface`）；**保留 `colors` 数组与 `selectedColor` 默认值不动**。

- [ ] **Step 3：qmllint 三个文件**

Run: `pyside6-qmllint qml/components/Sidebar.qml qml/components/StatCard.qml qml/components/ColorPicker.qml`
Expected: 无错误（Theme 能被解析）。

- [ ] **Step 4：跑 QML 测试，确认不回归**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS（含 `SidebarUiOptimization` 等现有用例）。

- [ ] **Step 5：grep 确认 chrome 残留已清**

Run（应只剩 ColorPicker 的 `colors` 数据数组与 selectedColor 默认值）：
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/components/Sidebar.qml qml/components/StatCard.qml qml/components/ColorPicker.qml
```
Expected: Sidebar / StatCard 无输出；ColorPicker 仅剩第 9-11 行的 `colors` 预设与第 7 行 `selectedColor` 默认值。

- [ ] **Step 6：提交**

```bash
git add qml/components/Sidebar.qml qml/components/StatCard.qml qml/components/ColorPicker.qml
git commit -m "令牌化基础组件 Sidebar/StatCard/ColorPicker"
```

---

## Task 3：迁移 TaskItem（最大组件，单独处理）

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1：顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换全部 chrome 值**

`TaskItem.qml`（637 行）颜色/字号/间距/圆角较多，逐处替换。注意按钮交互态（base/hover/pressed）按精调规则统一为 `accent`/`accentStrong`。

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/components/TaskItem.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/components/TaskItem.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/components/TaskItem.qml
git commit -m "令牌化 TaskItem"
```

---

## Task 4：迁移对话框 A —— AddTaskDialog / CategoryDialog

**Files:**
- Modify: `qml/components/AddTaskDialog.qml`
- Modify: `qml/components/CategoryDialog.qml`

- [ ] **Step 1：两文件顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换 chrome 值**

注意 AddTaskDialog 的错误态：`#c46f5f`→`Theme.dangerBorder`、`#b24f3d`→`Theme.danger`、`#d4a574`→`Theme.accent`；按钮三态统一（见精调）。`shadowColor: "#000000"` → `Theme.shadow`。CategoryDialog 中若内嵌 ColorPicker 的分类色数据不要动。

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/components/AddTaskDialog.qml qml/components/CategoryDialog.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS（含 `AddTaskDialogLayout`、`Phase3CategoryUi` 等）。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/components/AddTaskDialog.qml qml/components/CategoryDialog.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/components/AddTaskDialog.qml qml/components/CategoryDialog.qml
git commit -m "令牌化 AddTaskDialog/CategoryDialog"
```

---

## Task 5：迁移对话框 B —— CountdownDialog / ExportDialog

**Files:**
- Modify: `qml/components/CountdownDialog.qml`
- Modify: `qml/components/ExportDialog.qml`

- [ ] **Step 1：两文件顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换 chrome 值**

CountdownDialog：错误态 `#c46f5f`→`dangerBorder`、`#b24f3d`→`danger`；按钮三态统一；`shadowColor`→`Theme.shadow`。ExportDialog：状态文字 `#b24f3d`→`danger`、`#5d4e37`→`ink`。

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/components/CountdownDialog.qml qml/components/ExportDialog.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS（含 `CountdownUi`、`Phase3ExportUi`）。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/components/CountdownDialog.qml qml/components/ExportDialog.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/components/CountdownDialog.qml qml/components/ExportDialog.qml
git commit -m "令牌化 CountdownDialog/ExportDialog"
```

---

## Task 6：迁移倒计时小组件 —— CountdownBanner / CountdownItem

**Files:**
- Modify: `qml/components/CountdownBanner.qml`
- Modify: `qml/components/CountdownItem.qml`

- [ ] **Step 1：两文件顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换 chrome 值**（含 `shadowColor: "#000000"` → `Theme.shadow`）

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/components/CountdownBanner.qml qml/components/CountdownItem.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/components/CountdownBanner.qml qml/components/CountdownItem.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/components/CountdownBanner.qml qml/components/CountdownItem.qml
git commit -m "令牌化 CountdownBanner/CountdownItem"
```

---

## Task 7：迁移视图 A —— TodayTaskView / FocusView

**Files:**
- Modify: `qml/views/TodayTaskView.qml`
- Modify: `qml/views/FocusView.qml`

- [ ] **Step 1：两文件顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换 chrome 值**（TodayTaskView 的 add 按钮三态统一；多处 `shadowColor`→`Theme.shadow`）

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/views/TodayTaskView.qml qml/views/FocusView.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/views/TodayTaskView.qml qml/views/FocusView.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/views/TodayTaskView.qml qml/views/FocusView.qml
git commit -m "令牌化 TodayTaskView/FocusView"
```

---

## Task 8：迁移视图 B —— WeekPlanView / MonthGoalView

**Files:**
- Modify: `qml/views/WeekPlanView.qml`
- Modify: `qml/views/MonthGoalView.qml`

- [ ] **Step 1：两文件顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换 chrome 值**（MonthGoalView 的 `#4caf50`→`success`、`#b24f3d`→`danger`、多处 `shadowColor`→`Theme.shadow`）

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/views/WeekPlanView.qml qml/views/MonthGoalView.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/views/WeekPlanView.qml qml/views/MonthGoalView.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/views/WeekPlanView.qml qml/views/MonthGoalView.qml
git commit -m "令牌化 WeekPlanView/MonthGoalView"
```

---

## Task 9：迁移 StatisticsView（最大视图，单独处理）

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1：顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换全部 chrome 值**（921 行，逐处；趋势涨跌色 `#4caf50`→`success`、跌的红若为 `#f44336`→`danger`）

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/views/StatisticsView.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/views/StatisticsView.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/views/StatisticsView.qml
git commit -m "令牌化 StatisticsView"
```

---

## Task 10：迁移 CountdownView

**Files:**
- Modify: `qml/views/CountdownView.qml`

- [ ] **Step 1：顶部加 `import ".."`**

- [ ] **Step 2：按映射表替换 chrome 值**（add 按钮三态统一；`shadowColor`→`Theme.shadow`；倒计时大数字字号若为 64 → `Theme.fontDisplay`）

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/views/CountdownView.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5：grep 残留**

Run:
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/views/CountdownView.qml
```
Expected: 无输出。

- [ ] **Step 6：提交**

```bash
git add qml/views/CountdownView.qml
git commit -m "令牌化 CountdownView"
```

---

## Task 11：迁移主壳与图表 —— MainWindow / ChartBar / ChartPie

**Files:**
- Modify: `qml/MainWindow.qml`
- Modify: `qml/components/ChartBar.qml`
- Modify: `qml/components/ChartPie.qml`

- [ ] **Step 1：加导入**

- `qml/MainWindow.qml`（在 `qml/` 根下）：加 `import "."`
- `qml/components/ChartBar.qml`、`qml/components/ChartPie.qml`：加 `import ".."`

- [ ] **Step 2：替换 chrome 值**

- MainWindow：分隔线 `#e8dfc8`→`Theme.border`、内容底 `#fffef9`→`Theme.surface`（纸张纹理 SVG 字符串里的颜色保持不动，那是贴图数据）。
- ChartBar：坐标轴/网格/文字等 chrome 按映射表替换。
- ChartPie：把第 17 行的系列配色数组**替换为引用 `Theme.chartColors`**（值不变，只是改为引用单例）；其余 chrome（图例文字/边框等）按映射表替换。

- [ ] **Step 3：qmllint**

Run: `pyside6-qmllint qml/MainWindow.qml qml/components/ChartBar.qml qml/components/ChartPie.qml`
Expected: 无错误。

- [ ] **Step 4：跑 QML 测试**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS（含 `MainWindowUiOptimization`）。

- [ ] **Step 5：grep 残留**

Run（ChartPie 的系列色应已改为 `Theme.chartColors`，故数组字面量消失）：
```bash
grep -nE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/MainWindow.qml qml/components/ChartBar.qml qml/components/ChartPie.qml
```
Expected: 仅可能剩 MainWindow 纸张纹理 SVG 内的颜色（非 chrome 令牌，属贴图数据）；其余无输出。

- [ ] **Step 6：提交**

```bash
git add qml/MainWindow.qml qml/components/ChartBar.qml qml/components/ChartPie.qml
git commit -m "令牌化 MainWindow 与图表组件"
```

---

## Task 12：阶段五 · 全局统一检查

**Files:** 无（仅校验）

- [ ] **Step 1：全局扫描 chrome 色号残留**

Run（排除允许保留的数据色处）：
```bash
grep -rnE "#(fffef9|faf8f3|fffaf1|faf6ee|f5ede3|f5f0e6|e8dfc8|f0e6d2|eee2c9|ede5d4|ddd4bb|ded1b5|3d3327|5d4e37|6d5e47|7a5544|8b7355|a0896b|9d7556|d4a574|d9a574|c99666|4caf50|b24f3d|c46f5f|f44336|777777|bdbdbd|e0e0e0|000000)" qml/ | grep -v "Theme.qml"
```
Expected: 仅剩三类可接受残留——ColorPicker 的 `colors`/`selectedColor` 数据、MainWindow 纸张纹理 SVG、Theme.qml 自身的令牌定义（已被 `grep -v` 排除）。逐条确认无遗漏的 chrome。

- [ ] **Step 2：全量 qmllint**

Run:
```bash
pyside6-qmllint qml/Theme.qml qml/main.qml qml/MainWindow.qml qml/views/*.qml qml/components/*.qml
```
Expected: 无错误。

- [ ] **Step 3：全量构建**

Run: `cmake --build build`
Expected: 成功。

- [ ] **Step 4：全量测试**

Run: `ctest --test-dir build --output-on-failure`
Expected: 全绿（`PomodoroTodoTests` / `CountdownServiceTests` / `PomodoroTodoQmlTests`）。

- [ ] **Step 5：人工目测对照**

启动 `/Applications/番茄Todo.app`，逐屏检查六个视图 + 各对话框，确认观感与迁移前一致，仅精调项（暖灰、暖红趋势、按钮交互态变暗、间距微调）有预期内变化。记录任何异常。

- [ ] **Step 6：（如目测发现问题）修正并提交**

如目测无碍则跳过。如需修正，改完后重跑 Step 2-4，再：
```bash
git add -A
git commit -m "视觉一致性令牌化收尾与目测修正"
```

---

## 自检备注

- **Spec 覆盖**：颜色/字号/间距/圆角四类令牌均有 Task 1 定义 + Task 2-11 迁移；数据色保留有 ColorPicker/ChartPie/分类色三处明确豁免；精调四项（暖灰、暖红、按钮态、间距）已落到映射表与对应任务；验证（构建/测试/qmllint/grep/目测）在 Task 12 收口。
- **类型一致性**：令牌命名（`Theme.surface`、`Theme.fontMd`、`Theme.space16`、`Theme.radiusMd`、`Theme.chartColors` 等）在 Task 1 定义后，后续任务引用一致。
- **注册机制**：全程相对目录导入（组件/视图 `import ".."`、根下 `import "."`、测试 `import "../../qml"`），不依赖 `main.cpp`，与 qmltestrunner 兼容。
