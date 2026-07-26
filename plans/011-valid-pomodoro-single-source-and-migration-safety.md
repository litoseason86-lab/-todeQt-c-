# Plan 011: 把「有效番茄」口径收回唯一事实源，并堵住迁移的两个数据安全缺口

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> 本仓库有一批**尚未提交**的工作区改动，本计划针对的正是这批代码，
> 所以 **`git diff <SHA>..HEAD` 形式的漂移检查在这里无效**。改用 grep 判据：
>
> ```bash
> grep -n "duration >= 180" src/services/DatabaseManager.cpp          # 必须命中 1 行（这是要修的目标）
> grep -n "f.mode = 1 AND f.pomodoro_completed = 1" src/services/StatisticsService.cpp   # 必须命中（要修的目标）
> grep -n "inline QString validPomodoroCountExpr()" src/services/FocusSessionRules.h     # 必须命中（无参版本）
> grep -n "index = 3" src/services/DatabaseManager.cpp                 # 必须命中 pruneOldBackups 里的保留数
> grep -n "migrationV8BackfillsPomodoroCompletedPerRow" tests/ServiceTests.cpp  # 必须命中 → plans/010 已落地
> ```
>
> **最后一条不命中 = plans/010 尚未执行 → 直接 STOP。** 本计划要改的正是那些回填语句，
> 没有 010 的逐行断言做安全网就动它们，等于无保护地改写用户历史数据。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW（改动后 SQL 语义与今天完全等价；010 的测试负责证明这一点）
- **Depends on**: plans/010-migration-backfill-characterization-tests.md（**硬依赖**）
- **Category**: bug / tech-debt
- **Planned at**: commit `43ba2ee`（+ 未提交工作区），2026-07-26

## Why this matters

`src/services/FocusSessionRules.h` 是本项目唯一一处定义「什么算一个有效番茄」的地方，
它的注释白纸黑字写着：**「不允许在别处复制出第二套阈值或模式判断」**。

这条规则目前有两处违反，都在未提交的这批改动里。它们今天恰好和事实源等价，
所以测试全绿——但等价是巧合，不是保证：只要有人改了 `kMinimumValidDurationSeconds`，
这两处会**静默保持旧阈值**，用户的历史番茄数从此和当前番茄数按两套标准计算，没有任何报错。

同一批改动还带来两个数据安全缺口：v8 的回填 `UPDATE` 没有守卫，重入时会用启发式结果
覆盖真实记录；迁移前快照只保留 3 个，而迁移链现在有 5 步，最早那个（也就是唯一早于
所有破坏性回填的）快照会被自动删掉。

四处改动都很小、都不改变今天的行为，价值全在于「明天不会悄悄出错」。

## Current state

### 缺口 1：v8 回填硬编码了阈值和模式（`src/services/DatabaseManager.cpp:745-752`）

```cpp
// 旧版没有保存"自然到点"事实，无法完美还原。为避免升级后历史番茄归零，
// 只对升级前已完成、且达到有效门槛的番茄模式记录做一次兼容回填。
if (!query.exec(QStringLiteral(
        "UPDATE focus_sessions SET pomodoro_completed = "
        "CASE WHEN mode = 1 AND end_time IS NOT NULL AND duration >= 180 THEN 1 ELSE 0 END"))) {
```

`mode = 1` 和 `180` 都是手抄的字面量。事实源里对应的是
`FocusSessionRules::kPomodoroMode` 和 `FocusSessionRules::kMinimumValidDurationSeconds`。

### 缺口 2：v8 回填无守卫、无 WHERE（同一处）

上面那条 `UPDATE` **无条件重写全表每一行**。它前面的 `ALTER TABLE` 是有守卫的
（`src/services/DatabaseManager.cpp:732`，用 `columnExists` 判断），但 `UPDATE` 没有。

而 v8 的进入条件（`src/services/DatabaseManager.cpp:263-270`）是：

```cpp
if (version < 8
    || !columnExists(QStringLiteral("focus_sessions"),
                     QStringLiteral("pomodoro_completed"))) {
    if (!migrateToVersion8()) { return false; }
    version = 8;
}
```

即 `user_version < 8` **或** 列不存在。所以「版本号 < 8 但列已存在」这个组合会
**再跑一次回填**，把用户真实的 `pomodoro_completed = 0`（手动停止的番茄）
按启发式重新刷成 1——恰好摧毁 v8 存在的意义。

