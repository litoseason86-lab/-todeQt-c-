# Plan 007: 目标详情页 —— 100 格网格 + 完成预测 + 月历热力（奖励机制·阶段 B）

> **Executor instructions**: 按步骤执行，逐步验证；触发 STOP conditions 立即停下报告。
> 完成后更新 `plans/README.md` 状态行。
>
> **Drift check（先跑这个）**：
> `grep -n "goalOpened" qml/views/GoalsView.qml` 必须命中（006 已交付）；
> `grep -n "validPomodoroCountExpr" src/services/FocusSessionRules.h` 必须命中。
> 任一不命中按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW-MED
- **Depends on**: plans/006-goals-view-list-and-entry.md
- **Category**: feature（奖励机制 阶段 B）
- **Planned at**: commit `43ba2ee`, 2026-07-26
- **设计依据**: `docs/奖励机制实施方案.md` §一.2/§一.3/§三-阶段B；设计稿 `02/04/05`

## Why this matters

100 格网格是整套奖励感的**核心载体**：任意目标归一化成 10×10 格，
边界格按比例部分填充（目标 300 时一个番茄也有可见的 1/3 格增量——沉没成本可视化）；
第 25/50/75/100 格在未点亮时带描边（**前瞻性诱因**：下一个庆祝永远看得见还差几格）。
加上「照此速度还需 N 天」（goal-gradient）和月历热力（习惯轨迹），
详情页是用户"回味投入"的地方。

已定不再议：网格限宽 360 居中（铺满像毯子）；浅色主题未点亮格用 `Theme.border`
（`surfaceSunken` 与卡片底同色会看不见）；里程碑格**只描边不加星**；达成态用深焦糖不引绿色。

## Current state

### 入口（006 交付）

`qml/views/GoalsView.qml` 有 `signal goalOpened(int goalId)`，本计划把它接成页内详情：
GoalsView 增加 `property int openGoalId: -1`，>0 时显示详情子页（内部 Loader/状态切换，
**不新增 MainWindow 路由**——详情是目标页的子状态，不是新视图）。

### 数据

`goalService.getGoal(goalId)` 返回单目标 map（键同 006 列表）。
热力图需要**新增一个只读接口**（本计划唯一的 C++ 改动）：

```cpp
// GoalService.h 新增：
// 某目标在指定月份的每日有效番茄数。返回 [{day:int, count:int}]，只含 count>0 的天。
// 口径与 done_count 完全一致：所绑科目、番茄模式、自然到点、时长达标、起始逻辑日之后。
Q_INVOKABLE QVariantList getGoalDailyCounts(int goalId, int year, int month);
```

实现要点（照 `goalSelectSql` 的既有口径拼装，**不得复制第二套阈值**）：

```sql
SELECT date(fs.start_time, :dayShift) AS d, <validPomodoroCountExpr()> AS c
FROM focus_sessions fs JOIN tasks t ON fs.task_id = t.id
WHERE t.category_id = :categoryId
  AND fs.duration IS NOT NULL
  AND date(fs.start_time, :dayShift) >= :startDate
  AND date(fs.start_time, :dayShift) BETWEEN :monthFirst AND :monthLast
GROUP BY d
```

`:dayShift` 用 `LogicalDay::sqlShift(AppSettings::instance()->dayStartHour())`（文件内已有
`dayShift()` 匿名函数）。`categoryId/startDate` 先 `loadGoals(goalId)` 取。
goalId 不存在或查询失败 → 空列表 + `reportFailure`。

### 100 格归一化（照抄验证过的公式）

```
filledCells = targetPomodoros > 0 ? min(100, doneCount / targetPomodoros * 100) : 0
fullCells   = floor(filledCells)
partial     = filledCells - fullCells      // 第 fullCells 格的填充宽度比例
里程碑格下标 = 24 / 49 / 74 / 99（未整格点亮时 border Theme.accent 1px）
格子底色    = Theme.darkMode ? Theme.surfaceSunken : Theme.border
填充色      = Theme.accent；达成后整格填充可保持 accent（达成态主要靠头部与弹窗表达）
```

实现：`Repeater`×100 个 `Rectangle`（10 列 Grid，gap 4，限宽 360 居中），
格内左对齐子 Rectangle 按 `fillRatio` 撑宽。100 个静态项无动画开销可忽略。

### 月历热力渲染范式

照 `qml/views/MonthGoalView.qml` 的月历画法（起始星期偏移、当月天数、今天描边）。
只借渲染结构，数据源换 `getGoalDailyCounts`。格子透明度按
`0.25 + 0.75 * count/maxCount`，色相用 `Theme.accent`。

### 测试范式

- C++：`tests/GoalServiceTests.cpp`（已有 22 用例）加热力接口用例；
  helper `insertSession(taskId, start, duration, mode)` 会自动写 `pomodoro_completed`。
- QML：`tests/qml/tst_goals_view.qml` 追加详情用例。红线：不断言 visible；`tryCompare`。

## Commands you will need

