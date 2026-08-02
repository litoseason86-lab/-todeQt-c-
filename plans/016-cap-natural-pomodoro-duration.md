# Plan 016: 把自然到点番茄的持久化时长封顶在目标时长

> **Executor instructions**: 逐步执行并跑完每个验证门。触发 STOP conditions 时立即停止，不要扩大修改范围。完成后更新 `plans/README.md` 的 016 状态行。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/services/FocusTimer.cpp tests/TimingRobustnessTests.cpp
> ```
>
> 有输出时必须对照下文摘录检查；关键流程或测试名已变化则 STOP。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

番茄计时依赖单调时钟，系统休眠或 GUI 线程长时间阻塞后，一次 tick 可以越过目标数分钟。当前自然完成把全部越界时间写进 `duration`，导致 25 分钟番茄可能被记成 40 分钟，同时污染历史、统计和任务专注时长。只应对“自然到点的工作番茄”封顶；自由计时和手动停止必须保留真实累计时长。

## Current state

- `src/services/FocusTimer.cpp:23-58`：timeout 先同步真实经过时间，再在 `elapsed >= target` 时调用 `completeFocusSession(true)`。
- `src/services/FocusTimer.cpp:304-383` 当前直接保存全部累计值：

  ```cpp
  const int duration = m_elapsedSeconds;
  // ...
  if (!saveFocusSession(duration, naturalCompletion)) {
  ```

- `tests/TimingRobustnessTests.cpp:137-156` 的 `sleepPastEndCompletesExactlyOnce` 把 5 分钟目标推进到 10 分钟，只断言完成一次，没有核对数据库时长。
- `tests/TimingRobustnessTests.cpp:206-225` 的 `recoveredOverdueSessionCompletesOnceOnResume` 恢复 320 秒检查点到 300 秒目标，也没有核对时长。
- `FocusSessionRules::kMinimumValidDurationSeconds` 决定会话是否有效；本计划不改变有效番茄定义，只修正自然完成时传给保存、信号和自动完成逻辑的 duration。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-016 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-016 --target TimingRobustnessTests -j8` | exit 0 |
| 定向测试 | `cd /tmp/pt-016 && ctest -R '^TimingRobustnessTests$' --output-on-failure` | 1/1 通过 |
| 全量测试 | `cd /tmp/pt-016 && ctest --output-on-failure` | 14/14 通过（若后续计划已落地，以发现的总数为准） |

所有构建在仓库外进行；禁止启动 GUI，禁止省略 `POMODORO_TODO_DEPLOY_LOCAL=OFF`。

## Scope

**In scope**：

- `src/services/FocusTimer.cpp`
- `tests/TimingRobustnessTests.cpp`

**Out of scope**：

- `FocusSessionRules` 的 3 分钟/5 分钟口径。
- 修改 timeout 调度、休眠计时、活动态 schema 或 `end_time`。
- 对休息段、自由计时、手动停止做封顶。
- QML、部署和仓库内 `build/`。

## Git workflow

- 分支：`advisor/016-cap-natural-pomodoro-duration`
- 中文提交信息：`修正自然完成番茄的越界时长`
- 不 push，不开 PR。

## Steps

### Step 1: 先写会失败的越界时长特征测试

在 `TimingRobustnessTests` 增加查询最近已结束会话 duration 的小型测试 helper。扩展两个既有用例：

1. `sleepPastEndCompletesExactlyOnce`：数据库 duration 必须是 300，`focusCompleted` 参数也必须是 300。
2. `recoveredOverdueSessionCompletesOnceOnResume`：恢复后完成的数据库 duration 必须是 300，且仍只完成一次。
3. 增加边界用例：手动 `stopFocus()` 时即使测试注入的 elapsed 大于 target，也保存完整 elapsed，并写 `pomodoro_completed = 0`；证明封顶条件没有误伤手动停止。

**Verify**：定向测试应至少有上述自然完成断言失败，实际值为越界累计值；手动停止边界应通过。若测试在产品代码未改时全部通过，STOP，说明基线已变化或测试没走到目标路径。

### Step 2: 在完成入口只计算一次有效持久化时长

在 `FocusTimer::completeFocusSession(bool naturalCompletion)` 冻结时钟后计算 duration。目标代码形状：

```cpp
const bool capAtPomodoroTarget = naturalCompletion
    && m_mode == PomodoroMode
    && m_phase == WorkPhase
    && m_targetSeconds > 0;
const int duration = capAtPomodoroTarget
    ? qMin(m_elapsedSeconds, m_targetSeconds)
    : m_elapsedSeconds;
```

为这段非显然边界补中文注释：单调时钟越界要封顶，但手动停止和自由计时必须保存真实时长。后续最小时长判断、保存、自动完成判断、`sessionDiscarded` 和 `focusCompleted` 都继续使用这个单一 `duration` 变量，不能各算一份。

**Verify**：编译成功；定向测试 1/1 通过。

### Step 3: 做全量回归与范围审计

运行全量 CTest，再检查：

```bash
git diff --check
git status --short
git diff -- src/services/FocusTimer.cpp tests/TimingRobustnessTests.cpp
```

**Verify**：全量测试全绿；只有两个授权文件和索引状态发生变化；没有启动/部署应用。

## Test plan

- 自然完成：5 分钟目标跨休眠到 10 分钟，保存和信号均为 300 秒。
- 崩溃恢复：320 秒检查点恢复后自然完成，只保存 300 秒且只完成一次。
- 反例：手动停止越界状态不封顶、不标记完整番茄。
- 既有自由计时、短会话丢弃、休息段越界用例必须继续通过。

## Done criteria

- [ ] 两个自然完成越界用例都断言数据库 duration 等于 target。
- [ ] `focusCompleted` 对自然完成发出的 duration 也等于 target。
- [ ] 手动停止与自由计时仍保留真实累计时长。
- [ ] `TimingRobustnessTests` 和全量 CTest 全绿。
- [ ] `git diff --check` 无输出，未修改授权范围外产品文件。
- [ ] `plans/README.md` 的 016 状态已更新。

## STOP conditions

- timeout 不再通过 `completeFocusSession(true)` 完成工作番茄。
- duration 在多个函数中被重新计算，无法在当前两个文件内保证单一口径。
- 正确修复需要改变自由计时、休息段或数据库 schema。
- 任一验证连续两次失败且原因不在本计划范围。

## Maintenance notes

- reviewer 重点看封顶条件的四个守卫，尤其 `naturalCompletion` 和 `WorkPhase`，少一个都会改写合法历史。
- `end_time` 仍记录真正保存时刻，允许它晚于 `start_time + duration`；这是休眠恢复的事实，不要为了看起来整齐伪造墙钟时间。