**诚实的风险评估**：我没能构造出一条纯粹的正式用户路径抵达这个状态
（ALTER + 回填 + 版本号写入在同一个事务里，崩溃会整体回滚）。
但 `tests/BackupServiceTests.cpp:80-95` 的 `setBackupSchemaVersion` 能构造出它，
说明它并非纯理论。修它的成本是一个 `if`，而它保护的是**不可恢复的用户数据**。
按这个性价比做，不要因为「大概触发不了」就跳过。

### 缺口 3：迁移前快照只留 3 个，迁移链有 5 步

`src/services/DatabaseManager.cpp:983` 起的 `backupDatabaseBeforeMigration()`
在**每一步迁移前**都被调用（全文共 7 个调用点：行 342/466/509/634/678/723/770），
每次都用 `VACUUM main INTO` 生成一份快照，然后调 `pruneOldBackups()`。

`pruneOldBackups`（`src/services/DatabaseManager.cpp:1019-1033`）：

```cpp
// 只保留最近三个迁移备份，避免反复测试或启动应用时悄悄塞满数据目录。
const QFileInfoList backups = databaseDir.entryInfoList(
    QStringList{QStringLiteral("pomodoro_backup_*.db")}, QDir::Files, QDir::Time);

for (int index = 3; index < backups.size(); ++index) {
    if (!QFile::remove(backups.at(index).absoluteFilePath())) { /* warn */ }
}
```

`QDir::Time` 是**最新在前**，所以保留最新 3 个、删掉更老的。
一个还停在 v4 的旧库启动一次会依次生成 before-v5 / v6 / v7 / v8 / v9 五份快照，
最终留下 v7/v8/v9 三份，**before-v5 和 before-v6 被删掉**。

**准确的影响面（不要夸大）**：破坏性最强的 v8/v9 回填，它们各自的前置快照是保留的。
真正丢掉的是「所有迁移之前」的原始状态。这为什么仍然要紧：v5 迁移会用一份
**冻结在当年的列清单重建 `tasks` 表**（已在上一轮审计中记录为独立缺陷），
而能从 v5 事故中恢复的那份快照，正好是被删掉的 before-v5。

顺带一提：`VACUUM INTO` 是逐页重建整库，一次启动跑 5 次，是纯粹的浪费。
按整条链只做一次快照，同时解决保留策略和这个开销。

### 缺口 4：`validPomodoroCountExpr()` 没有别名参数

`src/services/FocusSessionRules.h` 全文（39 行，短，全文贴出）：

```cpp
namespace FocusSessionRules {

// 少于 3 分钟的会话属于误触或测试残留，不进入历史、统计和导出。
inline constexpr int kMinimumValidDurationSeconds = 3 * 60;

// 自动完成任务的门槛高于"有效记录"门槛：3 分钟可以记历史，5 分钟才算任务推进完成。
inline constexpr int kAutoCompleteTaskDurationSeconds = 5 * 60;

// 番茄工作模式在 focus_sessions.mode 里的取值；自由计时(正向计时)是 0。
inline constexpr int kPomodoroMode = 1;

// 一条专注记录计入"实际番茄"，当且仅当：番茄工作模式、自然到点，
// 且时长达到有效专注门槛。手动停止只保留专注时长，不伪装成完整番茄。
// 自由计时只累计专注分钟，不折算番茄。这是"有效番茄"的唯一口径，任务列表聚合、
// 单任务查询和长期目标进度都从这里取；不允许在别处复制出第二套阈值或模式判断。
// 放在本头文件而不是某个服务的匿名命名空间里，就是为了让多个服务能共享同一份定义。
inline QString validPomodoroPredicate(const QString& tableAlias = QString())
{
    const QString prefix = tableAlias.isEmpty() ? QString() : tableAlias + QLatin1Char('.');
    return QStringLiteral(
               "%1pomodoro_completed = 1 AND %1mode = %2 "
               "AND %1duration >= %3")
        .arg(prefix).arg(kPomodoroMode).arg(kMinimumValidDurationSeconds);
}

inline QString validPomodoroCountExpr()
{
    return QStringLiteral("SUM(CASE WHEN %1 THEN 1 ELSE 0 END)")
        .arg(validPomodoroPredicate());
}

}
```

注意：`validPomodoroPredicate` **有**别名参数，`validPomodoroCountExpr` **没有**。
后果在 `src/services/GoalService.cpp:296`——热力图查询 `JOIN` 了 `focus_sessions fs` 和
`tasks t` 两张表，却只能调无参版本，于是生成裸列名 `pomodoro_completed = 1 AND mode = 1 ...`。
今天能跑对，纯粹因为 `tasks` 表恰好没有同名列（`src/services/DatabaseManager.cpp:138-149`）。
哪天给 `tasks` 加一个 `duration` 列——对番茄应用来说完全合理——这条查询就变成
歧义列名错误，表现为热力图永远空白。

