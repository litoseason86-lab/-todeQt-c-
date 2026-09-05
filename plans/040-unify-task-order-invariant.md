# Plan 040: 定义并统一任务排序不变量，消除 0/正序号和写路径分裂

> **当前状态（2026-09-05）**：已完成并纳入当前分支；提交证据见 [状态索引](README.md)。下文的执行步骤、旧基线及未勾选验收项均为历史记录，不代表待执行；本轮全量验证 70/70 通过。

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 本计划先锁定产品口径，再改迁移和写路径。完整读完、逐步验证；
> 命中 STOP condition 时停止，不能只改一条 ORDER BY 把矛盾挪到别处。完成后更新索引状态。
>
> **Drift check（先跑）**：
> `git diff --stat f8e3120..HEAD -- src/services/DatabaseManager.h src/services/DatabaseManager.cpp src/services/TaskManager.h src/services/TaskManager.cpp src/services/RoutineManager.cpp qml/views/TodayTaskView.qml tests/ServiceTests.cpp tests/BackupServiceTests.cpp tests/qml/tst_task_reorder.qml`
> 任何文件变化都要重核所有写路径，不能按旧行号机械修改。

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: correctness / data invariant
- **Planned at**: commit `f8e3120`，2026-08-16

## 先拍板：唯一允许的排序语义

本计划采用以下口径；执行者无权临时改成另一套：

1. 生产库中每个任务的 `display_order` 必须是 **正整数**。`0` 只代表 v11 历史/半迁移状态，
   v12 初始化结束后不再允许存在。
2. 同一 `date` 内序号必须唯一；允许删除/改期留下间隙，不要求永久稠密。
3. 新建任务、例行任务、编辑改期、单任务改期、批量结转都追加到目标日期：`MAX + 1`。
4. 手动重排接收该日期**完整、无重复、无跨日期 ID**的集合，并重写为 `1..N`。
5. 查询仍先按 `completed ASC` 分组，再按 `display_order ASC`。因此“末尾”是所属完成状态组的末尾；
   新任务默认未完成，所以出现在未完成组末尾。
6. UI 只允许未完成任务在未完成组内拖动。待删除的 5 秒窗口内，UI 列表故意少于数据库完整集合，必须禁用排序。

为什么不继续保留 0：它同时被 v11 注释定义为“未排过”、被 ORDER BY 定义为“排最后”，又被 `MAX+1`
的新任务越过。三个语义互相冲突，没有任何局部 SQL 修补能让它们同时成立。

## Current state

### v11 把所有存量行留为 0（`DatabaseManager.cpp:1260-1267`）

```cpp
// 默认 0 ... 0 表示"没排过"
ALTER TABLE tasks ADD COLUMN display_order INTEGER NOT NULL DEFAULT 0
```

### 读取把正序号排在 0 前（`TaskManager.cpp:553-558`）

```sql
ORDER BY t.completed ASC,
CASE WHEN t.display_order = 0 THEN 1 ELSE 0 END ASC,
t.display_order ASC, t.created_at ASC, t.id ASC
```

### 写路径已经分裂

- `TaskManager.cpp:137-192` 的字符串科目 `addTask` 不写 `display_order`，得到 0。
- `TaskManager.cpp:240-249` 的整数科目重载写 `MAX(display_order)+1`，注释声称“新任务排在末尾”。
- `RoutineManager.cpp:368-372` 生成例行任务时不写排序列，得到 0。
- `TaskManager.cpp:437-448` 的 `updateTask` 改日期但保留原日期序号。
- `TaskManager.cpp:686-724` 的 `moveTasksToToday` 只改日期，保留旧序号。
- `TaskManager.cpp:851-858` 的 `moveTaskToDate` 已算目标日 `MAX+1`，但目标有 0 时仍会排到它们前面。

最小复现：同一天两条 v11 迁移任务为 0，再新增一条得到 1；查询结果是“新任务、旧甲、旧乙”。

### 服务契约写“完整顺序”，实现却不验证（`TaskManager.h:63-67` / `.cpp:800-821`）

实现不检查重复 ID、完整性或 `numRowsAffected()`；日期不匹配甚至被注释为“不是错误”。这会把重复序号写进库。

