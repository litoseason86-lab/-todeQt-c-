# Plan 032: 给数据库连接设置 busy_timeout，让导出期间的主线程写入不再瞬间失败

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 按步骤执行。每一步都要跑验证命令并确认预期结果，
> 再进入下一步。遇到 "STOP conditions" 里的任何一条，停下来汇报，不要自行发挥。
> 完成后更新 `plans/README.md` 里本计划那一行的状态——除非派发你的复核者说明索引由他维护。
>
> **Drift check（先跑这个）**：
> `git diff --stat b5a8836..HEAD -- src/services/DatabaseManager.cpp src/services/ExportService.cpp tests/RobustnessTests.cpp`
> 若任一 in-scope 文件有变化，先把下面 "Current state" 的摘录和实际代码逐条比对；
> 对不上就按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b5a8836`，2026-08-14
- **⚠️ 基线包含未提交改动**：见下面「基线前提」一节，开工前必须先确认。

## 基线前提（先读这一段）

本计划写于 `b5a8836`，但当时工作区有一批**未提交**改动（22 个文件），
其中包括对 `src/services/ExportService.cpp` 的实质修改：`acquireDatabase()` 的签名
从 `acquireDatabase(QString*)` 变成 `acquireDatabase(const QString& workerDatabasePath, QString*)`。

**开工前先确认你拿到的是哪一版**：

```bash
grep -n "QSqlDatabase ExportService::acquireDatabase" src/services/ExportService.cpp
```

- 输出含 `acquireDatabase(const QString& workerDatabasePath,` → 你拿到的是**本计划假定的版本**，继续。
- 输出是 `acquireDatabase(QString* ownedConnectionName) const` → 那批改动尚未合入，
  **STOP 并汇报**：本计划的 Step 2 会落在错误的函数签名上。

## Why this matters

导出功能在上一轮被移出 GUI 线程（commit `6fe714d`）。移出去之后，工作线程会对**同一个
数据库文件**再开一条连接，于是应用第一次有了「两条连接同时访问一个 SQLite 文件」的情形。

但主连接只设了 `foreign_keys`，**没有设 `busy_timeout`**，数据库也不是 WAL 模式。
SQLite 的 `busy_timeout` 默认是 **0**——意味着一旦撞锁，写操作**不等待、立刻返回
`SQLITE_BUSY`**，`QSqlQuery::exec()` 直接返回 false。

具体后果：用户在导出一个较大的日期区间时，导出线程持有 SHARED 锁遍历结果集；
这期间主线程要提交一次写入（结束一个番茄、改一个任务、存一次专注会话），
提交阶段需要 EXCLUSIVE 锁，拿不到就**当场失败**。用户看不到任何弹窗——
代码路径只有 `qWarning()`，专注记录就这么丢了。

这个洞是移线程带来的，不是历史遗留。修法是一行 pragma：让撞锁的一方等一会儿，
而不是立刻放弃。项目自己在别处已经这么做了（见下面 `BackupOperations.cpp:400`）。

## Current state

相关文件：

- `src/services/DatabaseManager.cpp` — 主连接的打开与 pragma 设置（第 105–128 行）
- `src/services/ExportService.cpp` — 导出工作线程的只读连接（`acquireDatabase`，第 495–524 行）
- `src/services/BackupOperations.cpp` — **已有先例**，证明本项目认可这个做法
- `tests/RobustnessTests.cpp` — 新测试的落点

### 主连接：只设了 foreign_keys（`DatabaseManager.cpp:109-123`）

```cpp
    m_db.setDatabaseName(path);
    if (!m_db.open()) {
        qWarning() << "Failed to open database:" << path << m_db.lastError().text();
        return false;
    }

    QSqlQuery pragmaQuery(m_db);
    if (!pragmaQuery.exec(QStringLiteral("PRAGMA foreign_keys = ON"))) {
        qWarning() << "Failed to enable SQLite foreign keys:" << pragmaQuery.lastError().text();
        return false;
    }

    if (!createTables()) {
        return false;
    }
```

### 导出工作线程：另开一条只读连接（`ExportService.cpp:504-523`）

```cpp
    // 工作线程：按线程开一条只读连接。名字带线程指针，避免并发导出撞名。
    // 路径由 GUI 线程在投递任务前快照。工作线程不能为了读取 databaseName()
    // 去碰主线程创建的 QSqlDatabase 句柄。
    if (workerDatabasePath.isEmpty()) {
        return QSqlDatabase();
    }
    const QString name = QStringLiteral("ExportWorker_%1_%2")
                             .arg(reinterpret_cast<quintptr>(QThread::currentThread()))
                             .arg(QDateTime::currentMSecsSinceEpoch());
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), name);
    db.setDatabaseName(workerDatabasePath);
    // 只读：导出不写库，也就不会和主线程的写事务抢锁。
    db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
    if (!db.open()) {
```

注意那句注释「只读：导出不写库，也就不会和主线程的写事务抢锁」——**这句话是错的**，
只读连接照样持有 SHARED 锁并阻塞写方的 EXCLUSIVE 阶段。修复时要一并改掉这句注释，
否则下一个人还会照它推理。

### 已有先例（`BackupOperations.cpp:398-402`）

```cpp
                if (!timeout.exec(QStringLiteral("PRAGMA busy_timeout = 5000"))) {
```

备份路径给自己的临时连接设了 5000ms。主连接没设，是遗漏而非有意为之。

### 项目约定（必须遵守）

- **注释写「为什么」，不写「做了什么」**，用中文。上面每段摘录都是这个风格，照着写。
- 编译开了 `-Wall -Wextra`（`CMakeLists.txt:242`），新代码不得引入告警。
- **新断言必须先证伪**：写完测试后，把实现改坏，确认测试变红，再改回来。
  这是本项目的硬性纪律，Step 4 会明确要求你做这件事。
- **还原被改坏的源文件后必须 `touch` 该文件**再重新构建：
  用 `sed -i.bak` + `mv` 还原会保留旧 mtime，构建系统会判定「无需重编译」，
  于是你测的还是被改坏的二进制，结论会完全反过来。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 构建（验证用目录） | `cmake --build ~/pt-audit -j8` | exit 0，无 error、无新增 warning |
| 全量测试 | `cd ~/pt-audit && ctest --output-on-failure -j4` | `19/19 tests passed`（本计划完成后仍是 19） |
| 单个测试可执行文件 | `cd ~/pt-audit && ./RobustnessTests` | `0 failed` |
| 单条用例 | `cd ~/pt-audit && ./RobustnessTests <slotName>` | `0 failed` |

**构建目录规则（`AGENTS.md` 明文规定，必须遵守）**：本机只允许两个构建目录——
`~/pt-build`（部署用，`DEPLOY_LOCAL=ON`）与 `~/pt-audit`（验证用，`DEPLOY_LOCAL=OFF`）。
**本计划一律用 `~/pt-audit`**。不要新建 `pt-fix`、`pt-tmp` 这类一次性目录——
每个 300–450M、只增不减，历史上攒到过 3.3G。

若 `~/pt-audit` 不存在，用这条创建（注意 `OFF`，否则构建会覆盖 `/Applications/番茄Todo.app`）：

```bash
cmake -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF -DCMAKE_PREFIX_PATH=~/Qt/6.10.3/macos
```

## Scope

**In scope**（只改这些文件）：
- `src/services/DatabaseManager.cpp`
- `src/services/ExportService.cpp`（只改 `acquireDatabase` 内部与那句错误注释）
- `tests/RobustnessTests.cpp`（新增 1 个测试槽）

**Out of scope**（看着相关也不要动）：
- **不要切换到 WAL 模式。** WAL 会引入 `-wal`/`-shm` 附属文件，而本项目的备份设计
  是「`VACUUM INTO` 出单文件快照 + 嵌入 QSettings」的 `.tomatobackup`，
  恢复/校验路径都按单文件假设写的。WAL 是否值得开是一个独立课题，需要单独评估，
  **不在本计划内**。只加 `busy_timeout`。
- `src/services/BackupOperations.cpp` — 它已经设了 timeout，不要动。
- 任何导出的 SQL 语句或 CSV 输出格式。
- `qml/` 下的任何文件。

## Git workflow

- 分支：`advisor/032-sqlite-busy-timeout`
- 提交信息用中文、说明「为什么」，与现有历史一致。参考 `git log --oneline -5`：
  例如 `修 PERF-03/04：导出移出 GUI 线程，拖动期间不再重建整片 delegate`
- **不要 push，不要开 PR**，除非派发你的人明确要求。

## Steps

### Step 1: 给主连接加 busy_timeout

在 `src/services/DatabaseManager.cpp` 里，紧挨着现有的 `foreign_keys` pragma 之后，
加一条 `busy_timeout`。与现有 pragma 相同的错误处理风格（失败则 `qWarning` + `return false`）。

超时值用 **5000**（毫秒），与 `BackupOperations.cpp:400` 保持一致——同一个代码库里
两个不同的超时值会让后来的人以为其中一个有特殊含义。

注释要写明为什么需要它（导出工作线程会并发持锁，默认 0 意味着撞锁即失败），
而不是复述代码在做什么。

**Verify**：
```bash
grep -n "busy_timeout" src/services/DatabaseManager.cpp
```
→ 有一条命中，且在 `foreign_keys` 那条之后。

```bash
cmake --build ~/pt-audit -j8 2>&1 | grep -E "warning|error" | head
```
→ 无输出。

### Step 2: 给导出工作线程的只读连接也加上，并改掉那句错误注释

在 `ExportService::acquireDatabase()` 里，`db.open()` 成功之后、`*ownedConnectionName = name;`
之前，对这条连接执行同样的 `PRAGMA busy_timeout = 5000`。

**只读连接同样需要**：读方在写方提交（EXCLUSIVE 阶段）时也会撞锁，
没有超时就会让导出中途报「database is locked」而整个失败。

同时把这句注释改掉：

```cpp
    // 只读：导出不写库，也就不会和主线程的写事务抢锁。
```

它断言的「不会抢锁」是错的。改成说明真实情况：只读连接不产生写冲突，
但仍持有 SHARED 锁、仍会与主线程的提交互相阻塞，所以两侧都要有 busy_timeout。

**Verify**：
```bash
grep -n "busy_timeout" src/services/ExportService.cpp
grep -c "也就不会和主线程的写事务抢锁" src/services/ExportService.cpp
```
→ 第一条有一条命中；第二条输出 `0`（旧注释已删除）。

```bash
cd ~/pt-audit && ctest --output-on-failure -j4 2>&1 | tail -3
```
→ `19/19 tests passed`。

### Step 3: 写一条能真正复现撞锁的测试

在 `tests/RobustnessTests.cpp` 新增测试槽
`writeSucceedsWhileAnotherConnectionHoldsTheLock()`，并在 `private slots:` 段落里
`largeDatasetQueriesStayFast();` 之后登记声明。

结构照抄本文件既有用例（`init()` 已经建好临时库并 `initialize()`，`cleanup()` 负责关闭，
你不需要自己管理这些）。

测试要做的事：

1. 取主连接的数据库文件路径：`DatabaseManager::instance()->database().databaseName()`。
2. 起一个 `QThread`（或 `QtConcurrent::run`），在其中用**另一个连接名**打开同一个文件，
   执行 `BEGIN EXCLUSIVE`，持锁约 **300ms**，然后 `COMMIT` 并关闭、`removeDatabase`。
   注意：连接必须在该线程内创建和销毁，QSqlDatabase 不能跨线程共享。
3. 主线程等到「锁确实已被持有」之后（用 `QTRY_VERIFY` 等一个由子线程置位的
   `std::atomic<bool>`，不要用固定 sleep），发起一次真实写入，
   例如 `TaskManager::instance()->addTask(...)`。
4. 断言这次写入**成功**（返回 true / 任务能被查回来）。

判据的含义：有了 busy_timeout，主线程会等那 300ms 然后成功；
没有它，写入会在毫秒内返回失败。

**不要用固定 `QTest::qSleep` 来同步两个线程**——本项目已有的时序敏感测试是已知痛点，
不要再增加一处。用 `QTRY_VERIFY` 等待原子标志。

**Verify**：
```bash
cmake --build ~/pt-audit --target RobustnessTests -j8 2>&1 | tail -2
cd ~/pt-audit && ./RobustnessTests writeSucceedsWhileAnotherConnectionHoldsTheLock
```
→ `1 passed, 0 failed`（另加 initTestCase/cleanupTestCase）。

### Step 4: 证伪——确认这条测试真的能失败

把 Step 1 加的 pragma 值临时改成 0（`PRAGMA busy_timeout = 0`），重新构建并跑这条用例。

```bash
sed -i '' 's/busy_timeout = 5000/busy_timeout = 0/' src/services/DatabaseManager.cpp
touch src/services/DatabaseManager.cpp
cmake --build ~/pt-audit --target RobustnessTests -j8 2>&1 | grep -c "Building CXX"
cd ~/pt-audit && ./RobustnessTests writeSucceedsWhileAnotherConnectionHoldsTheLock
```

- 那条 `grep -c "Building CXX"` 必须输出 **≥1**。如果是 0，说明构建跳过了重编译，
  你测的是旧二进制，**结论无效**——先解决重编译再继续。
- 这一次用例必须**失败**（FAIL）。如果它仍然通过，说明判据没有锁住真实行为，
  **STOP 并汇报**，不要为了让它变红而修改断言。

然后还原：

```bash
sed -i '' 's/busy_timeout = 0/busy_timeout = 5000/' src/services/DatabaseManager.cpp
touch src/services/DatabaseManager.cpp
cmake --build ~/pt-audit --target RobustnessTests -j8
cd ~/pt-audit && ./RobustnessTests writeSucceedsWhileAnotherConnectionHoldsTheLock
```
→ 重新变绿。

**Verify**：`git diff src/services/DatabaseManager.cpp | grep -c "busy_timeout = 0"` → `0`

### Step 5: 全量回归

```bash
cmake --build ~/pt-audit -j8 && cd ~/pt-audit && ctest --output-on-failure -j4
```
→ `19/19 tests passed`。

## Test plan

- **新增**：`tests/RobustnessTests.cpp` 的
  `writeSucceedsWhileAnotherConnectionHoldsTheLock()`，覆盖
  「另一条连接持有 EXCLUSIVE 锁期间，主线程写入仍能成功」这一条。
- **结构范本**：同文件的 `rapidRepeatedAddAndQueryRemainsConsistent()` 和
  `reopenAfterCloseKeepsData()`——沿用它们的 `init()`/`cleanup()` 约定和断言风格。
- **必须完成证伪**（Step 4）：把 timeout 改成 0 时该用例必须变红。
- 验证：`cd ~/pt-audit && ctest --output-on-failure -j4` → 19/19 全绿。

## Done criteria

全部满足：

- [ ] `grep -c busy_timeout src/services/DatabaseManager.cpp` ≥ 1
- [ ] `grep -c busy_timeout src/services/ExportService.cpp` ≥ 1
- [ ] `grep -c "也就不会和主线程的写事务抢锁" src/services/ExportService.cpp` == 0
- [ ] `cmake --build ~/pt-audit -j8` exit 0 且无新增编译告警
- [ ] `cd ~/pt-audit && ctest -j4` → `19/19 tests passed`
- [ ] 新用例 `writeSucceedsWhileAnotherConnectionHoldsTheLock` 存在且通过
- [ ] 证伪已完成：改成 `busy_timeout = 0` 时该用例变红（在汇报里写明你观察到的失败输出）
- [ ] `git status` 显示改动文件不超出 in-scope 列表
- [ ] `plans/README.md` 对应状态行已更新

## STOP conditions

出现以下任一情况，停下汇报，不要自行发挥：

- 「基线前提」一节的 `acquireDatabase` 签名检查不匹配。
- "Current state" 的代码摘录与实际文件对不上。
- Step 4 的证伪里，用例在 `busy_timeout = 0` 下**仍然通过**——
  说明判据没锁住真实行为，需要重新设计测试而不是调断言。
- 你发现修复需要改 in-scope 之外的文件。
- 你判断需要开 WAL 才能解决——那超出本计划范围，汇报即可，不要自行切换。
- 全量 ctest 从 19 变成别的数字。

## Maintenance notes

- **给后续维护者**：`busy_timeout` 只是让撞锁的一方等待，不是消除竞争。
  如果将来导出的数据量增长到单次遍历超过 5 秒，5000ms 会不够，
  那时应该考虑的是给导出分批、或认真评估 WAL，而不是把超时数字调大。
- **复核时重点看**：两处 pragma 是否都在 `open()` 成功**之后**执行
  （在 open 之前设无效）；以及 `ExportService.cpp` 那句错误注释是否真的改掉了——
  留着它比没有注释更糟，它会让下一个人推出错误结论。
- **本计划刻意没做**：WAL 模式评估、导出分批。都需要独立评估其对备份单文件假设的影响。
