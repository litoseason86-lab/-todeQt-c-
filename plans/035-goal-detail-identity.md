# Plan 035: 原子切换目标详情，禁止弹窗标题与删除主键分裂

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 按步骤执行。每一步都跑对应验证，遇到 STOP condition 立即停下汇报。
> 完成后更新 `plans/README.md` 中本计划的状态。
>
> **Drift check（先跑）**：
> `git diff --stat f8e3120..HEAD -- qml/views/GoalsView.qml tests/qml/tst_goals_view.qml`
> 若文件有变化，先逐项重核下文的状态摘录；身份源、失败信号时序或删除入口改变时必须 STOP。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: correctness / destructive action
- **Planned at**: commit `f8e3120`，2026-08-16

## 产品口径

详情页的身份必须是一个原子快照：`openGoalId`、`detailGoal.id`、`dailyCounts` 要么全部属于新目标，
要么在加载失败时全部保留旧目标。删除只能使用用户当前看到的 `detailGoal.id`；两个 ID 不一致时拒绝删除。

这不是纯显示错误。当前弹窗标题取 `detailGoal.title`，实际删除却取 `openGoalId`。从目标 A 切到 B 时，
若 B 的数据库查询同步失败，界面仍显示 A，却会删除 B。

## Current state

### 身份先变、数据后取（`GoalsView.qml:125-132`）

```qml
function openGoal(goalId) {
    var normalizedId = Number(goalId || -1)
    if (normalizedId <= 0)
        return false
    root.syncDetailDateSnapshot()
    root.openGoalId = normalizedId
    root.refreshDetail()
    return Number(root.detailGoal.id || -1) === normalizedId
}
```

### 查询失败保留旧数据，却不回滚 ID（`GoalsView.qml:141-159`）

```qml
var loaded = root.goalServiceRef.getGoal(root.openGoalId)
if (!loaded || Number(loaded.id || -1) <= 0) {
    if (root.errorText.length > 0)
        return
    root.errorText = qsTr("目标不存在或已被删除")
    root.closeGoal()
    return
}
root.detailGoal = loaded
root.dailyCounts = root.goalServiceRef.getGoalDailyCounts(...)
```

`GoalService::getGoal()` 会在返回空 map 前同步发 `operationFailed`，所以这里的 early return 确实可达。

### 展示与删除使用不同身份源

```qml
// GoalsView.qml:183-189
const goalId = root.openGoalId
if (!root.goalServiceRef.deleteGoal(goalId)) {

// GoalsView.qml:754-759
text: qsTr("删除“%1”？").arg(String(root.detailGoal.title || qsTr("该目标")))
```

现有 `test_failed_detail_refresh_keeps_open_goal` 只测同一目标刷新失败，没有覆盖 A → B 的切换失败。

## Scope

**In scope**：

- `qml/views/GoalsView.qml`
- `tests/qml/tst_goals_view.qml`
- `plans/README.md`（只更新状态）

**Out of scope**：

- 不改 `GoalService` 的同步信号协议。
- 不重构整个目标页状态机。
- 不改变目标实际不存在时的既有口径：当前打开目标确实消失时，关闭详情并提示。

## QML 离屏测试红线（必须内联遵守）

- **禁止断言 `visible === true`。** 本项目用 `QT_QPA_PLATFORM=offscreen`，`visible` 会沿父级可见性链级联，
  不能稳定表达组件业务状态。改断言业务属性、控件 `enabled`、`Popup.opened`、模型内容或信号参数。
- **所有“今天/日期”都走逻辑日。** 使用测试现有的 `logicalDayService`、`logicalToday()` 或注入固定 ISO 日期；
  不直接用物理日 `new Date()` 推导今天，否则凌晨 `dayStartHour` 前会得到偶发失败。
- **不要等待或监听 `Popup.onClosed` 作为完成判据。** 离屏环境不保证投递该生命周期回调。
  直接调用被测请求/提交函数，并断言业务状态、`opened` 或控件状态；不要靠 `onClosed` SignalSpy 结束测试。

## Implementation

### Step 1: 先写跨目标失败回归测试

扩展 `tests/qml/tst_goals_view.qml` 的假服务：