### UI 在两个窗口提交不完整/不可兑现的顺序

- `TodayTaskView.qml:405-414` 在 5 秒待删除期间过滤一条数据库仍存在的任务，但 `canReorderTasks:297-299`
  仍为 true。
- 完成行自身不可拖，但 `updateReorder():305-327` 允许未完成行把完成行当落点；数据库查询又强制完成项分组，
  指示线展示的位置无法兑现。

## Scope

**In scope**：

- `src/services/DatabaseManager.h/.cpp`（schema v12 与防御性归一化）
- `src/services/TaskManager.h/.cpp`
- `src/services/RoutineManager.cpp`
- `qml/views/TodayTaskView.qml`
- `tests/ServiceTests.cpp`
- `tests/BackupServiceTests.cpp`
- `tests/qml/tst_task_reorder.qml`
- `plans/README.md`（只更新状态）

**Out of scope**：

- 不做任意日期的跨日拖拽 UI 重构。
- 不增加 `(date, display_order)` UNIQUE 索引。本轮顺序更新逐行执行，直接加索引会在交换中间态撞约束；
  若要数据库硬约束，必须另做两阶段临时序号协议。
- 不改变“完成项固定在未完成项之后”的展示规则。
- 不做备份 Schema 全量白名单，也不处理备份资源预算。

## QML 离屏测试红线（必须内联遵守）

- **禁止断言 `visible === true`。** 本项目用 `QT_QPA_PLATFORM=offscreen`，`visible` 会沿父级可见性链级联，
  不能稳定表达组件业务状态。改断言业务属性、控件 `enabled`、`Popup.opened`、模型内容或信号参数。
- **所有“今天/日期”都走逻辑日。** 使用测试现有的 `logicalDayService`、`logicalToday()` 或注入固定 ISO 日期；
  不直接用物理日 `new Date()` 推导今天，否则凌晨 `dayStartHour` 前会得到偶发失败。
- **不要等待或监听 `Popup.onClosed` 作为完成判据。** 离屏环境不保证投递该生命周期回调。
  直接调用被测请求/提交函数，并断言业务状态、`opened` 或控件状态；不要靠 `onClosed` SignalSpy 结束测试。

## Implementation

### Step 1: 先补能复现 mixed 0/positive 的服务测试

在 `ServiceTests.cpp` 添加两条具名回归：

1. `mixedLegacyOrdersKeepNewTasksAtEnd()`：直接插入同日两个 `display_order=0` 的旧任务，再走正式 `addTask`；当前实现会让新任务跑到最前，
   测试要求新任务位于末尾。
2. `allTaskDateWritesAppendAfterLegacyRows()`：目标日期包含 0 行时，分别用编辑改期、`moveTaskToDate`、`moveTasksToToday` 移入任务，
   要求每条依次追加且序号为正、互不重复。

旧实现必须转红。不要只测目标日全是正序号；现有 `moveTaskToDateLandsAtTheEndOfTheTargetDay()` 已覆盖了那个容易路径。

**Verify**：运行 `~/pt-audit/PomodoroTodoTests mixedLegacyOrdersKeepNewTasksAtEnd`
→ 旧实现失败，输出显示新任务/移入任务越过了 display_order=0 的旧行。

### Step 2: 新增 v12 迁移，把当前可见顺序固化为正序号

在 `DatabaseManager`：

- `kCurrentSchemaVersion` 升为 12。
- 声明/实现 `migrateToVersion12()`。
- 复用 `backupDatabaseBeforeMigration()`，在一个事务里完成归一化和 `setDatabaseVersion(12)`。
- 在 `createTables()` 的 v11 之后接入 v12。

归一化必须按**迁移前真实可见顺序**对每个日期编号：

```sql
PARTITION BY date
ORDER BY completed ASC,
         CASE WHEN display_order = 0 THEN 1 ELSE 0 END ASC,
         display_order ASC,
         created_at ASC,
         id ASC
```

用 `ROW_NUMBER()` 生成 1..N，再回写 `display_order`。这样迁移不会凭空改变用户升级前看到的顺序，
只是把隐式 fallback 固化成显式序号。

