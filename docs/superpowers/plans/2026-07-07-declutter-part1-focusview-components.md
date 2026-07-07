# 拆臃肿 · 计划一（FocusView 抽 3 个自包含组件）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans。纯重构：不改行为，既有测试是安全网（全程保持全绿）。Steps 用 `- [ ]` 追踪。

**Goal:** 把 FocusView 的 3 个自包含内联组件（PresetButton / DurationStepper / FocusRing）抽成 `qml/components/` 下独立文件，FocusView 从 1239 行降到 ~1000 行，行为与测试 100% 不变。

**Architecture:** 三组件已被设计为零 `root.` 依赖（仅引用 Theme 与自身属性/信号；FocusRing 注释明言"自身不读取 root 状态"）。抽出＝移动 + 加文件头 imports + qrc 注册 + FocusView 加 `import "../components"` 并删内联块。所有 objectName 在**使用点**设置，抽取不触及，测试照常命中。

**Tech Stack:** Qt 6.9 / QML / qmltestrunner

**Depends on:** 无。在 `ui-polish` 分支。

## Global Constraints

- 注释、提交说明中文，解释为什么/边界。
- 自动流程无头，禁 `open`；QML `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`；验收 = 连续 2 次全绿。
- **重构铁律：不改任何行为。** 抽出内容逐字保留（属性/信号/绑定/objectName 使用点均不动）。
- qmllint 三个新文件零警告。

---

### Task 1: 创建三个组件文件（逐字移动 + 文件头 imports）

**Files:**
- Create: `qml/components/PresetButton.qml`
- Create: `qml/components/DurationStepper.qml`
- Create: `qml/components/FocusRing.qml`

**Interfaces:**
- Produces: 三个可复用组件类型，供 FocusView（及将来）实例化。对外属性/信号与内联时完全一致（PresetButton: `backgroundObjectName`；DurationStepper: `value/from/to/namePrefix` + `signal adjusted(int)`；FocusRing: `progress/ringColor/...` 等既有属性）。

- [ ] **Step 1: PresetButton.qml**

新建，文件头加 imports，正文为 FocusView 现 `component PresetButton: Button { ... }`（行 301-326）的 `Button { ... }` 本体（去掉 `component PresetButton:` 前缀，`id: presetButton` 保留）：

```qml
import QtQuick
import QtQuick.Controls
import ".."

// 番茄时长预设按钮：选中态暖色填充。从 FocusView 抽出，零外部状态依赖（仅 Theme + 自身）。
Button {
    id: presetButton

    property string backgroundObjectName: ""

    checkable: true
    implicitWidth: 104
    implicitHeight: 42

    background: Rectangle {
        objectName: presetButton.backgroundObjectName
        color: presetButton.checked ? Theme.accent : (presetButton.hovered ? Theme.surface : Theme.surfaceRaised)
        border.color: presetButton.checked ? Theme.accentStrong : Theme.border
        border.width: 1
        radius: Theme.radiusMd
    }

    contentItem: Text {
        text: presetButton.text
        textFormat: Text.PlainText
        color: presetButton.checked ? Theme.surface : Theme.ink
        font.pixelSize: Theme.fontMd
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
```

- [ ] **Step 2: DurationStepper.qml**

新建，正文为 FocusView 现 `component DurationStepper: RowLayout { ... }`（行 330-411）本体（保留注释、`id: stepper`、`property`、`signal adjusted`）：

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

// 暖纸步进器替代 SpinBox 与"自定义"chip。value 只读外部状态，
// 加减通过 adjusted 信号回给 select*Minutes，避免出现第二套时长来源。
RowLayout {
    id: stepper

    property int value: 0
    property int from: 1
    property int to: 99
    property string namePrefix: ""

    signal adjusted(int newValue)

    spacing: 0

    // …… 移动 FocusView 行 342-410 的 minusButton / 数值 Rectangle / plusButton 三块，逐字不改 ……
}
```

（`minusButton`/数值 Rectangle/`plusButton` 三块从 FocusView 342-410 逐字搬入，含 `objectName: stepper.namePrefix + "Minus"/"Value"/"Plus"`。）

- [ ] **Step 3: FocusRing.qml**

新建，正文为 FocusView 现 `component FocusRing: Canvas { ... }`（行 416-546）本体（保留注释、`id: ring`、全部 property、onPaint 绘制逻辑逐字）：

```qml
import QtQuick
import ".."

// 环形进度盘：番茄模式下的可视化核心。只画"轨道 + 剩余弧"，
// 进度/颜色/暂停/预览态全部由外部属性驱动，自身不读取 root 状态——
// 保持可复用、可测试（测试断言驱动属性，不做像素级检查）。
Canvas {
    id: ring

    // …… 移动 FocusView 行 419-546 的全部 property 与 onPaint 逐字搬入 ……
}
```

- [ ] **Step 4: 三文件 qmllint 零警告**

Run: `for f in PresetButton DurationStepper FocusRing; do /Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/$f.qml; done`
Expected: 无输出（零警告）。若 FocusRing 报未限定 `Theme`，确认 `import ".."` 已加。

- [ ] **Step 5: 提交（暂不接线，下一步统一切换）**

```bash
git add qml/components/PresetButton.qml qml/components/DurationStepper.qml qml/components/FocusRing.qml
git commit -m "抽出 FocusView 三个自包含组件为独立文件"
```

---

### Task 2: qrc 注册 + FocusView 切换到外部组件

**Files:**
- Modify: `resources/qml.qrc`
- Modify: `qml/views/FocusView.qml`

**Interfaces:**
- Consumes: Task 1 的三组件文件。

- [ ] **Step 1: qrc 注册三文件**

在 `resources/qml.qrc` 的 `<file alias="qml/components/Sidebar.qml">` 行附近（组件区）加三行：

```xml
        <file alias="qml/components/PresetButton.qml">../qml/components/PresetButton.qml</file>
        <file alias="qml/components/DurationStepper.qml">../qml/components/DurationStepper.qml</file>
        <file alias="qml/components/FocusRing.qml">../qml/components/FocusRing.qml</file>
```

- [ ] **Step 2: FocusView 加 import + 删三个内联组件块**

`qml/views/FocusView.qml`：

1. 文件头 `import ".."` 之后加：`import "../components"`；
2. 删除 `component PresetButton: Button { ... }`（301-326）、`component DurationStepper: RowLayout { ... }`（330-411，含其上方注释 328-329）、`component FocusRing: Canvas { ... }`（413-546，含其上方注释 413-415）三整块；
3. 使用点（705 `FocusRing {}`、824+ 各 `PresetButton {}`、863/913 `DurationStepper {}`）**不动**——类型现由 `import "../components"` 提供，id/objectName/属性绑定原样有效。

- [ ] **Step 3: 构建**

Run: `cmake --build build 2>&1 | tail -3`
Expected: 通过。若报 `PresetButton is not a type`，确认 import 与 qrc 均已加。

- [ ] **Step 4: FocusView 测试 ×2 + lint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`（×2）
Expected: 全绿 ×2（37 个既有断言不变——行为未改）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add resources/qml.qrc qml/views/FocusView.qml
git commit -m "FocusView 切换到外部三组件并注册资源"
```

---

### Task 3: 全量无头回归

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量回归**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`
Expected: 4/4 通过。确认 FocusView 行数下降（`wc -l qml/views/FocusView.qml` ≈ 1000）、行为零变化。

- [ ] **Step 2: 汇报**

汇报行数变化与全绿，等待用户确认后进入下一文件（MonthGoalView / StatisticsView / TaskItem，先易后难逐个）。
