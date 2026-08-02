# Plan 028: 七个页面改为按需加载，不再全生命周期常驻

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- qml/MainWindow.qml qml/views
> grep -n "StackLayout" qml/MainWindow.qml          # 应命中 :558 附近
> grep -c "Loader" qml/MainWindow.qml               # 当前应为 1
> grep -n "focusView\." qml/MainWindow.qml          # 应命中 :365 与 :374
> ```

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED（`Loader` 会打断按 id 直接调用视图方法的既有写法）
- **Depends on**: plans/025（量化收益）、建议排在 plans/027 之后（两者都改视图容器）
- **Category**: perf
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

`qml/MainWindow.qml:558` 的 `StackLayout` 直接实例化七个视图，全仓只有 1 个 `Loader`。
`StackLayout` 对非当前子项**只切 `visible`，从不销毁**，所以：

- `FocusView`（1251 行）、`DashboardView`（871）、`StatisticsView`（884）、
  `GoalsView`（801）、`WeekPlanView`、`MonthGoalView`、`TodayTaskView` **全部在启动时构建、
  此后常驻**；
- 其中三个页面（今日任务、周计划、仪表盘）**各自持有一份任务列表**，
  即同一批 `TaskItem` 在内存里存在三套。

`pageActive` 属性做得是对的——它确实压住了各页的**逻辑**（第五轮审计实测：
没有任何动画在后台页空转）。但它压不住 **item 树、绑定和 JS 堆**。
另一个后果是切页时集中付账：新页面的所有 layer FBO 在同一帧里分配。

**诚实说明**：这条的收益**未经测量**。常驻的是"构建成本"和"内存"，
第五轮审计没能测到常驻内存与切页帧时（需要可见窗口，项目红线不允许）。
本计划的价值判断建立在结构事实上，不是实测数字上——所以它的优先级是 P3，
且**应该在 plans/025 的工装能给出数字之后再做**。

## Current state

```qml
// qml/MainWindow.qml:558
StackLayout {
    id: stackLayout
    objectName: "mainViewStack"

    anchors.fill: parent
    currentIndex: root.viewIndex(root.currentView)

    TodayTaskView {
        pageActive: root.currentView === "today"
        categoryManagerRef: root.categoryManagerRef
        countdownServiceRef: root.countdownServiceRef
        settingsRef: root.appSettingsRef
        pendingDeleteTaskId: root.pendingDeleteTaskId
        // ...
    }
    // FocusView、WeekPlanView、MonthGoalView、StatisticsView、DashboardView、GoalsView 同理
}
```

### 两处会被 `Loader` 打断的直接调用（本计划的主要风险）

```qml
// qml/MainWindow.qml:365
focusView.syncToActiveTimer()
// qml/MainWindow.qml:374
if (focusView.enterWithTask(taskId, taskTitle, usePomodoro)) {
```

这两处按 `id` 直接调 `FocusView` 的方法。包成 `Loader` 之后 `focusView` 不再是视图本身，
必须走 `focusViewLoader.item.xxx()`，且要防 `item` 为 null。

### 测试对结构的依赖

- `tests/qml/tst_mainwindow_ui_optimization.qml:316` 和 `:400` 都
  `findChild(mainWindow, "mainViewStack")` 并操作 `currentIndex`。
  `StackLayout` 本身保留即可，这两处应不受影响——但**必须实际验证**。
- 其它测试若按 `objectName` 找具体视图，`Loader` 未激活时会找不到。

### 项目约定

- 注释用中文，解释「为什么」和「边界条件」；跨层调用属于必须注释的类别。
- QML 测试硬规则：**绝不允许断言 `item.visible === true`**；用 `tryCompare` 不用固定 `wait()`。
- `Loader` 相关的项目通用规则：`active: false` 时销毁并释放；访问 `Loader.item` 前
  必须确认 `status === Loader.Ready`。

## Commands you will need

构建目录必须在仓库外，**必须显式传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**（cache 变量会粘住）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-028 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| QML 测试 | `cd /tmp/pt-028 && ctest -R PomodoroTodoQmlTests --output-on-failure` | 通过 |
| 全量 | `cd /tmp/pt-028 && ctest --output-on-failure` | `100% tests passed ... out of 14` |

## Scope

**In scope**：
- `qml/MainWindow.qml`（`StackLayout` 子项包 `Loader`；`focusView` 的两处调用改走 `item`）
- `tests/qml/tst_mainwindow_ui_optimization.qml`（若结构改动导致断言失效，同步更新）

**Out of scope**（不许碰）：
- **`TodayTaskView` 与 `FocusView` 保持饿汉加载** —— 见 Step 2 的理由。
- **各视图内部** —— 本计划只改它们怎么被创建，不改它们做什么。
- `pageActive` 的语义 —— 保持不变，`Loader` 是叠加在它之上的第二道闸。
- 任何 C++ 文件。

## Git workflow

- 分支：`advisor/028-lazy-pages`
- 中文提交信息：`次要页面改为按需加载`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 先把 `focusView` 的两处直接调用改成防空写法

**顺序很重要**：先让调用点能容忍 `item` 为 null，再引入 `Loader`。
反过来会有一段必然崩溃的窗口期。

即使 `FocusView` 最终保持饿汉加载（Step 2），这一步也值得做——它让调用点不再假设
视图一定存在。加中文注释说明为什么要防空。

**Verify**: `ctest` → 14/14（此时行为未变）

### Step 2: 只对**五个次要页面**包 `Loader`

**`TodayTaskView` 和 `FocusView` 保持直接实例化**，理由：
- `TodayTaskView` 是启动默认页，懒加载没有收益；
- `FocusView` 被 `MainWindow` 按 id 直接调用（`:365`/`:374`），且专注是核心路径，
  延迟构建会让"开始专注"这个最关键的交互多一次构建开销。

其余五个（`WeekPlanView`、`MonthGoalView`、`StatisticsView`、`DashboardView`、`GoalsView`）
包成：

```qml
Loader {
    // 次要页面按需构建：StackLayout 只切 visible 不销毁，七个页面否则会全程常驻。
    // 一旦加载过就不再卸载——用户在页面间来回切时不该反复重建。
    property bool everActivated: false
    readonly property bool pageIsCurrent: root.currentView === "stats"
    active: pageIsCurrent || everActivated
    asynchronous: true
    onPageIsCurrentChanged: if (pageIsCurrent) everActivated = true
    sourceComponent: StatisticsView { pageActive: ...; ... }
}
```

**"加载过就不卸载"是刻意的**：真正卸载会让每次切页都重建，比常驻更糟。
本计划要消除的是"从没打开过的页面也常驻"，不是"打开过的页面还占内存"。

**Verify**: `ctest -R PomodoroTodoQmlTests --output-on-failure` → 通过

### Step 3: 修复因 `Loader` 失效的测试

跑完 Step 2 后逐条看哪些用例红了。典型原因：`findChild` 找不到未激活页面里的对象。
**修法是让测试先切到该页再断言**，而不是把 `Loader` 改成常驻——后者等于放弃本计划。

**Verify**: `ctest` → 14/14

### Step 4: 量化

用 plans/025 的 `bench_page_switch.qml` 对比：启动时构建了几个视图、
首次切到统计页的耗时。**把数字写进报告**。

若 025 未落地：如实写"未能量化"，并给出结构性依据（启动构建的视图数 7 → 2）。

## Test plan

- **新增**：一条断言"未访问过的页面不会被构建"的用例。
  可行做法：给某个次要视图加 `Component.onCompleted: root.constructedPages++` 之类的计数钩子，
  或直接断言 `Loader.status === Loader.Null`。**不要断言 `visible`**（项目红线）。
- **回归**：`tst_mainwindow_ui_optimization.qml` 全部用例，尤其 `:316`/`:400` 操作
  `mainViewStack.currentIndex` 的两条。

## Done criteria

- [ ] `cd /tmp/pt-028 && ctest --output-on-failure` → 14/14
- [ ] `grep -c "Loader" qml/MainWindow.qml` → 明显大于 1
- [ ] `TodayTaskView` 与 `FocusView` 仍是直接实例化（未被包 `Loader`）
- [ ] `focusView` 的两处调用都有 null 防护
- [ ] 新用例存在并通过
- [ ] Step 4 的数字或"未能量化"声明已写进报告
- [ ] `plans/README.md` 中 028 的状态行已更新

## STOP conditions

- Drift check 与实际不符。
- 修复失效测试时，你发现只能通过"让 `Loader` 常驻"来让它变绿 —— 停下报告，
  那等于本计划白做。
- 包 `Loader` 后出现绑定循环或 `item` 为 null 的运行时错误，且两次修复未解决。
- 你发现某个次要视图被 `MainWindow` 或别的视图按 id 直接引用（除已知的 `focusView`）——
  报告是哪一处，不要自行改造那个调用链。

## Maintenance notes

- **新增页面时的默认做法应当是包 `Loader`**，除非它是启动默认页或核心路径。
  值得在 `MainWindow.qml` 的 `StackLayout` 上方写一句注释说明这个约定。
- `asynchronous: true` 让首次切页不阻塞 UI 线程，代价是页面会晚一两帧出现。
  若观感上有"闪一下空白"，可以给 `Loader` 加一个占位背景，**不要**改回同步加载。
- 本计划**没有**解决"打开过的页面永久常驻"。若将来内存成为真问题，
  下一步是给长期不用的页面加卸载策略——但那需要先有内存数字，现在没有。