- 增加 `lastDeletedGoalId`，在 `deleteGoal(goalId)` 第一行记录参数。
- 准备两个目标 A/B，先成功 `openGoal(A)`。
- 令 `failGoalQuery = true` 后调用 `openGoal(B)`，断言返回 false。
- 断言仍显示 A：`openGoalId == A.id`、`detailGoal.id == A.id`、标题与 A 一致。
- 打开删除确认并确认删除，断言 `lastDeletedGoalId == A.id`，绝不能是 B。

先在现有实现上运行这条用例，预期它失败；若它直接通过，说明复现前提已漂移，STOP。

**Verify**：
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir ~/pt-audit -R '^QmlTest.goals_view$' --output-on-failure`
→ 新增的 A → B 用例在旧实现上失败，失败值显示 `openGoalId` 已变成 B。

### Step 2: 把详情切换改成提交式更新

在 `GoalsView.qml` 提取一个只负责加载候选目标的内部函数。先把候选 ID、目标 map、每日数据放进局部变量；
只有全部必要同步调用成功后，才一次性写入 `openGoalId`、`detailGoal`、`dailyCounts`。

必须保留两种空结果的区别：

- `operationFailed` 已同步写入 `errorText`：加载失败，保留原快照，返回 false。
- 没有失败信号但目标为空：目标确实不存在。若是刷新当前详情，沿用现有行为关闭详情；若是尝试打开另一个目标，
  不得先破坏当前详情，返回 false 并给出“目标不存在或已被删除”。

`refreshDetail()` 复用同一加载逻辑，不能再出现先改 ID 再加载数据的路径。中文注释解释“候选数据全部成功后才提交，
避免破坏性操作引用另一目标”，不要逐行翻译代码。

**Verify**：重建后运行 `ctest --test-dir ~/pt-audit -R '^QmlTest.goals_view$' --output-on-failure`
→ A → B 失败用例转绿，既有“当前目标刷新失败”和“目标确实消失”用例仍通过。

### Step 3: 删除入口增加最后一道身份校验

`confirmDeleteDetail()` 使用 `Number(root.detailGoal.id || -1)` 作为删除 ID，并在调用 service 前检查：

- ID 必须大于 0；
- 必须等于 `openGoalId`。

不满足时设置明确的 `deleteErrorText`、保持弹窗和详情打开、返回 false，且 `deleteCalls` 不增加。
再加一条测试，直接制造两 ID 不一致，断言服务完全未被调用。这里是防御式保护，即使以后另一个刷新路径再次写坏状态，
破坏性操作仍不会落到错误主键。

**Verify**：运行同一 `QmlTest.goals_view` 条目
→ 身份不一致用例断言 `deleteCalls == 0`，整组测试 0 failed。

## Test plan

- 结构沿用 `tests/qml/tst_goals_view.qml:322-345` 的失败/恢复测试。
- 新增跨目标 A → B 查询失败、删除目标 ID、身份守卫拒绝、真实缺失四类断言。
- 不用 wait 猜同步时序；假服务与生产 `GoalService` 一样在返回前同步发 `operationFailed`。

## Verification

```bash
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build ~/pt-audit -j8
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit -R '^QmlTest.goals_view$' --output-on-failure
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8
```

预期：目标页新增用例通过，全量测试通过，无新增 qmllint/C++ warning。不要启动应用窗口。

## Done criteria

- A → B 查询失败后，三个详情字段仍一致地属于 A。
- 真正不存在的目标仍按明确口径处理，不伪装成数据库错误。
- 删除服务只接收当前展示目标的 ID；身份不一致时零调用。
- 新测试在旧实现上确实能转红，在修复后转绿。

## STOP conditions

- `GoalService::operationFailed` 已改为异步 queued signal，不能再用本轮同步错误判据区分“缺失/查询失败”。
- 发现除 `GoalsView.qml` 外还有直接用 `openGoalId` 删除目标的生产入口。
- 需要改变“目标确实不存在时关闭详情”的产品口径。

## Maintenance notes

- 以后给详情增加里程碑、热力或其他按目标加载的数据时，也必须放进同一候选快照后再提交。
- 评审重点不是“删除时用了哪个 ID”这一行，而是所有详情身份字段是否始终一起更新。
- 若未来把服务错误改成异步 result/promise，本计划的 `errorText` 同步判据必须整体替换，不能继续沿用。

## Git workflow

- 建议分支：`advisor/035-goal-detail-identity`
- 建议提交：`修复目标详情加载失败时误删其他目标`
- 不 push、不创建 PR，除非维护者明确要求。
