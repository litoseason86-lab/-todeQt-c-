# Plan 018: 恢复数据库时同步恢复番茄循环计数

> **Executor instructions**: 逐步执行，每个门都要验证。完成后更新索引；任何 STOP 条件出现即停止。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/services/FocusTimer.h src/services/FocusTimer.cpp src/services/BackupService.h src/services/BackupService.cpp tests/BackupServiceTests.cpp
> ```
>
> 017 未完成则先完成 017；共享的 `FocusTimer` 文件不得并行修改。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/017-detach-deleted-active-task.md`
- **Category**: bug
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

恢复数据库会替换任务、会话和设置，却没有替换内存里的 `completedPomodoros`。目标备份没有活动计时状态时，`restoreInterruptedSession()` 直接返回，旧库的循环计数因此泄漏到新库；恢复失败回滚时也没有明确还原原计数。结果是长休息节奏由已被替换的数据库状态决定。

## Current state

- `FocusTimer::completedPomodoros` 是当前番茄循环计数，并随 `active_focus_state.completed_pomodoros` 持久化。
- `src/services/FocusTimer.cpp:671-695`：目标库没有 `active_focus_state` 行时仅 `return cleanupOrphanedSessions();`，不会把内存计数归零。
- 同函数有活动态时会读取 `restoredPomodoros` 并在后段覆盖 `m_completedPomodoros`。
- `BackupService::requestRestore()` 只禁止活动专注/休息，没有捕获当前循环计数。
- `BackupService::RestoreContext` 目前只有路径和设置快照；同步回滚函数 `restoreFromPreRestoreSnapshot(...)` 也没有计数参数。
- 异步成功路径在 `installPreparedRestore()` 中调用 `restoreInterruptedSession()`；异步回滚在 `rollbackAsyncRestore()` 重新载入原库后调用同一函数。
- `tests/BackupServiceTests.cpp:516` 的 `asyncRestoreRollbackRestoresOriginalTaskCount` 已验证任务数回滚，可扩展为计时状态回滚测试。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-018 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-018 --target BackupServiceTests PomodoroTodoTests -j8` | exit 0 |
| 定向测试 | `cd /tmp/pt-018 && ctest -R '^(BackupServiceTests|PomodoroTodoTests)$' --output-on-failure` | 2/2 通过 |
| 全量测试 | `cd /tmp/pt-018 && ctest --output-on-failure` | 全部通过 |

## Scope

**In scope**：`src/services/FocusTimer.h`、`src/services/FocusTimer.cpp`、`src/services/BackupService.h`、`src/services/BackupService.cpp`、`tests/BackupServiceTests.cpp`。

**Out of scope**：把循环计数迁移到独立表；允许活动计时期间恢复；改变备份格式/schema；改变长休息阈值；QML；为测试暴露 `Q_INVOKABLE` 写接口。

## Git workflow

- 分支：`advisor/018-restore-pomodoro-loop-count`
- 中文提交信息：`恢复数据库时同步番茄循环计数`
- 不 push，不开 PR。

## Steps

### Step 1: 先锁定成功恢复与失败回滚语义

在 `BackupServiceTests` 添加/扩展三类用例：

1. 目标备份没有活动态：当前内存计数为 3，恢复成功后必须变成 0，并发一次 `completedPomodorosChanged`。
2. 目标备份含暂停的番茄休息态且计数为 3：恢复成功后必须得到 3，不能一律清零。
3. 扩展 `asyncRestoreRollbackRestoresOriginalTaskCount`：恢复前原内存计数为 3，诱发设置恢复失败后自动回滚，最终计数仍为 3。

测试类已经采用 friend 访问服务私有测试钩子；如需设初值，为 `BackupServiceTests` 增加与现有 `ServiceTests` 相同的受控 friend，不要增加 QML 可写接口。

**Verify**：产品代码未改时，至少“无活动态清零”和“失败回滚还原”应失败。全部通过则 STOP 检查测试隔离和单例残留。

### Step 2: 给 FocusTimer 增加单一的恢复赋值入口

新增一个仅 C++ 使用、非 `Q_INVOKABLE` 的方法，例如 `applyRestoredPomodoroCount(int count)`。它必须：

- 把负数夹到 0；
- 值没变化时不发 signal；
- 值变化时只赋值并发 `completedPomodorosChanged()`；
- 不自行持久化，因为调用时数据库刚被替换或正在回滚，持久化职责仍属于恢复流程。

`restoreInterruptedSession()` 无活动态分支先通过该方法设为 0，再清理孤儿会话；有活动态分支也复用该方法，删除对成员和 signal 的手抄赋值。补中文注释说明“无活动态代表目标库没有可恢复的循环状态，必须清掉来源库内存”。

**Verify**：编译通过；成功恢复两类测试通过。

### Step 3: 将原计数纳入同步和异步回滚上下文

- `requestRestore()` 在关闭数据库前记录 `FocusTimer::completedPomodoros()` 到 `RestoreContext::originalCompletedPomodoros`。
- 同步 `restoreBackup()` 也在任何替换前捕获同一值。
- 扩展 `restoreFromPreRestoreSnapshot(...)` 参数，在原数据库重新打开并调用 `restoreInterruptedSession()` 后，再应用捕获的原计数。顺序不能反：`restoreInterruptedSession()` 的无状态分支会归零。
- 异步 `rollbackAsyncRestore()` 同样在重新载入原库后应用 `context->originalCompletedPomodoros`。
- 只在数据库、设置和计时运行态恢复成功时标记整个回滚成功；不要让一个 signal 或赋值函数伪装数据库失败。

中文注释解释：循环计数是内存态，未必有活动行；因此恢复前必须单独快照，回滚时不能只依赖数据库。

**Verify**：异步回滚用例通过；现有同步回滚、数据库重开、设置恢复测试全部通过。

### Step 4: 全量回归和泄漏检查

连续执行两个成功恢复用例，确保第二个用例不继承第一个单例计数。测试 cleanup 必须把计数归零。

**Verify**：定向 2/2、全量全绿；`git diff --check` 无输出；只修改授权文件和索引状态。

## Test plan

- 无活动态目标库 → 计数 0。
- 有暂停休息态目标库 → 计数从目标库恢复。
- 异步恢复失败 → 原数据库、设置和原计数一起回来。
- 同步失败回滚同样保留原计数。
- 值未变不重复发 `completedPomodorosChanged`。

## Done criteria

- [ ] 无活动态恢复不再保留来源库计数。
- [ ] 有活动态恢复仍读取目标库的 `completed_pomodoros`。
- [ ] 同步和异步回滚都显式还原恢复前计数。
- [ ] 没有新增 QML 可写接口或 schema。
- [ ] 定向和全量 CTest 全绿，`git diff --check` 无输出。
- [ ] 018 状态行已更新。

## STOP conditions

- 017 未完成，或 `FocusTimer` 发生无法合并的漂移。
- 备份恢复已改成跨进程/重启后完成，内存快照不再可靠。
- 目标库活动态格式不再包含 `completed_pomodoros`。
- 修复需要修改备份文件格式或迁移版本。
- 验证连续两次失败且原因不在授权范围。

## Maintenance notes

- reviewer 要逐条检查成功、回滚、无活动态三条路径；只修成功路径仍会在失败恢复后留下错误循环数。
- `completedPomodoros` 是“当前连续循环”而非历史番茄总数，不能从 `focus_sessions` 聚合重建。
