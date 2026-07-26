# Plan 010: 给 v8/v9 迁移回填补逐行特征测试（改迁移代码前的安全网）

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个，务必看懂下面这段）**：
>
> 本仓库有一批**尚未提交**的工作区改动，本计划审计与针对的正是这批代码。
> 因此 **`git diff <SHA>..HEAD` 形式的漂移检查在这里完全无效**——你要比对的代码根本不在任何提交里。
> 请改用下面的 grep 判据：
>
> ```bash
> grep -n "migrateToVersion8" src/services/DatabaseManager.cpp        # 必须命中
> grep -n "pomodoro_completed" src/services/DatabaseManager.cpp        # 必须命中多行
> grep -n "category_id_snapshot" src/services/DatabaseManager.cpp      # 必须命中
> grep -n "createLegacyVersion1Database" tests/ServiceTests.cpp        # 必须命中
> grep -c "kCurrentSchemaVersion = 9" src/services/DatabaseManager.h   # 必须为 1
> ```
>
> 任一判据不命中 → 按 STOP condition 处理，报告实际看到的内容。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW（纯新增测试，不改产品代码）
- **Depends on**: none
- **Blocks**: plans/011（改迁移代码）、plans/012（改统计口径）
- **Category**: tests
- **Planned at**: commit `43ba2ee`（+ 未提交工作区），2026-07-26

## Why this matters

schema v8 和 v9 各自包含一条**不可逆的 `UPDATE`，直接重写用户的全部历史专注记录**：
v8 回填 `pomodoro_completed`（决定每条历史记录还算不算「一个番茄」），
v9 回填三个科目快照列（决定删掉科目后历史统计还认不认得出它）。

这两条语句是整批改动里风险最高的两行，而目前保护它们的全部测试就是一句
`QCOMPARE(user_version, kCurrentSchemaVersion)`——**把这两条 UPDATE 整个删掉，测试照样全绿**。

后续 plans/011 要修改这两处迁移逻辑。在没有逐行断言的情况下改它们，等于在没有安全网的
情况下改写用户数据。所以本计划必须先落地：它不修任何缺陷，它是让别的计划可以安全落地的前提。

## Current state

### 相关文件

- `src/services/DatabaseManager.cpp` — 迁移链。v8 在 `migrateToVersion8()`，v9 在 `migrateToVersion9()`。**本计划不修改它**。
- `src/services/DatabaseManager.h` — `kCurrentSchemaVersion = 9`。
- `tests/ServiceTests.cpp` — 4059 行、118 个测试槽的主测试文件。本计划**只往里追加**。

### 现有迁移测试的形态（这是你要模仿又要超越的范式）

`tests/ServiceTests.cpp` 已有一个构造旧库的夹具函数，位置在文件顶部的匿名工具区：

```cpp
// tests/ServiceTests.cpp:314 起
bool createLegacyVersion1Database(const QString& path)
{
    // 构造旧版本数据库，验证真实用户升级时的迁移路径。
    const QString connectionName = QStringLiteral("LegacyMigrationSetupConnection");
    {
        QSqlDatabase legacyDb = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        legacyDb.setDatabaseName(path);
        if (!legacyDb.open()) { /* qWarning + return false */ }

        QSqlQuery query(legacyDb);
        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE tasks ( ... )
        )SQL"))) { /* ... */ }
        // ... 建 focus_sessions、插数据 ...
    }
    QSqlDatabase::removeDatabase(connectionName);   // 注意：必须在作用域外移除连接
    return true;
}
```

**关键范式（照抄）**：建库用**独立命名连接**，用完在 `{}` 作用域结束后
`QSqlDatabase::removeDatabase(connectionName)`。Qt 会对「连接仍在使用中就移除」发警告，
所以 `QSqlDatabase` 对象必须先离开作用域。

对应的测试槽形态（`tests/ServiceTests.cpp:2773` 附近）：

```cpp
void ServiceTests::migrationMapsLegacyCategoryTextToCategoryIds()
{
    // 建旧库 → 让 DatabaseManager 指向它并 initialize() → 查断言
    QSqlQuery versionQuery(db);
    versionQuery.exec(QStringLiteral("PRAGMA user_version"));
    versionQuery.next();
    QCOMPARE(versionQuery.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
}
```

