# Plan 027: 任务列表启用 delegate 复用，并把两处 Repeater 换成虚拟化视图

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> git diff --stat 0aa89af..HEAD -- qml/views qml/components/TaskItem.qml  # 基线 2026-08-07 复核时更新
> grep -rn "reuseItems" qml/                        # 当前应只有 GoalsView:387,410 两处
> grep -n "Repeater" qml/views/DashboardView.qml    # 任务列表那处应命中 :661 附近
> grep -n "Repeater" qml/views/WeekPlanView.qml     # 应命中 :547 附近
> ```
>
> 2026-08-07 在 `0aa89af` 上重验：两处 `Repeater` 仍未虚拟化，`reuseItems` 仍只在目标页。
> **行号漂移**：`DashboardView` 的任务列表 `Repeater` 由 `:610` 移到 **`:661`**
> （`0aa89af` 修 `ScrollView` 宽度绑定时上移了内容项）。注意同文件 `:529` 还有一个
> `Repeater`，那是筛选胶囊（三个固定项），**不是本计划的目标**，不要改它。
> `WeekPlanView.qml:547` 与外层 `ListView` 的 `cacheBuffer: 180`（`:397`）都没变。

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED（delegate 复用会暴露被"每次重建"掩盖的状态泄漏；Step 1 先做小的、可回退的一半）
- **Depends on**: plans/025（用它的 harness 量化收益；未落地也能做，但收益只能定性描述）
- **Category**: perf
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

`TaskItem` 是全应用最重的 delegate：**两个 layer FBO**（根节点一个、删除按钮背景一个）、
3 个 `Button`、1 个 `CheckBox`、1 个 `TextField`、2 个 `GlassPanel`、1 个 `CompletionParticles`。
它出现在四个地方，但**没有一处启用 `reuseItems`**，其中**两处根本没有虚拟化**：

- `qml/views/DashboardView.qml:610` —— `Repeater { model: root.filteredTasks }`，
  外面套 `ColumnLayout` + `ScrollView`。**每个任务都被实例化，没有上限，没有回收。**
  40 个任务 = 40 个完整 delegate + 80 个 layer target；换成 `ListView` 只需要约 10 个。
- `qml/views/WeekPlanView.qml:547` —— `Repeater { model: dayRow.dayTasks }`，
  嵌在一个 7 天的 `ListView` delegate 里，而那个 `ListView` 还带 `cacheBuffer: 180`
  （`:397`），于是大半周的任务同时被实体化。

而项目**自己已经在目标页收敛了正确做法**：`qml/views/GoalsView.qml:387` 和 `:410` 都有
`reuseItems: true`，`qml/components/GoalProgressRing.qml:5-8` 还专门写了复用契约的注释
（"列表启用了 delegate 复用，立即更新还能保证圆弧和中央数字始终属于同一个目标"）。
`qml/components/GoalCard.qml:47` 的注释也记着"列表每一行都会多占一个 FBO"这个认知。

**同一个认知已经存在，只是没有应用到更常见、更重的任务行上。**

## Current state

### 四处 `TaskItem` 的容器形态

| 位置 | 容器 | 虚拟化 | 复用 |
|---|---|---|---|
| `qml/views/TodayTaskView.qml:628` | `ListView` | ✅ | ❌ 无 `reuseItems` |
| `qml/views/CountdownView.qml:201` | `ListView` → `Loader` → `CountdownItem` | ✅ | ❌ 无 `reuseItems` |
| `qml/views/DashboardView.qml:610` | `Repeater` | ❌ | ❌ |
| `qml/views/WeekPlanView.qml:547` | `Repeater`（嵌在 `ListView` delegate 内） | ❌ | ❌ |

`TodayTaskView.qml:628` 现状：

```qml
ListView {
    id: todayTaskList
    anchors.fill: parent
    clip: true
    visible: root.tasks.length > 0
    model: root.tasks
    spacing: Theme.space8
    boundsBehavior: Flickable.StopAtBounds

    delegate: TaskItem {
        width: todayTaskList.width
        height: implicitHeight
        // ...
    }
}
```

### 复用会暴露的状态（这是本计划的主要风险）

`TaskItem` 有三个跨行不能串味的状态：

```qml
// qml/components/TaskItem.qml
property bool visualTaskCompleted: false   // :56  完成动画的视觉态
property bool titleEditing: false          // :57  行内改名编辑态
readonly property bool itemHovered: root.pointerInside  // :73  派生自指针，无需手动重置
```

`titleEditing` 最危险：用户正在改 A 的标题时滚动，delegate 被回收给 B，
**B 会带着 A 的编辑态出现**。`visualTaskCompleted` 次之（完成动画串到别的行）。
`itemHovered` 是派生值，`pointerInside` 会自然复位，不用处理。

正确做法是 `ListView.onReused` / `ListView.onPooled` 里显式复位——
`GoalProgressRing.qml:5-8` 的注释就是在讲同一类问题（它的解法是干脆去掉动画，
让新值立即生效）。

## Commands you will need

构建目录必须在仓库外，且**必须显式传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**
（默认 ON 且部署目标挂在 `ALL`，不关会覆盖 `/Applications/番茄Todo.app`；cache 变量会粘住）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-027 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| QML 测试 | `cd /tmp/pt-027 && ctest -R PomodoroTodoQmlTests --output-on-failure` | 通过 |
| 全量 | `cd /tmp/pt-027 && ctest --output-on-failure` | `100% tests passed ... out of 14` |

## Scope

**In scope**：
- `qml/components/TaskItem.qml`（**只加** `ListView.onReused` / `onPooled` 复位逻辑）
- `qml/views/TodayTaskView.qml`（加 `reuseItems`）
- `qml/views/CountdownView.qml`（加 `reuseItems`）
- `qml/views/DashboardView.qml`（`Repeater` → `ListView`）
- `qml/views/WeekPlanView.qml`（`Repeater` → 虚拟化，见 Step 4 的两个选项）
- 对应的 `tests/qml/tst_*.qml`（补复用不串味的用例）

**Out of scope**（不许碰）：
- **`layer.enabled`** —— `TaskItem.qml:26-27` 的注释写明：hover 事件分发期间切换它
  会重入已释放的 `QQuickItem`。本计划不碰它，减少 FBO 的事交给 plans/026 的 `blurMax`。
- **`TaskItem` 的业务逻辑与视觉** —— 只加复位钩子，不改它做什么、长什么样。
- `GoalsView` 的两个视图 —— 已经有 `reuseItems`。
- 任何 C++ 文件。

## Git workflow

- 分支：`advisor/027-list-virtualization`
- 中文提交信息，建议分三次：
  `任务行补 delegate 复用复位钩子` / `今日任务与倒计时列表启用 reuseItems` /
  `仪表盘与周计划任务列表改为虚拟化`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 先给 `TaskItem` 加复位钩子（在启用复用之前）

顺序很重要：**先有复位，再开复用**。反过来会先引入一段串味的窗口期。

```qml
// 列表启用 delegate 复用后，回收的实例会带着上一行的状态出现。
// titleEditing 最危险：正在改 A 的标题时滚动，B 会带着编辑态冒出来。
ListView.onPooled: {
    root.titleEditing = false
    root.visualTaskCompleted = false
}
ListView.onReused: {
    root.titleEditing = false
    root.visualTaskCompleted = false
}
```

`itemHovered` 是 `pointerInside` 的派生值，不用处理——在注释里写明为什么不处理，
免得下一个人以为漏了。

**注意**：`ListView.onPooled` 附加属性只在 `ListView` 的 delegate 里有效。
`TaskItem` 也被 `Repeater` 用（Step 3/4 之前还是），那里这两个信号不会触发，**无害**。

**Verify**: `cmake --build /tmp/pt-027 -j8` → exit 0；`ctest` → 14/14（此时行为未变）

### Step 2: 今日任务与倒计时列表开 `reuseItems`

`TodayTaskView.qml:628` 与 `CountdownView.qml:201` 各加一行 `reuseItems: true`。

**Verify**: `ctest -R PomodoroTodoQmlTests` → 通过

### Step 3: 补复用不串味的用例（**必须先确认它会红**）

在 `tests/qml/tst_task_item_edit.qml`（已存在，处理改名编辑）或今日任务的测试文件里加：

```js
function test_reused_delegate_does_not_carry_edit_state() {
    // 让一行进入 titleEditing，触发复用，断言新行的 titleEditing === false
}
```

**做法**：直接调用 delegate 的 `ListView.onPooled`/`onReused` 语义难以在测试里触发，
退而求其次：实例化 `TaskItem`，设 `titleEditing = true`，手工调用复位逻辑
（把复位抽成一个 `function resetPooledState()` 让测试可调），断言两个状态都回到 false。

**验证它有效**：临时删掉 `resetPooledState()` 里的那两行 → 用例必须变红 → 再还原。
**报告里要写明你做了这次验证、看到了什么**。一条从没红过的测试证明不了任何事。

**Verify**: 新用例通过，且你确认过它在功能移除后会红

### Step 4: 两处 `Repeater` 改虚拟化

**`DashboardView.qml:610`** —— 直接换 `ListView`：
`ScrollView` + `ColumnLayout` + `Repeater` → `ListView { reuseItems: true }`。
注意 `ListView` 的 delegate 不再享有 `ColumnLayout` 的隐式尺寸协商，
delegate 要显式给 `width: ListView.view.width` 和 `height: implicitHeight`
（照 `TodayTaskView.qml:638` 的写法）。

**`WeekPlanView.qml:547`** —— 这处是 `ListView`(7 天) 内嵌 `Repeater`(当天任务)，
更棘手。两个选项，**按这个顺序尝试**：

1. **保守方案（推荐先试）**：保留结构，把外层 `ListView` 的 `cacheBuffer: 180`（`:397`）
   降到 `0`。这不改结构、风险最低，但只减少了预实体化的天数，没有解决当天任务多时的问题。
2. **彻底方案**：拍平成单个 `ListView` + `section.property: "date"`，用分组头代替日期行。
   这会重写周计划页的列表结构，**风险明显更高**。

**若方案 1 就能让 harness 读数明显改善，就停在方案 1**，把方案 2 记进 Maintenance notes。
不要为了"做彻底"去动一个测试覆盖不明的页面结构。

**Verify**: `ctest` → 14/14；周计划页与仪表盘的既有 QML 用例全绿

### Step 5: 量化收益

用 plans/025 的 `tests/perf/bench_task_list.qml` 对比改动前后：
30 行任务的构建帧数与耗时。**把实际数字写进报告**，不要写"应该更快了"。

若 025 尚未落地：如实说明"未能量化"，并给出定性依据（实例化数量从 N 变成约 10）。

**Verify**: 报告里有数字，或有明确的"未能量化"声明

## Test plan

- **新增**：delegate 复用状态复位用例（Step 3），必须验证过会红
- **回归**：`tst_task_item_edit.qml`、今日任务/仪表盘/周计划的既有 QML 用例全绿。
  这些是本计划最重要的安全网——改动的是列表结构，它们最可能先红
- 结构范式：`qml/views/GoalsView.qml:387` 的 `ListView { reuseItems: true }`

## Done criteria

- [ ] `cd /tmp/pt-027 && ctest --output-on-failure` → 14/14
- [ ] `grep -rn "reuseItems" qml/` → 至少 4 处（原 2 + 今日任务 + 倒计时，若 Step 4 用了
      `ListView` 则更多）
- [ ] `grep -n "Repeater" qml/views/DashboardView.qml` → 任务列表那处已消失
- [ ] `git diff qml/ | grep -c "layer.enabled"` → **0**
- [ ] 新用例存在，且报告写明"移除复位逻辑后它会红"
- [ ] Step 5 的数字或"未能量化"声明已写进报告
- [ ] `plans/README.md` 中 027 的状态行已更新

## STOP conditions

- Drift check 与实际不符。
- 开启 `reuseItems` 后既有 QML 用例变红 —— 说明还有别的状态需要复位，
  **报告是哪个状态、哪条用例**，不要盲目往复位函数里加属性。
- `WeekPlanView` 的方案 1 无明显改善、方案 2 又需要重写超过 100 行 —— 停下报告，
  让人决定要不要单独立项。
- 你发现必须动 `layer.enabled` 才能拿到收益 —— 停下报告。

## Maintenance notes

- **以后给 `TaskItem` 加任何"当前交互态"属性（编辑中、动画中、选中），都必须同时加进
  `resetPooledState()`**。这是复用列表的长期维护义务，值得写在 `TaskItem` 头部注释里。
- 若 Step 4 停在了方案 1，`WeekPlanView` 的彻底虚拟化仍是待办：当某一天的任务数很大时
  它还是会一次性实体化。触发条件是单日任务数，不是总数。
- 审查这个 PR 时该重点看：`onPooled`/`onReused` 里复位的属性集合，是否覆盖了
  `TaskItem` 所有"跨行不能串"的状态；以及 `DashboardView` 的 delegate 尺寸是否
  从 `Layout.*` 正确改成了 `width`/`height`（两者不能混用）。
