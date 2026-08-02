# Plan 017: 删除正在专注的任务时立即解除计时器关联

> **Executor instructions**: 按顺序执行并验证。完成后更新 `plans/README.md`；出现 STOP 条件不要自行扩展设计。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/services/TaskManager.h src/services/TaskManager.cpp src/services/FocusTimer.h src/services/FocusTimer.cpp src/main.cpp tests/ServiceTests.cpp
> ```
>
> 有输出时必须核对下文符号与语义；计划 016 未完成则先执行 016。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/016-cap-natural-pomodoro-duration.md`
- **Category**: bug
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

SQLite 会在删除任务时把 `active_focus_state.task_id` 置空，但内存中的 `FocusTimer::m_currentTaskId` 仍指向已删除任务。之后每次 checkpoint 又可能把悬空 ID 写回活动态，结束专注还会制造一次必然失败的“自动完成任务”告警。正确行为是删除事务成功后立即通知计时器解除关联，同时保留标题快照与已累计专注。

## Current state

- `src/services/TaskManager.cpp:387-437`：`deleteTask` 在事务内先解绑历史会话，再删任务，成功后只发 `tasksChanged()`。
- `src/services/TaskManager.h` 目前只有 `tasksChanged()` 与 `operationFailed()`，没有带 task id 的删除事实信号。
- schema 对 `active_focus_state.task_id` 使用 `ON DELETE SET NULL`，数据库态能解绑，但不会自动改 C++ 内存。
- `FocusTimer::persistActiveState()` 仍绑定内存中的 `m_currentTaskId`；如果不清理，它可能重写悬空值并导致外键失败。
- `tests/ServiceTests.cpp:4029-4044` 的 `focusAutoCompleteFailureIsReported` 把“删除活动任务后结束必然报警”当成正确行为，这条测试必须改写。
- `tests/ServiceTests.cpp:4124-4154` 的 `restoreKeepsSessionWhenTaskWasDeleted` 已证明从数据库恢复时，`task_id=-1`、标题快照保留、会话继续完成是正确语义，应作为实现参照。
- 跨服务装配放在 `src/main.cpp`；不要让 `TaskManager` 直接 include 或调用 `FocusTimer`。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-017 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-017 --target PomodoroTodoTests PomodoroTodo -j8` | exit 0 |
| 定向测试 | `cd /tmp/pt-017 && ctest -R '^PomodoroTodoTests$' --output-on-failure` | 1/1 通过 |
| 全量测试 | `cd /tmp/pt-017 && ctest --output-on-failure` | 全部通过 |

## Scope

**In scope**：`src/services/TaskManager.h`、`src/services/TaskManager.cpp`、`src/services/FocusTimer.h`、`src/services/FocusTimer.cpp`、`src/main.cpp`、`tests/ServiceTests.cpp`。

**Out of scope**：改变删除事务或外键策略；删除专注历史；自动关闭正在运行的计时器；清空任务标题快照；QML 提示与撤销 UI；改变 `taskAutoCompleteFailed` 对其他真实失败的语义。

## Git workflow

- 分支：`advisor/017-detach-deleted-active-task`
- 中文提交信息：`删除活动任务时解除计时器关联`
- 不 push，不开 PR。

## Steps

### Step 1: 先把旧错误期望改成新契约

重写 `focusAutoCompleteFailureIsReported`，命名为能表达新行为的用例。测试类增加一个 `QMetaObject::Connection` 成员，在 `initTestCase()` 建立与生产相同的连接：`TaskManager::taskDeleted(int)` → `FocusTimer::detachDeletedTask(int)`，在 `cleanupTestCase()` 断开。只建立一次，避免逐用例连接在 `QVERIFY` 提前返回时泄漏并累积。

覆盖运行态和暂停态两种删除：

- 删除后 `currentTaskId == -1`，`currentTaskTitle` 不变，活动会话仍存在。
- `currentTaskChanged` 恰好发生一次。
- 查询 `active_focus_state.task_id IS NULL`。
- 后续 checkpoint、恢复/暂停、`stopFocus()` 均成功，不发 `taskAutoCompleteFailed`。
- 已结束 `focus_sessions.task_id IS NULL` 且 duration 正常。

保留一条真实自动完成失败的测试路径；若现有测试无法安全制造 DB 写失败，可继续保留该 signal 的其他既有覆盖，不要为了造失败增加产品钩子。

**Verify**：新测试在信号/方法尚未实现时编译失败；这就是红灯。若无需产品改动即通过，STOP 检查测试是否真的连到删除事实。

### Step 2: 让任务服务只发布成功删除事实

在 `TaskManager` 新增 `void taskDeleted(int taskId)`。只在删除事务 `commit()` 成功后发出；顺序为先 `taskDeleted(taskId)`，再 `tasksChanged()`。失败、无效 id、未找到任务、回滚路径一律不得发。

补中文注释说明该信号用于让持有任务引用的其他服务在提交后解除关联，不能在事务提交前发出。

**Verify**：编译 `PomodoroTodoTests` 成功；失败删除的既有测试仍通过。

### Step 3: 在计时器中提供非 QML 的幂等解绑槽

在 `FocusTimer` public slots 或普通 public API 增加 `void detachDeletedTask(int taskId)`，不要标 `Q_INVOKABLE`。行为：

1. `taskId <= 0`、没有活动计时器、或 id 与当前任务不符时直接返回且不发信号。
2. 匹配时仅把 `m_currentTaskId` 设为 `-1`，保留标题、session、phase、elapsed 和运行状态。
3. 活动态存在时立即 `persistActiveState()`，让数据库保持 NULL；失败时发既有 `operationFailed`，但不能撤销已经提交的任务删除，也不能恢复悬空 id。
4. 最后发一次 `currentTaskChanged()`。

注释解释“删除已提交，解绑持久化失败只能告警，不能回滚跨服务事务”。

**Verify**：定向测试通过；暂停态和运行态都不再产生自动完成失败。

### Step 4: 在 composition root 装配跨服务信号

在 `src/main.cpp`、QML engine 创建前加入：

```cpp
QObject::connect(TaskManager::instance(), &TaskManager::taskDeleted,
                 FocusTimer::instance(), &FocusTimer::detachDeletedTask);