**这正是问题所在**：现有迁移测试只断言版本号，不断言任何一行数据的迁移结果。

### v7 时期的表结构（你要构造的夹具目标）

当前（v9）的 `focus_sessions` 定义在 `src/services/DatabaseManager.cpp:156-168`：

```sql
CREATE TABLE IF NOT EXISTS focus_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,
    start_time TEXT NOT NULL,
    end_time TEXT,
    duration INTEGER,
    mode INTEGER NOT NULL DEFAULT 1,
    pomodoro_completed INTEGER NOT NULL DEFAULT 0 CHECK(pomodoro_completed IN (0, 1)),
    category_id_snapshot INTEGER,
    category_name_snapshot TEXT NOT NULL DEFAULT '',
    category_color_snapshot TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
)
```

**v7 的形态 = 上面这个去掉最后四列**（`pomodoro_completed` 是 v8 加的，三个 `category_*_snapshot`
是 v9 加的），即：

```sql
CREATE TABLE focus_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,
    start_time TEXT NOT NULL,
    end_time TEXT,
    duration INTEGER,
    mode INTEGER NOT NULL DEFAULT 1,
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
)
```

`tasks` 表和 `categories` 表在 v7 时已是当前形态（v5 引入 `category_id`，v7 引入
`estimated_pomodoros`），你可以直接从 `DatabaseManager.cpp` 的 `createTables()` 里抄它们的
`CREATE TABLE` 语句。构造完夹具后要写 `PRAGMA user_version = 7`。

### 两条回填语句的确切语义（你的断言要锁住这个）

**v8 回填**（`src/services/DatabaseManager.cpp:745-752`）：

```sql
UPDATE focus_sessions SET pomodoro_completed =
CASE WHEN mode = 1 AND end_time IS NOT NULL AND duration >= 180 THEN 1 ELSE 0 END
```

即：番茄模式(mode=1) **且** 已结束(end_time 非空) **且** 时长 ≥ 180 秒 → 1，否则 0。

**v9 回填**（`src/services/DatabaseManager.cpp:774-808` 附近）：把每条 session 所属任务当时的
科目 id / 名称 / 颜色写进三个快照列。读之前先看懂它的 `WHERE` 条件和对
「任务已删除」「旧版纯文本科目」两种情况的处理——你的断言必须覆盖它实际写了什么，
而不是你以为它该写什么。

### 项目约定

- **注释必须是中文**，解释「为什么这样做」和「边界条件是什么」，不要逐行翻译代码。
  数据库迁移、事务、兼容旧数据的逻辑属于**必须注释**的类别。
- 测试里为了稳定性或环境隔离做的特殊处理（比如独立连接名、临时目录）也要注释说明原因。
- 分层：`src/services` / `src/models` / `qml` / `tests` 职责不混。本计划只碰 `tests/`。

## Commands you will need

构建目录**必须在仓库外**。禁止改动仓库内的 `build/`、`build-release/`。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-010 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译本测试 | `cmake --build /tmp/pt-010 --target PomodoroTodoTests -j8` | exit 0 |
| 跑本测试 | `QT_QPA_PLATFORM=offscreen /tmp/pt-010/PomodoroTodoTests` | `Totals: 138 passed` → 加完后应为 `144 passed` |
| 只跑迁移相关槽 | `QT_QPA_PLATFORM=offscreen /tmp/pt-010/PomodoroTodoTests backfill` | 匹配的槽全过 |
| 全量 | `cd /tmp/pt-010 && ctest --output-on-failure` | `100% tests passed, 0 tests failed out of 12` |

**必须传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**：该选项默认 ON，且部署目标挂在 `ALL` 上，
不关的话每次构建都会去覆盖 `/Applications/番茄Todo.app`。审计与临时构建一律关掉。

**基线用例数以你第一次跑出来的实际数字为准**。上表写 138 是审计时的实测值；
如果你跑出来不是 138，先把实际数记下来，用「实际基线 + 6」作为完成判据，
**不要为了凑数字改测试**。

## Scope

**In scope**（只允许改这些文件）：
- `tests/ServiceTests.cpp` — 新增 1 个夹具函数 + 6 个测试槽（含 `private slots:` 里的声明）