`validPomodoroCountExpr` 的三个调用点：
- `src/services/TaskManager.cpp:65`（包了一层同名本地函数）→ `:91`、`:650`
- `src/services/GoalService.cpp:296`

### 缺口 5：`StatisticsService.cpp:875` 的第三份副本

```cpp
SUM(CASE WHEN f.mode = 1 AND f.pomodoro_completed = 1 ...
```

它正上方（`:850` 附近）的注释还声称口径复用自 `FocusSessionRules`。
它今天等价，是因为外层 CTE 已经过滤了 `duration >= :minDuration`——
这种「靠远处另一段代码维持正确」的等价最容易在重构时断掉。

### 项目约定

- **注释必须是中文**，解释「为什么」和「边界条件」。数据库迁移、事务、兼容旧数据的逻辑
  属于必须注释的类别。
- 分层：`src/services` / `src/models` / `qml` / `tests` 职责不混。

## Commands you will need

构建目录**必须在仓库外**，且**必须传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**
（该选项默认 ON 且部署目标挂在 `ALL` 上，不关会覆盖 `/Applications/番茄Todo.app`）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-011 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-011 -j8` | exit 0 |
| 主测试 | `QT_QPA_PLATFORM=offscreen /tmp/pt-011/PomodoroTodoTests` | 全过（含 010 新增的 6 个） |
| 目标测试 | `QT_QPA_PLATFORM=offscreen /tmp/pt-011/GoalServiceTests` | 全过 |
| 备份测试 | `QT_QPA_PLATFORM=offscreen /tmp/pt-011/BackupServiceTests` | 全过 |
| 全量 | `cd /tmp/pt-011 && ctest --output-on-failure` | `100% tests passed ... out of 12` |

## Scope

**In scope**：
- `src/services/FocusSessionRules.h` — 给 `validPomodoroCountExpr` 加别名参数
- `src/services/GoalService.cpp` — 热力图查询传别名 `"fs"`（`:296`）
- `src/services/TaskManager.cpp` — 跟随新签名（`:65`）
- `src/services/StatisticsService.cpp` — `:875` 换成事实源
- `src/services/DatabaseManager.cpp` — v8 回填引用常量 + 加守卫；快照改为整链一次
- `tests/ServiceTests.cpp` — 新增守卫与快照保留的测试

**Out of scope**（看着相关也不许碰）：
- **`FocusSessionRules` 里的任何常量值** —— `180`、`5*60`、`kPomodoroMode = 1` 一个都不许改。
  本计划是「把散落的副本收回事实源」，不是「调整口径」。改数值是产品决策。
- **v8 回填的判定逻辑本身** —— 只把字面量换成常量引用，
  生成的 SQL 必须与今天**逐字符等价**（除了空白）。不要顺手"优化"这条 CASE WHEN。
- `plans/010` 新增的那些测试 —— 它们必须原样通过。改动它们才能通过 = 你改变了迁移语义。
- 仪表盘 / `getFocusSessionCount` 的口径 —— 那是 plans/012，本计划不碰。
- 任何 `qml/` 文件。

## Git workflow

- 分支：`advisor/011-valid-pomodoro-single-source`
- 中文提交信息，建议按步骤分 3 次提交：
  `有效番茄口径统一由 FocusSessionRules 提供` /
  `v8 回填只在新增列时执行，避免覆盖真实记录` /
  `迁移前快照按整条链只做一次`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 给 `validPomodoroCountExpr` 加别名参数

`src/services/FocusSessionRules.h`：

```cpp
// 与 validPomodoroPredicate 一样必须能带表别名：多表 JOIN 里裸列名会被外层表意外解析，
// 一旦别的表出现同名列就变成歧义列名错误，而且是静默的（查询返回空而不是报错）。
inline QString validPomodoroCountExpr(const QString& tableAlias = QString())
{
    return QStringLiteral("SUM(CASE WHEN %1 THEN 1 ELSE 0 END)")
        .arg(validPomodoroPredicate(tableAlias));
}
```

然后把 `src/services/GoalService.cpp:296` 改成传 `QStringLiteral("fs")`。
同文件 `:153` 已经正确传了 `"fs"` 给 predicate 版本，照那个写法。

`src/services/TaskManager.cpp:63-65` 的本地包装函数跟随新签名（它的调用场景是
相关子查询，也应该传自己的别名——去 `:91` 和 `:650` 看它实际用在哪个别名下，
传对应的那个；看不出来就保持无参并在报告里说明）。

**Verify**: `cmake --build /tmp/pt-011 -j8` → exit 0，且
`QT_QPA_PLATFORM=offscreen /tmp/pt-011/GoalServiceTests` → 全过（热力图用例会覆盖这条查询）

### Step 2: 收编 `StatisticsService.cpp:875` 的副本

把手写的 `f.mode = 1 AND f.pomodoro_completed = 1` 换成
`FocusSessionRules::validPomodoroPredicate(QStringLiteral("f"))`。

注意 predicate 比原式**多一个 `duration >= 180` 条件**。
原式靠外层 CTE 的 `duration >= :minDuration` 保证等价，所以加上这个条件后
**结果集不变**——但你必须实际验证这一点，别只是推理。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-011/PomodoroTodoTests weekly` → 每周复盘相关用例全过
（若无匹配槽名，跑全量 `PomodoroTodoTests` 并确认用例数与通过数都不变）