```

放在其他跨服务装配附近，并用中文说明依赖方向：任务服务发布事实，计时器消费；两者不互相 include。

**Verify**：应用目标编译成功；`rg -n "taskDeleted|detachDeletedTask" src/main.cpp src/services tests/ServiceTests.cpp` 显示声明、单一产品连接和测试连接。

### Step 5: 全量回归与范围核查

**Verify**：全量 CTest 全绿；`git diff --check` 无输出；`git status --short` 没有授权范围外产品文件。

## Test plan

- 成功删除运行中的活动任务。
- 成功删除暂停中的活动任务。
- 删除其他任务、无效 id、重复通知均为 no-op。
- 删除后活动态 task_id 为 NULL，标题和专注进度保留。
- 结束会话不再发伪 `taskAutoCompleteFailed`。
- 原有“跨重启时任务已删除”的恢复用例继续通过。

## Done criteria

- [ ] `taskDeleted` 只在删除 commit 成功后发出。
- [ ] `detachDeletedTask` 幂等、非 QML API、不停止计时。
- [ ] 删除活动任务后内存与 `active_focus_state` 都是无任务关联状态。
- [ ] 运行态、暂停态和恢复路径有自动化覆盖。
- [ ] 定向与全量测试全绿，`git diff --check` 无输出。
- [ ] 017 状态行已更新。

## STOP conditions

- 计划 016 未完成或 `completeFocusSession` 基线与其结果冲突。
- 删除逻辑已被改成软删除或不再使用当前事务。
- 解绑必须跨线程或跨进程完成。
- 正确实现需要 TaskManager 直接依赖 FocusTimer，或需要修改 schema。
- 验证连续两次失败且原因超出授权文件。

## Maintenance notes

- reviewer 要确认 signal 在 commit 后发，且解绑失败没有把已删除 id 填回内存。
- 未来若任务支持恢复/撤销，恢复的是任务实体；活动计时器是否重新绑定必须另定契约，不能默认反向绑定。