**Out of scope**（看着相关也不许碰）：
- `src/services/DatabaseManager.cpp` / `.h` —— **一行都不要改**。本计划的全部价值就在于
  「先有能锁住当前行为的测试，再谈改」。如果你在写测试时发现迁移逻辑有 bug：
  **按当前的真实行为写断言，并在 STOP conditions 里报告这个 bug**，由 plans/011 去修。
- 其它任何 `src/` 文件、任何 `qml/` 文件。
- `tests/BackupServiceTests.cpp` —— 备份侧的迁移测试是 plans/011 的事。

## Git workflow

- 分支：`advisor/010-migration-backfill-tests`
- 提交信息用中文，描述本次提交完成的功能。参考既有风格（`git log --oneline -5`）：
  例如 `新增 v8/v9 迁移回填的逐行特征测试`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 写 v7 夹具函数

在 `tests/ServiceTests.cpp` 里 `createLegacyVersion1Database` 附近（同一个匿名工具区）新增：

```cpp
// 构造一个 schema v7 形态的数据库：focus_sessions 尚无 pomodoro_completed 与三个科目快照列。
// 用于验证 v8/v9 迁移的回填结果，而不只是验证版本号被改到了 9。
bool createLegacyVersion7Database(const QString& path)
```

它要建 `categories`、`tasks`、`focus_sessions`（v7 形态，见 "Current state"），
写 `PRAGMA user_version = 7`，并插入下面这批**刻意覆盖所有分支**的数据：

| # | mode | end_time | duration | 说明 | v8 回填应得 |
|---|---|---|---|---|---|
| 1 | 1 | 非空 | 1500 (25分) | 正常番茄 | 1 |
| 2 | 1 | 非空 | 240 (4分) | 短但达标 | 1 |
| 3 | 1 | 非空 | 179 | 差一秒不达标 | 0 |
| 4 | 1 | 非空 | 180 | 正好在门槛上（边界） | 1 |
| 5 | 0 | 非空 | 1800 | 自由计时，不是番茄 | 0 |
| 6 | 1 | **NULL** | 1500 | 未结束 | 0 |
| 7 | 1 | 非空 | NULL | 时长缺失 | 0 |

第 4 行是**边界值**，最容易在改动阈值时被写错，必须有。
第 7 行验证 `duration IS NULL` 时 SQL 的 `>=` 比较结果（SQLite 里 `NULL >= 180` 为 NULL，
`CASE WHEN NULL` 走 ELSE 分支 → 0）——这类三值逻辑的边界一定要用测试钉死。

任务/科目侧再准备两条，供 v9 用：一条 session 挂在有科目的任务上，一条挂在
**已被删除的任务**上（`task_id` 指向不存在的行，或插入后删掉任务）。

**Verify**: `cmake --build /tmp/pt-010 --target PomodoroTodoTests -j8` → exit 0（此时还没有新测试槽，只验证夹具能编译）

### Step 2: 写 v8 回填的逐行断言

在 `private slots:` 区加声明，并实现：

```cpp
void ServiceTests::migrationV8BackfillsPomodoroCompletedPerRow()
```

流程：建 v7 夹具库 → 把 `DatabaseManager` 指向它并 `initialize()` →
逐条 `SELECT id, pomodoro_completed FROM focus_sessions ORDER BY id` →
对上表 7 行**逐行** `QCOMPARE`。

再加一个槽锁住「不该被误伤」的方向：

```cpp
void ServiceTests::migrationV8DoesNotInventPomodorosForFreeTimerSessions()
```
断言第 5 行（自由计时 30 分钟）迁移后仍是 0——这条最容易在放宽回填条件时被破坏。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-010/PomodoroTodoTests migrationV8` → 2 passed

### Step 3: 写 v9 快照回填的断言

先**读懂** `migrateToVersion9()` 的实际实现，再写断言。至少覆盖三个槽：

```cpp
void ServiceTests::migrationV9SnapshotsCategoryForSessionsWithTasks();
void ServiceTests::migrationV9LeavesSnapshotEmptyWhenTaskIsGone();
void ServiceTests::migrationV9PreservesSnapshotAfterCategoryDeletion();
```

第三个是快照列**存在的理由**：迁移后删掉科目，历史 session 仍应能报出当时的科目名和颜色。

**若你读代码后发现 `migrateToVersion9()` 的真实行为与上述槽名的预期不符**：
按真实行为写断言并改槽名，同时在最终报告里明确写出「实现与预期的差异」。
不要改产品代码去迎合槽名。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-010/PomodoroTodoTests migrationV9` → 3 passed