### Step 3: v8 回填引用常量，并加上「仅在新增列时回填」的守卫

`src/services/DatabaseManager.cpp` 的 `migrateToVersion8()`：

```cpp
QSqlQuery query(m_db);
// 记下本次是否真的新增了列：只有新增列时才需要回填。
// 若列已存在（例如恢复了一个更新版本的库、或半迁移状态），说明每行的
// pomodoro_completed 已经是真实记录的事实，用启发式再刷一遍会把
// "用户手动停止"错误地改写成"自然到点"，且不可恢复。
const bool columnJustAdded = !columnExists(QStringLiteral("focus_sessions"),
                                           QStringLiteral("pomodoro_completed"));
if (columnJustAdded) {
    if (!query.exec(QStringLiteral("ALTER TABLE focus_sessions ADD COLUMN ..."))) { /* 原样 */ }
}

if (columnJustAdded) {
    // 旧版没有保存"自然到点"事实，无法完美还原。为避免升级后历史番茄归零，
    // 只对升级前已完成、且达到有效门槛的番茄模式记录做一次兼容回填。
    // 阈值与模式取自 FocusSessionRules，不在此处复制第二套判断。
    if (!query.exec(QStringLiteral(
            "UPDATE focus_sessions SET pomodoro_completed = "
            "CASE WHEN mode = %1 AND end_time IS NOT NULL AND duration >= %2 "
            "THEN 1 ELSE 0 END")
            .arg(FocusSessionRules::kPomodoroMode)
            .arg(FocusSessionRules::kMinimumValidDurationSeconds))) { /* 原样 rollback */ }
}
```

记得加 `#include "FocusSessionRules.h"`（若尚未包含）。

**这一步的关键约束**：生成的 SQL 字符串必须与改动前**逐字符等价**。
建议临时 `qDebug()` 打印一次比对，确认后删掉调试输出。

**Verify**:
`QT_QPA_PLATFORM=offscreen /tmp/pt-011/PomodoroTodoTests migrationV8` →
plans/010 新增的 v8 用例**全部原样通过**。
**若有任何一条变红 → STOP**：说明你改变了回填语义，而不是等价重写。

### Step 4: 给守卫补一个测试

在 `tests/ServiceTests.cpp` 新增：

```cpp
void ServiceTests::migrationV8DoesNotRewriteExistingCompletionFacts()
```

构造「列已存在、且某行 `pomodoro_completed = 0` 但满足 mode=1/已结束/duration≥180」
的数据库（可复用 plans/010 的 v7 夹具，先 initialize 一次让列建好，
再手动把某行改成 0 且把 `PRAGMA user_version` 改回 7），再 `initialize()` 一次，
断言那一行**仍然是 0**。

改动前这条测试必然红（这就是它的价值），改动后应转绿。
建议先写测试确认它红，再确认 Step 3 让它绿。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-011/PomodoroTodoTests migrationV8DoesNotRewrite` → 1 passed

### Step 5: 迁移前快照改为整条链只做一次

目标：`backupDatabaseBeforeMigration()` 在一次 `createTables()` 调用中**最多执行一次**，
而不是每个 `migrateToVersionN()` 各执行一次。

推荐做法（改动最小、语义最清楚）：在 `DatabaseManager` 加一个成员标志
（例如 `mutable bool m_migrationSnapshotTaken = false;`），
`backupDatabaseBeforeMigration()` 开头判断，已做过就直接返回 true。
在 `createTables()` 开始处（判断出 `version < kCurrentSchemaVersion` 之后）重置为 false。

保留 7 个调用点不动——这样「每步迁移前都尝试快照」的意图仍然写在代码里，
只是实际只会落地一份，且是**最早**那份（真正的迁移前原始状态）。

必须加中文注释说明理由：

```cpp
// 一次启动可能连跨多级迁移（例如 v4 直接升到 v9）。若每级都生成快照，
// pruneOldBackups 的"保留最近三个"会把最早那份——也就是唯一早于所有
// 破坏性回填的原始状态——自动删掉，恰好丢掉出事时最该有的那份。
// 同时 VACUUM INTO 是逐页重建整库，连跑五次纯属浪费。
```

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-011/PomodoroTodoTests migrationCreatesDatabaseBackup` → 通过
（既有槽，见 `tests/ServiceTests.cpp:2821`）