同 plan 006 的表（构建目录换 `/tmp/pt-007`）。C++ 改动后跑：
`cmake --build /tmp/pt-007 --target GoalServiceTests -j8 && QT_QPA_PLATFORM=offscreen /tmp/pt-007/GoalServiceTests`

## Scope

**In scope**：
- `src/services/GoalService.h/.cpp`（**只加** `getGoalDailyCounts`）
- `qml/components/Grid100.qml`、`qml/components/GoalHeatmap.qml`（新建）
- `qml/views/GoalsView.qml`（接详情子页）
- `resources/qml.qrc`（注册两个新组件）
- `tests/GoalServiceTests.cpp`、`tests/qml/tst_goals_view.qml`（追加用例）

**Out of scope**：
- `goalSelectSql` / 里程碑逻辑 / `refreshMilestones` —— 一行不动。
- 弹窗、音效、toast —— 008。
- MainWindow / Sidebar —— 详情是页内子状态，不动路由。
- 格子的点亮动画（cell-pop）—— 008 决策 A 只做全局 toast，页面内动效未纳入本轮。

## Git workflow

分支 `advisor/007-goal-detail`；提交建议：
`目标服务新增每日番茄热力查询` / `详情页:100格网格与月历热力`。不 push。

## Steps

### Step 1: C++ `getGoalDailyCounts` + 单测

实现如上。在 `GoalServiceTests` 加 2 个用例：

1. `dailyCountsGroupByLogicalDay`：dayStartHour=4，anchor 日 02:00 与 12:00 各插 1 个
   有效番茄 → 02:00 归前一天；断言两天各 count=1。
2. `dailyCountsRespectStartDateAndCategory`：起始日前的记录与别科目的记录不计入。

**Verify**: `GoalServiceTests` → `Totals: 26 passed`（22+plan004 已并入后按实际基线+2）。
基线数不符合预期时先数清再报告，不要硬凑。

### Step 2: `Grid100.qml`

属性：`doneCount`、`targetCount`、`gap: 4`。按 "Current state" 公式实现。
组件顶部中文注释写明归一化理由与里程碑格语义。

### Step 3: `GoalHeatmap.qml`

属性：`year`、`month`、`dailyCounts`（数组）、今天描边 `Theme.accent`。
渲染照 MonthGoalView 月历结构。

### Step 4: GoalsView 详情子页

`openGoalId > 0` 时替换列表区为详情列：
返回按钮 + 标题 + 「开始 yyyy.M.d · 长期目标/截止 …」副行 →
进度条卡片（`doneCount / target 番茄` + 圆角条）→
100 格卡片（右上角 percent%）→
`forecastDays > 0` 时一行「照此速度还需 N 天」→
热力卡片（当月，`getGoalDailyCounts` 取数）→
编辑 / 删除按钮（复用 006 的 GoalFormDialog；删除带确认，成功后回列表）。
`goalsChanged` 时若详情打开则重取 `getGoal`。
对外暴露 `function openGoal(goalId)`（008 的弹窗跳转用）。

### Step 5: QML 用例（追加到 tst_goals_view.qml）

1. `openGoal(id)` 后 `openGoalId === id`；返回后 `-1`。
2. Grid100 归一化：done=25,target=300 → `fullCells===8`、部分格比例≈0.33（浮点用 `fuzzyCompare`）。
3. 里程碑格：done=0 时下标 24/49/74/99 的格子 border 宽 >0，其余 ===0。
4. forecast 行：forecastDays=-1 时详情里无「还需」文案。

**Verify**: QML 套件通过。

### Step 6: 视觉稿 + 全量

离屏渲染详情页（62/100 与 25/300 两张）存 `docs/设计稿/长期目标/实现-详情*.png`；
全量 `ctest` 12 套件通过。

## Done criteria

- [ ] 全量 12 套件通过；`GoalServiceTests` 基线+2
- [ ] `grep -n "getGoalDailyCounts" src/services/GoalService.h` 命中
- [ ] `grep -rn "180\|\b3 \* 60\b" src/services/GoalService.cpp` 中**没有**新增的阈值字面量
      （口径只能来自 `FocusSessionRules`）
- [ ] Grid100 在 done=25/target=300 下第 9 格为部分填充（QML 用例锁定）
- [ ] 两张实现视觉稿生成
- [ ] `plans/README.md` 更新

## STOP conditions

- Drift check 失败；006 尚未落地（`goalOpened` 不存在）。
- `GoalServiceTests` 基线与预期不符且原因不明。
- 发现需要动 `goalSelectSql` 或 `refreshMilestones` 才能实现热力接口。
- MonthGoalView 的月历结构无法复用（结构与描述不符）——报告，不要另起炉灶自创一套。

## Maintenance notes

- 008 的达成弹窗「查看目标」调 `GoalsView.openGoal(goalId)`。
- 热力接口是每目标每月一次查询，打开详情才调用；无性能顾虑。若未来做"年视图"再谈聚合。
- 页内子状态意味着 goals 视图的 `pageActive` 变 false 时详情随页隐藏，无需单独处理。