### Step 4: 写「逻辑日 × 有效番茄」的交叉边界

```cpp
void ServiceTests::migrationV8BackfillIsIndependentOfDayStartHour()
```

设 `dayStartHour = 4`，插两条 03:59 和 04:01 开始的合格番茄，断言迁移回填结果都是 1
（回填只看 mode/end_time/duration，**不该**受逻辑日设置影响）。
这条测试的作用是钉死「回填与逻辑日无关」这个不变量——将来有人给回填加日期条件时会立刻红。

**Verify**: `QT_QPA_PLATFORM=offscreen /tmp/pt-010/PomodoroTodoTests DayStartHour` → 1 passed

### Step 5: 全量回归

**Verify**:
```
cd /tmp/pt-010 && ctest --output-on-failure
```
→ `100% tests passed, 0 tests failed out of 12`

## Test plan

全部是新增测试，无产品代码改动，因此「测试计划」即上面 Step 2-4：

- v8 回填 7 行逐行断言（含 179/180 边界、NULL duration 三值逻辑、自由计时不误判）
- v9 快照 3 个场景（正常、任务已删、科目已删后仍可追溯）
- v8 回填与 dayStartHour 无关的不变量
- 结构范式照 `tests/ServiceTests.cpp:2773` 的 `migrationMapsLegacyCategoryTextToCategoryIds`
- 夹具范式照 `tests/ServiceTests.cpp:314` 的 `createLegacyVersion1Database`

## Done criteria

全部必须成立：

- [ ] `cd /tmp/pt-010 && ctest --output-on-failure` → 12/12 通过
- [ ] `PomodoroTodoTests` 用例数 = 你第一次测得的基线 + 6
- [ ] `grep -c "createLegacyVersion7Database" tests/ServiceTests.cpp` ≥ 2（定义 + 至少一处调用）
- [ ] `git status --short` 显示**只有** `tests/ServiceTests.cpp` 被修改
      （注意：工作区本来就有大量未提交文件，你要确认的是「没有新增你不该动的文件」，
      对照本计划的 In scope 列表逐个核）
- [ ] `git diff src/` 为空 —— 产品代码一行未动
- [ ] 新测试全部带中文注释，说明该断言在守护什么边界
- [ ] `plans/README.md` 中 010 的状态行已更新

## STOP conditions

出现以下任一情况，停下报告，不要自行发挥：

- Drift check 的 grep 判据不命中。
- 你在写断言时发现 v8 或 v9 的回填**存在真实缺陷**（结果与注释声称的语义不符）。
  → 按真实行为写测试让它通过，然后在报告里单独列出这个缺陷。修它是 plans/011 的事。
- 构造 v7 夹具后 `initialize()` 直接失败 —— 说明 v7 形态推断有误，报告实际报错。
- 某一步的验证连续两次修复后仍失败。
- 你发现必须修改 `src/` 下的任何文件才能让测试通过。

## Maintenance notes

- 本计划是 plans/011 的前置安全网。011 会修改 v8 回填语句和快照保留策略，
  届时**这些测试必须仍然全绿**——如果 011 让它们变红，说明 011 改变了用户可见的迁移语义，
  那是需要人拍板的产品决策，不是可以顺手调整的测试。
- 将来若 `FocusSessionRules::kMinimumValidDurationSeconds` 从 180 改成别的值，
  Step 1 表格里的 179/180/240 三行需要跟着改。这正是设计意图：让阈值变更**必须**
  经过一次有意识的测试修改，而不是悄悄生效。
- 审查这个 PR 时该重点看：断言是不是逐行的（`QCOMPARE` 每一行的 `pomodoro_completed`），
  而不是聚合的（`COUNT(*) WHERE pomodoro_completed = 1`）。聚合断言会漏掉「两行互相抵消」的错误。
</content>
</invoke>