`createTables()` 还要防御 user_version 已是 12、但数据仍含非正数或同日重复序号的半迁移/恢复库。
增加一次轻量 invariant 查询：按 date 分组检查 `MIN(display_order) <= 0` 或
`COUNT(DISTINCT display_order) != COUNT(*)`。查询失败不能假装“不需要迁移”；返回初始化失败并报告。

**兼容边界**：`ROW_NUMBER()` 要求 SQLite 3.25+。先用目标 Qt SDK 和最低支持运行时执行一条窗口函数探测；不支持则 STOP，
改用 C++ 按查询顺序逐行更新，不能静默降低最低系统兼容性。

**Verify**：运行新增 v11→v12 migration 用例
→ `user_version == 12`；每日期 `MIN(display_order) > 0`、distinct count 等于 row count；迁移前后标题顺序相同。

### Step 3: 所有生产写路径统一追加

提取一个私有、连接内使用的“目标日期下一个序号”helper，或使用一致的 SQL 子查询。
要求所有计算与写入处在同一事务/同一 SQL 原子语句里：

- 两组 `TaskManager::addTask` 重载都显式写 `display_order = MAX+1`。
- `RoutineManager::materializeToday()` 的 INSERT 同样写 `MAX+1`；同一事务生成多条例行时，后续 INSERT
  必须看到前一条未提交结果，得到连续且唯一的序号。
- `updateTask()` 先识别日期是否变化；同日编辑保留序号，跨日编辑写目标日 `MAX+1`。
- `moveTasksToToday()` 在现有事务内按输入顺序依次分配目标日 `MAX+1`，不能把原日期序号带过去。
- `moveTaskToDate()` 保留追加语义，并在 v12 后删除“0 仍合法”的过时注释。

每条 UPDATE/INSERT 都检查执行结果和受影响行数；任何失败 rollback，不能留下部分移动。

**Verify**：运行新增的 add/routine/update/move/rollover 数据驱动用例
→ 每个目标日按操作顺序追加，序号全为正且同日唯一，整组 0 failed。

### Step 4: 把 reorderTasks 的接口契约落实为事务校验

更新 `TaskManager.h` 注释，删除“0 保留给没排过”。实现流程：

1. 校验日期、非空列表、每个 ID 为正且无重复。
2. 在同一事务查询该日期真实 ID 集合。
3. 输入集合必须与数据库集合完全相等；多、少、跨日期均失败并 `reportFailure`。
4. 按输入顺序写 1..N，每条 `numRowsAffected() == 1`。
5. 任一步失败 rollback，不发 `tasksChanged`；全部成功才 commit/发信号。

不要延续“刚被改期走的任务不是错误”这一宽松口径。调用方过期就是并发/状态失配，静默接受只会制造重复排序。

**Verify**：运行 reorder 拒绝用例
→ 重复、缺失、额外、跨日四组都返回 false，且每组操作前后的 `(id, display_order)` 完全相同。

### Step 5: 收紧 TodayTaskView 拖拽边界

- `canReorderTasks` 增加 `pendingDeleteTaskId <= 0`。待删除开始时若已有拖拽，清掉
  `draggingTaskId/dropTargetIndex`，避免松手提交旧状态。
- `updateReorder()` 不能把完成行设为落点。计算第一个 completed index，将 target 限制在未完成区间；
  若没有合法未完成落点则清空 target。
- `commitReorder()` 继续传完整数组（含末尾完成项），与服务完整集合契约一致。
- 拖动指示线必须使用夹紧后的实际 target，不能仍画在完成行附近。

在 `tst_task_reorder.qml` 增加：待删除时 `canReorderTasks == false` 且零 service 调用；拖向完成行时落点被限制在最后一个未完成位置，
最终 ID 顺序与指示线一致。

**Verify**：运行 `ctest --test-dir ~/pt-audit -R '^QmlTest.task_reorder$' --output-on-failure`
→ 新增两条边界用例和既有长列表/指示线用例全部通过。

### Step 6: 迁移与全部写路径测试

在 `ServiceTests.cpp` 增加：

