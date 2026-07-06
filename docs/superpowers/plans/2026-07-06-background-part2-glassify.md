# 背景主题 · 计划二（内容层玻璃化）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按规格映射表把主内容区透明化、各视图顶层区块与既有弹窗玻璃化，交付最终"区块浮在壁纸上"观感。

**Architecture:** 以 `mainContentBackground` 透明化为界（计划一刻意未动它）；共享组件（StatCard/ChartBar/ChartPie/CountdownItem）各改一处即覆盖多页；视图侧只动映射表所列容器，**表外一律不动**。

**Tech Stack:** Qt 6.9 / QML / qmltestrunner

**Depends on:** 计划一已合入（`Theme.glassCard/glassBorder/glassDialog` 令牌与 BackgroundWallpaper 壁纸层已存在）。

## Global Constraints

- 注释、提交说明一律中文；注释解释"为什么/边界"（AGENTS.md）。
- 构建：`cmake --build build`；**不得改 build/**。
- QML 单文件：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`；验收 = 连续 2 次全绿。
- **例外**：`tst_ui_optimization.qml` 有既有窗口曝光类偶发失败基线——该文件的验收是"新增断言不引入新失败"，偶发失败允许重跑一次区分。
- QML 测试纪律：不断言 `visible === true`；alpha 等浮点用近似断言（`< 0.01`），不裸 compare。
- 映射表外的元素（输入框、chip、TaskItem 行、星期脊柱、`rolloverBanner`、Toast、CountdownBanner、`mainContentDivider`）**一律不动**。

---

### Task 1: 主内容区透明化 + 移除旧噪点层

**Files:**

- Modify: `qml/MainWindow.qml`
- Test: `tests/qml/tst_mainwindow_ui_optimization.qml`

**Interfaces:**

- Consumes: 计划一的 `backgroundWallpaperLayer`（噪点已内置于壁纸组件）。
- Produces: `mainContentBackground` 全透明——后续任务的玻璃卡片直接压在壁纸上。

- [x] **Step 1: 写失败测试**

在 `tests/qml/tst_mainwindow_ui_optimization.qml` 已有测试之后加（MainWindow 实例 id 为 `mainWindow`）：

```qml
    function test_mainContentBackgroundTransparent() {
        var bg = findChild(mainWindow, "mainContentBackground")
        verify(bg)
        // 核心失败模式的守门员：主容器不透明会把壁纸整块盖死。
        verify(bg.color.a < 0.01, "主内容区必须透明，否则壁纸被盖住")
        // 噪点已迁往 BackgroundWallpaper，旧层残留会造成双重颗粒。
        verify(!findChild(mainWindow, "paperTextureLayer"), "旧噪点层应已移除")
    }
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`
Expected: 新测试 FAIL（alpha = 1）。

- [x] **Step 3: 实现**

`qml/MainWindow.qml` 的 `mainContentBackground` Rectangle（约 193-198 行）：

```qml
        Rectangle {
            objectName: "mainContentBackground"

            Layout.fillWidth: true
            Layout.fillHeight: true
            // 透明让壁纸透出；此 Rectangle 保留为 StackLayout 的布局宿主，不再承担底色。
            color: "transparent"
```

并把其内部整个 `Image { objectName: "paperTextureLayer" ... }` 块（约 200-209 行）删除。

- [x] **Step 4: 跑测试确认通过（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`（×2）
Expected: 全绿 ×2。

- [x] **Step 5: 提交**

```bash
git add qml/MainWindow.qml tests/qml/tst_mainwindow_ui_optimization.qml
git commit -m "主内容区透明化让壁纸透出并移除旧噪点层"
```

---

### Task 2: 共享组件玻璃化（StatCard / ChartBar / ChartPie / CountdownItem）

**Files:**

- Modify: `qml/components/StatCard.qml`
- Modify: `qml/components/ChartBar.qml`
- Modify: `qml/components/ChartPie.qml`
- Modify: `qml/components/CountdownItem.qml`
- Test: `tests/qml/tst_glass_components.qml`（新建）

**Interfaces:**

- Consumes: `Theme.glassCard/glassBorder`。
- Produces: 一处组件改动覆盖今日页 2 卡、统计页 3 卡 + 2 图、倒计时页全部卡片。

- [x] **Step 1: 写失败测试**

新建 `tests/qml/tst_glass_components.qml`（四个组件的属性都有安全默认值，可直接实例化）：

```qml
import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 共享卡片组件的玻璃化守门测试：断言驱动属性（color 令牌），不做像素级检查。
TestCase {
    id: testCase
    name: "GlassComponents"
    when: windowShown
    width: 420
    height: 320

    StatCard {
        id: statCard

        title: "专注"
        value: "0"
    }

    ChartBar {
        id: chartBar

        width: 300
        height: 160
    }

    ChartPie {
        id: chartPie

        width: 300
        height: 160
    }

    CountdownItem {
        id: countdownItem

        width: 300
        goalName: "考研"
    }

    function test_statCardGlass() {
        verify(Qt.colorEqual(statCard.color, Theme.glassCard))
        verify(Qt.colorEqual(statCard.border.color, Theme.glassBorder))
    }

    function test_chartBarGlass() {
        verify(Qt.colorEqual(chartBar.color, Theme.glassCard))
        verify(Qt.colorEqual(chartBar.border.color, Theme.glassBorder))
    }

    function test_chartPieGlass() {
        verify(Qt.colorEqual(chartPie.color, Theme.glassCard))
        verify(Qt.colorEqual(chartPie.border.color, Theme.glassBorder))
    }

    function test_countdownItemGlassKeepsHoverBorder() {
        verify(Qt.colorEqual(countdownItem.color, Theme.glassCard))
        // hover 描边行为是既有交互（border → accent），底色玻璃化不得动它；
        // 默认态（无悬停）边框仍应是 Theme.border。
        verify(Qt.colorEqual(countdownItem.border.color, Theme.border))
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_glass_components.qml`
Expected: 4 个测试 FAIL（颜色仍是 surface/surfaceRaised）。

- [x] **Step 3: 实现（四处底色替换）**

`qml/components/StatCard.qml` 31-32 行：

```qml
    color: Theme.glassCard
    border.color: Theme.glassBorder
```

`qml/components/ChartBar.qml` 21-22 行：

```qml
    color: Theme.glassCard
    border.color: Theme.glassBorder
```

`qml/components/ChartPie.qml` 23-24 行：

```qml
    color: Theme.glassCard
    border.color: Theme.glassBorder
```

`qml/components/CountdownItem.qml` 26 行（27 行 hover 边框三元式**不动**）：

```qml
    color: Theme.glassCard
```

- [x] **Step 4: 跑测试确认通过（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_glass_components.qml`（×2）
Expected: 全绿 ×2。

- [x] **Step 5: 相关既有测试回归**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_countdown_ui.qml`
Expected: 全绿（若其中有对旧底色的断言，按新令牌更新断言而非回退实现）。

- [x] **Step 6: 提交**

```bash
git add qml/components/StatCard.qml qml/components/ChartBar.qml qml/components/ChartPie.qml qml/components/CountdownItem.qml tests/qml/tst_glass_components.qml
git commit -m "统计卡与图表倒计时卡片玻璃化"
```

---

### Task 3: 今日页任务列表容器玻璃化

**Files:**

- Modify: `qml/views/TodayTaskView.qml`
- Test: `tests/qml/tst_today_rollover.qml`

- [x] **Step 1: 写失败测试**

在 `tests/qml/tst_today_rollover.qml` 已有测试之后加（TodayTaskView 实例 id 为 `view`，见 99-100 行）：

```qml
    function test_taskListContainerIsGlass() {
        var container = findChild(view, "todayTaskListContainer")
        verify(container)
        verify(Qt.colorEqual(container.color, Theme.glassCard))
        verify(Qt.colorEqual(container.border.color, Theme.glassBorder))
    }
```

若该文件尚未导入 Theme（无 `import "../../qml"`），在文件头部补上。

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml`
Expected: 新测试 FAIL。

- [x] **Step 3: 实现**

`qml/views/TodayTaskView.qml` 的 `todayTaskListContainer`（约 476-482 行）改两行：

```qml
            color: Theme.glassCard
            radius: Theme.radiusLg
            border.color: Theme.glassBorder
```

（`rolloverBanner` 是强调横幅，**不动**——映射表明确排除。）

- [x] **Step 4: 跑测试确认通过（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml`（×2）
Expected: 全绿 ×2。

- [x] **Step 5: 提交**

```bash
git add qml/views/TodayTaskView.qml tests/qml/tst_today_rollover.qml
git commit -m "今日任务列表容器玻璃化"
```

---

### Task 4: 专注页整页玻璃底板

**Files:**

- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

- [x] **Step 1: 写失败测试**

在 `tests/qml/tst_focus_view.qml` 已有测试之后加（FocusView 实例 id 为 `view`，见 125-126 行）：

```qml
    function test_pageBackdropIsGlass() {
        var backdrop = findChild(view, "focusPageBackdrop")
        verify(backdrop, "整页底板应有 objectName 供守护")
        verify(Qt.colorEqual(backdrop.color, Theme.glassCard))
    }
```

若该文件尚未导入 Theme（无 `import "../../qml"`），在文件头部补上（该文件已有此导入，见其第 3 行）。

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
Expected: 新测试 FAIL（findChild 返回 null）。

- [x] **Step 3: 实现**

`qml/views/FocusView.qml` 491-493 行的整页 Rectangle 改为：

```qml
    Rectangle {
        objectName: "focusPageBackdrop"

        anchors.fill: parent
        // 整页一块玻璃底板透出壁纸；不做"中央列包卡"的结构手术——
        // 专注页刚重构过且状态机复杂，玻璃化只换材质、不动布局。
        color: Theme.glassCard
```

- [x] **Step 4: 跑测试确认通过（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`（×2）
Expected: 全绿 ×2。

- [x] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "专注页底板玻璃化透出壁纸"
```

---

### Task 5: 周计划空日子玻璃化 + 两处滚动条轨道透明

**Files:**

- Modify: `qml/views/WeekPlanView.qml`
- Modify: `qml/views/MonthGoalView.qml`
- Test: `tests/qml/tst_ui_optimization.qml`（该文件已实例化 WeekPlanView 与 MonthGoalView）

- [x] **Step 1: 写失败测试**

在 `tests/qml/tst_ui_optimization.qml` 已有测试之后加。该文件的视图实例（143-165 行）：`todayTaskView`、`weekPlanView`、`monthGoalView`，Theme 已导入（第 5 行 `import "../../qml"`）：

```qml
    function test_weekEmptyDayIsGlass() {
        var emptyCard = findChild(weekPlanView, "weekEmptyDayCard")
        verify(emptyCard, "空日子占位块应有 objectName 供守护")
        verify(Qt.colorEqual(emptyCard.color, Theme.glassCard))
        verify(Qt.colorEqual(emptyCard.border.color, Theme.glassBorder))
    }

    function test_weekScrollTrackTransparent() {
        var track = findChild(weekPlanView, "weekScrollTrack")
        verify(track)
        // 主容器透明后，不透明轨道会变成压在壁纸上的白条。
        verify(track.color.a < 0.01)
    }

    function test_monthTimelineScrollTrackTransparent() {
        var track = findChild(monthGoalView, "monthTimelineScrollTrack")
        verify(track)
        verify(track.color.a < 0.01)
    }
```

前置条件：`test_weekEmptyDayIsGlass` 需要 mock 的 `getWeekTasks` 返回空数组（该文件现状即如此），保证至少一个"空日子"占位块被创建。

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml`
Expected: 3 个新测试 FAIL（findChild 返回 null——objectName 尚未加）。既有偶发失败按基线处理（重跑区分）。

- [x] **Step 3: 实现**

`qml/views/WeekPlanView.qml` 空日子 Rectangle（约 402-409 行）改为：

```qml
                        Rectangle {
                            objectName: "weekEmptyDayCard"

                            visible: !dayRow.hasTasks
                            Layout.fillWidth: true
                            Layout.preferredHeight: 48
                            radius: Theme.radiusMd
                            // 占位应比内容更轻：玻璃占位 vs 暖纸内容卡是有意的材质层级。
                            color: Theme.glassCard
                            border.color: Theme.glassBorder
                            border.width: 1
```

`qml/views/WeekPlanView.qml` 滚动条轨道（约 330-332 行）改为：

```qml
                background: Rectangle {
                    objectName: "weekScrollTrack"

                    // 主容器透明后轨道必须跟着透明，否则是一条压在壁纸上的白带。
                    color: "transparent"
                }
```

`qml/views/MonthGoalView.qml` 时间线滚动条轨道（约 691-693 行）改为：

```qml
                                background: Rectangle {
                                    objectName: "monthTimelineScrollTrack"

                                    color: "transparent"
                                }
```

- [x] **Step 4: 跑测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml`
Expected: 3 个新测试通过；文件整体不引入新失败（偶发基线重跑一次区分）。

- [x] **Step 5: 提交**

```bash
git add qml/views/WeekPlanView.qml qml/views/MonthGoalView.qml tests/qml/tst_ui_optimization.qml
git commit -m "周计划空日子玻璃化并透明化滚动条轨道"
```

---

### Task 6: 专注历史页两大容器玻璃化

**Files:**

- Modify: `qml/views/MonthGoalView.qml`
- Test: `tests/qml/tst_ui_optimization.qml`

- [x] **Step 1: 写失败测试**

在 `tests/qml/tst_ui_optimization.qml` 加（沿用 Task 5 的 `monthView` 实例）：

```qml
    function test_monthContainersAreGlass() {
        var calendar = findChild(monthView, "monthCalendarContainer")
        verify(calendar)
        verify(Qt.colorEqual(calendar.color, Theme.glassCard))
        verify(Qt.colorEqual(calendar.border.color, Theme.glassBorder))

        var timeline = findChild(monthView, "focusTimelinePanel")
        verify(timeline)
        verify(Qt.colorEqual(timeline.color, Theme.glassCard))
        verify(Qt.colorEqual(timeline.border.color, Theme.glassBorder))
    }
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml`
Expected: 新测试 FAIL（颜色仍是 surface）。

- [x] **Step 3: 实现**

`qml/views/MonthGoalView.qml`——`monthCalendarContainer`（约 467-469 行）：

```qml
                    radius: Theme.radiusLg
                    color: Theme.glassCard
                    border.color: Theme.glassBorder
```

`focusTimelinePanel`（约 616-618 行）：

```qml
                    radius: Theme.radiusLg
                    color: Theme.glassCard
                    border.color: Theme.glassBorder
```

（两处的 `border.width: 1` 与阴影 MultiEffect 保持不动。）

- [x] **Step 4: 跑测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml`
Expected: 新测试通过；不引入新失败（偶发基线重跑区分）。

- [x] **Step 5: 提交**

```bash
git add qml/views/MonthGoalView.qml tests/qml/tst_ui_optimization.qml
git commit -m "专注历史页日历与时间线容器玻璃化"
```

---

### Task 7: 六个既有弹窗面板玻璃化

**Files:**

- Modify: `qml/components/AddTaskDialog.qml`、`qml/components/EditTaskDialog.qml`、`qml/components/CountdownDialog.qml`、`qml/components/CategoryDialog.qml`、`qml/components/RoutineDialog.qml`、`qml/components/ExportDialog.qml`
- Test: `tests/qml/tst_add_task_dialog.qml`、`tests/qml/tst_edit_task_dialog.qml`

- [x] **Step 1: 写失败测试（有 objectName 的两个面板）**

`tests/qml/tst_add_task_dialog.qml` 已有测试之后加（弹窗面板 objectName 为 `dialogPanel`；打开弹窗后再找，Popup 的 background 才可靠存在；该文件的 dialog 实例 id 以文件内为准，下例以 `dialog` 指代）：

```qml
    function test_panelIsGlassDialog() {
        dialog.open()
        wait(20)
        var panel = findChild(dialog, "dialogPanel")
        verify(panel)
        verify(Qt.colorEqual(panel.color, Theme.glassDialog))
        dialog.close()
    }
```

`tests/qml/tst_edit_task_dialog.qml` 已有测试之后加（面板 objectName 为 `editDialogPanel`）：

```qml
    function test_panelIsGlassDialog() {
        dialog.openForTask({ id: 1, title: "任意", categoryId: -1, date: isoWithOffset(0) })
        wait(20)
        var panel = findChild(dialog, "editDialogPanel")
        verify(panel)
        verify(Qt.colorEqual(panel.color, Theme.glassDialog))
        dialog.close()
    }
```

两个测试文件若缺 `import "../../qml"`（取 Theme），在头部补上。

- [x] **Step 2: 跑测试确认失败**

Run:
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_add_task_dialog.qml`
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_edit_task_dialog.qml`
Expected: 各 1 个新测试 FAIL。

- [x] **Step 3: 实现（六处面板底色替换）**

逐文件把 `background: Rectangle` 面板的底色行改为 `color: Theme.glassDialog`（描边一律不动）：

- `AddTaskDialog.qml` 140 行：`color: Theme.surface` → `color: Theme.glassDialog`
- `EditTaskDialog.qml` 203 行：`color: Theme.surface` → `color: Theme.glassDialog`
- `CountdownDialog.qml` 155 行：`color: Theme.surface` → `color: Theme.glassDialog`
- `CategoryDialog.qml` 193 行：`color: Theme.surfaceRaised` → `color: Theme.glassDialog`
- `RoutineDialog.qml` 183 行：`color: Theme.surfaceRaised` → `color: Theme.glassDialog`
- `ExportDialog.qml` 169 行：`color: Theme.surfaceRaised` → `color: Theme.glassDialog`

注意：以上行号是面板 `background: Rectangle` 内的 color 行；同文件里内容区还有别的 `Theme.surface`/`surfaceRaised` 引用（输入框、按钮底），**不许连带替换**——只改各文件唯一的顶层 `background: Rectangle` 块内那一行。

- [x] **Step 4: 文本核验（无 objectName 的四个面板）**

Run: `grep -n "color: Theme.glassDialog" qml/components/AddTaskDialog.qml qml/components/EditTaskDialog.qml qml/components/CountdownDialog.qml qml/components/CategoryDialog.qml qml/components/RoutineDialog.qml qml/components/ExportDialog.qml`
Expected: 恰好 6 行命中，每文件 1 行。

- [x] **Step 5: 跑测试确认通过（2 次）+ 相关弹窗回归**

Run（各 ×2）:
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_add_task_dialog.qml`
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_edit_task_dialog.qml`
Run（各 1 次，回归）:
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_routine_dialog.qml`
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_phase3_category_ui.qml`
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_phase3_export_ui.qml`
`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_countdown_ui.qml`
Expected: 全绿（若既有测试断言了旧面板色，按新令牌更新断言而非回退实现）。

- [x] **Step 6: 提交**

```bash
git add qml/components/AddTaskDialog.qml qml/components/EditTaskDialog.qml qml/components/CountdownDialog.qml qml/components/CategoryDialog.qml qml/components/RoutineDialog.qml qml/components/ExportDialog.qml tests/qml/tst_add_task_dialog.qml tests/qml/tst_edit_task_dialog.qml
git commit -m "既有六弹窗面板统一玻璃材质"
```

---

### Task 8: 全量回归

**Files:** 无新改动（验证任务）。

- [x] **Step 1: 全量构建 + 三套测试**

Run: `cmake --build build && ctest --test-dir build --output-on-failure`
Expected: 3/3 通过（tst_ui_optimization.qml 偶发按既有基线重跑一次区分；本计划新增/改动的其它测试文件必须稳定绿）。

- [x] **Step 2: 冒烟指引（报告给用户）**

构建部署后人工确认最终观感：六个页面区块浮在壁纸上（今日列表卡 / 专注整页玻璃 / 周计划空日子 / 历史双容器 / 统计卡与图 / 倒计时卡）；弹窗面板玻璃材质；切换六张壁纸逐页看可读性；`rolloverBanner`（造一条昨日未完成任务）仍是焦糖强调横幅。