### Step 6: 给快照策略补一个测试

```cpp
void ServiceTests::multiStepMigrationKeepsOnlyThePreMigrationSnapshot()
```

用 plans/010 的 v7 夹具（或更老的 v1 夹具，跨的级数更多）触发多级迁移，
断言 `pomodoro_backup_*.db` 的数量为 **1**，且用独立连接打开它、
`PRAGMA user_version` 读出来等于**迁移前**的版本号。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-011/PomodoroTodoTests Snapshot` → 通过

### Step 7: 全量回归 + 判据自检

**Verify**:
```
cd /tmp/pt-011 && ctest --output-on-failure
grep -rn "duration >= 180" src/          # 期望：无输出
grep -rn "mode = 1" src/ | grep -v FocusSessionRules.h   # 期望：无输出
```

## Test plan

- **新增** `migrationV8DoesNotRewriteExistingCompletionFacts`（Step 4）——锁住守卫
- **新增** `multiStepMigrationKeepsOnlyThePreMigrationSnapshot`（Step 6）——锁住快照策略
- **回归**：plans/010 的 6 个用例必须原样通过，一条都不许改
- 结构范式照 `tests/ServiceTests.cpp:2821` 的 `migrationCreatesDatabaseBackup`
- 验证：`ctest` 12/12，`PomodoroTodoTests` 用例数 = 010 之后的基线 + 2

## Done criteria

全部必须成立：

- [ ] `cd /tmp/pt-011 && ctest --output-on-failure` → 12/12 通过
- [ ] `grep -rn "duration >= 180" src/` → **无输出**
- [ ] `grep -rn "mode = 1" src/ | grep -v FocusSessionRules.h` → **无输出**
- [ ] `grep -n "validPomodoroCountExpr(const QString&" src/services/FocusSessionRules.h` → 命中
- [ ] `grep -n "columnJustAdded" src/services/DatabaseManager.cpp` → 命中
- [ ] plans/010 新增的 6 个用例**一条未改**（`git diff` 里 `tests/ServiceTests.cpp`
      只有新增，没有对 010 那些槽的修改）
- [ ] `FocusSessionRules.h` 里三个常量的**数值**与改动前完全一致
- [ ] `plans/README.md` 中 011 的状态行已更新

## STOP conditions

停下报告，不要自行发挥：

- Drift check 任一判据不命中，特别是 **plans/010 的用例不存在**（→ 先执行 010）。
- plans/010 的任何一条迁移用例在你的改动后变红。
  这意味着你改变了用户可见的迁移语义，而不是做了等价重写。**不要改测试让它绿。**
- Step 2 之后每周复盘/统计相关数字发生变化 —— 说明 predicate 与原式并不等价，
  报告你观察到的差异。
- 你发现要让某处收编生效，必须修改 `FocusSessionRules` 里的常量数值。
- 你发现 `TaskManager.cpp:91` / `:650` 的两个调用点需要**不同的**表别名，
  而单一默认参数无法同时满足 —— 报告，不要自创第二个辅助函数。

## Maintenance notes

- 这条规则的执行者是 done criteria 里那两条 grep。将来审查任何触及统计/聚合的 PR，
  跑一遍 `grep -rn "duration >= 180\|mode = 1" src/`——非空就是回归。
- Step 5 之后，`pruneOldBackups` 的「保留 3 个」不再与迁移链长度耦合，
  以后加 v10、v11 都不会再挤掉原始快照。但**如果有人把快照改回每步一份，
  这个耦合会立刻复活**——审查时要盯住 `m_migrationSnapshotTaken` 是否还在。
- 本计划刻意**没有**碰一个已知的产品问题：v8 回填让「升级前手动停止的番茄」算数、
  「升级后手动停止的番茄」不算数，同一个动作在升级前后被两套规则计算，
  且没有任何地方告诉用户。那是需要维护者拍板的产品决策（要不要加一次性说明、
  要不要给历史行加第三种状态），不是执行者能定的，已记录在 `plans/README.md`。
</content>