- 构造 v11 mixed 0/positive、完成/未完成、相同 created_at 的库，调用 `createTables()`；断言可见顺序与迁移前规则一致、
  全部序号 >0 且同日唯一、`user_version == 12`。
- 再次 `createTables()` 幂等，顺序和序号不变。
- 字符串科目 add、整数科目 add、例行生成、编辑改期、单任务改期、批量结转全部追加。
- `reorderTasks` 对重复、缺失、额外、跨日期 ID 均返回 false，且失败前后数据库序号完全一致。

在 `BackupServiceTests.cpp` 扩展旧 Schema 恢复用例：恢复合法 v11 备份后应自动迁到 12，原任务可见且排序不变量成立。
这不是 Schema 全量白名单；只验证本应用自己 v11 → v12 的兼容链。

**Verify**：分别运行 `PomodoroTodoTests` 与 `BackupServiceTests`
→ v12 migration 幂等、全部写路径、旧备份恢复均 0 failed。

### Step 7: 证伪关键断言

至少做三次局部 mutation：

- 临时跳过 v12 回填，migration 测试应红。
- 临时让一条新增路径写 0，append 测试应红。
- 临时移除 reorder 完整集校验，拒绝测试应红。

每次还原后 `touch` 被还原文件再重建，防止旧对象文件造成假绿。证伪改动不提交。

**Verify**：三次 mutation 各自使指定用例转红；最终还原后定向三组和全量 CTest 均通过，`git diff` 无临时改坏代码。

## Test plan

- 迁移：v11 mixed 0/positive、完成分组、时间/id tie-break、幂等、防御性重入。
- 写路径：两类 add、routine materialize、编辑改期、单项改期、批量结转。
- 服务契约：完整成功；重复/缺失/额外/跨日期全部原子失败。
- QML：待删除禁拖、完成区落点夹紧、既有滚动长列表落点不退化。
- 备份兼容：合法 v11 备份恢复后由正式初始化链升 v12。

## Verification

```bash
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build ~/pt-audit -j8
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit -R '^PomodoroTodoTests$' --output-on-failure --timeout 240
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit -R '^BackupServiceTests$' --output-on-failure --timeout 240
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit -R '^QmlTest.task_reorder$' --output-on-failure
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8
```

预期：三组定向测试与全量测试通过，无新增 warning；不启动 GUI。

## Done criteria

- v12 初始化成功后，生产库不存在 0/负序号或同日重复序号。
- 所有新增/改期/结转/例行写路径都追加到目标日期。
- 手动重排拒绝任何非完整、重复或跨日期集合，失败全回滚。
- 待删除窗口不允许排序，未完成任务不能落到完成组。
- v11 备份仍可恢复并自动迁移；不引入 Schema 全量白名单。
- mixed 0/positive 的旧库复现从失败转为通过。

## STOP conditions

- 产品不接受“0 只属于历史数据”，仍要保留“未手排”这一第三状态；必须先重新定义新任务和跨日任务与该状态的相对顺序。
- 最低支持的 Qt SQLite 不支持窗口函数，且执行者尚未改为等价的事务内逐行回填。
- 发现还有本计划未列出的生产 SQL 直接插入/改期 `tasks`；先补入 scope，不能留半套不变量。
- v11 合法备份被当前恢复预检拒绝，说明恢复兼容策略与版本迁移链冲突，需要先解决入口策略。

## Maintenance notes

- 今后任何直接写 `tasks.date` 或插入 tasks 的 SQL 都必须同时维护 `display_order`；reviewer 应全仓搜 INSERT/UPDATE。
- 如果未来加入同日并发写或多进程写，服务层“先 MAX 后写”不足以保证唯一，应升级为数据库约束和冲突安全分配。
- 完成状态若改成可跨组拖动，必须同时重定义查询 ORDER BY、UI 指示线和 reorder 完整集，不能只改 delegate。
- Schema 全量白名单与备份资源预算明确延期，不得借 v12 排序迁移夹带实现。

## Git workflow

- 建议分支：`advisor/040-unify-task-order-invariant`
- 建议提交：`统一任务排序不变量并迁移旧序号`
- 不 push、不创建 PR，除非维护者明确要求。
