# Plan 001: 恢复回滚失败后数据库必须重新打开，并为异步回滚补失败路径测试

> **Executor instructions**: 按步骤执行本计划。每一步都要运行验证命令并确认预期结果，
> 再进入下一步。若触发 "STOP conditions" 里的任何一条，立即停下来报告，**不要自行发挥**。
> 完成后更新 `plans/README.md` 里本计划的状态行（除非派发你的评审者说明由他维护索引）。
>
> **Drift check（先跑这个）**：
> `git diff --stat 43ba2ee..HEAD -- src/services/BackupService.cpp src/services/BackupService.h tests/BackupServiceTests.cpp`
> 若任一 in-scope 文件自本计划编写后有改动，先把下面 "Current state" 的代码摘录与实际代码逐行比对；
> 不一致就按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `43ba2ee`, 2026-07-26

## Why this matters

用户点「从备份恢复」，如果恢复后校验失败，应用会自动回滚到恢复前的数据。
但**回滚流程一开始就关闭了数据库，而重新打开数据库的调用挂在一个 `&&` 短路链的后半段**——
只要后台拷贝失败（磁盘满、目标文件被占用），`initialize()` 一次都不会被调用，
数据库就此保持关闭状态，直到用户重启应用。

此时用户看到的提示是「自动回滚失败，恢复前备份保留在 ...」，然后整个应用变成僵尸：
任务列表空白、无法开始专注、无法再次尝试恢复（`requestRestore` 本身也要求数据库是打开的）。
而**原数据库文件多半完好无损，只是没人去打开它**。

这条路径是全应用唯一能让用户丢掉全部考研数据的操作，却恰好是最脆弱的一段。
本计划让重新打开数据库变成无条件动作，并区分三种结局的提示语，同时补上这条路径的自动化测试
——目前 21 个备份测试里有 20 个测的是**同步**恢复，而界面只走**异步**恢复，
`rollbackAsyncRestore` 零覆盖。

## Current state

### 相关文件

- `src/services/BackupService.cpp` — 备份/恢复服务实现。异步恢复链路：
  `requestRestore` → `installPreparedRestore`（:619）→ 失败时 `rollbackAsyncRestore`（:688）。
  同步恢复链路（界面不走，但测试大量使用）：`restoreBackup`（:359）→ `restoreFromPreRestoreSnapshot`（:315）。
- `src/services/BackupService.h` — 服务声明；私有成员区在 :74-109。
- `tests/BackupServiceTests.cpp` — 21 个用例，fixture 在 :155-168。

### 缺陷代码 1：异步回滚（`src/services/BackupService.cpp:688-725`）

```cpp
void BackupService::rollbackAsyncRestore(
    const QSharedPointer<RestoreContext>& context,
    const QString& reason)
{
    DatabaseManager::instance()->close();                 // ← 先关库
    setBusy(true, QStringLiteral("恢复失败，正在安全回滚"), true);

    auto* watcher = new QFutureWatcher<BackupOperations::OperationResult>(this);
    connect(watcher, &QFutureWatcherBase::finished, this,
            [this, watcher, context, reason]() {
        const BackupOperations::OperationResult result = watcher->result();
        watcher->deleteLater();

        bool rolledBack = result.success
            && DatabaseManager::instance()->initialize(context->databasePath)   // ← 短路后不执行
            && verifyRestoredDatabase()
            && cleanBackupTables()
            && applySettingsSnapshot(context->originalSettings);
        if (rolledBack && m_settingsFilePath.isEmpty()) {
            AppSettings::instance()->reload();
        }
        if (rolledBack) {
            rolledBack = FocusTimer::instance()->restoreInterruptedSession();
        }

        const QString message = rolledBack
            ? reason + QStringLiteral("，已回滚到恢复前数据")
            : reason + QStringLiteral("；自动回滚失败，恢复前备份保留在 ")
                + context->preRestorePath;
        setLastError(message);
        setBusy(false);
        emit restoreCompleted(false, message);
    });
    watcher->setFuture(QtConcurrent::run([context]() {
        return BackupOperations::atomicCopy(
            context->preRestorePath, context->databasePath);
    }));
}
```

`result.success == false` 时，`&&` 短路 → `initialize` 不执行 → 数据库保持关闭。

### 缺陷代码 2：同步回滚（`src/services/BackupService.cpp:315-329`）

```cpp
bool BackupService::restoreFromPreRestoreSnapshot(const QString& preRestorePath,
                                                  const QString& dbPath,
                                                  const QVariantMap& originalSettings,
                                                  QString* error)
{
    DatabaseManager::instance()->close();
    const BackupOperations::OperationResult copy =
        BackupOperations::atomicCopy(preRestorePath, dbPath);
    if (!copy.success) {
        if (error) {
            *error = QStringLiteral("自动回滚失败：%1。恢复前备份仍保留在 %2")
                         .arg(copy.error, preRestorePath);
        }
        return false;                                     // ← 直接返回，不重开数据库
    }
    ...
```

同一个形状：关库后拷贝失败即返回，不重新打开。

### 正确的对照写法（同文件 `src/services/BackupService.cpp:631-639`）

`installPreparedRestore` 里安装失败的分支**已经写对了**，本计划就是把这个写法推广到两处回滚：

```cpp
if (!result.success) {
    // 原子安装失败时旧数据库仍在原路径，只需重新打开；恢复前快照若已生成则继续保留。
    const bool reopened =
        DatabaseManager::instance()->initialize(context->databasePath);
    const QString message = reopened
        ? QStringLiteral("恢复失败，原数据未改动：") + result.error
        : QStringLiteral("恢复失败且数据库重新打开失败：") + result.error;
    setLastError(message);
    setBusy(false);
    emit restoreCompleted(false, message);
    return;
}
```

### 仓库约定（必须遵守）

摘自 `AGENTS.md`：

- **注释必须用中文**，解释「为什么这样做」和「边界条件是什么」，不要逐行翻译代码。
  优先注释：数据库迁移、事务、兼容旧数据的逻辑；跨层调用与信号传播。
- 不要给简单赋值、显而易见的属性、普通 getter/setter 加噪音注释。
- 保持分层：`src/services`、`src/models`、`qml`、`tests` 的职责不要混杂。
- **Git 提交说明必须使用中文**，清楚描述本次提交解决的问题或完成的功能。

**测试用「受控友元」而非 `#define private public`** —— 这是本仓库已确立的约定，
见 `src/services/FocusTimer.h:88-95`：

```cpp
private:
    // 单元测试需要直接推进单调时钟和内部计数来模拟长时间运行；
    // 用受控友元替代测试侧 #define private public 的未定义行为写法。
    friend class ServiceTests;
    // 菜单栏控制器测试需要在用例间复位单例计时器状态。
    friend class PlatformControlTests;
    // 计时健壮性测试注入 FakeClock 模拟休眠/时钟跳变。
    friend class TimingRobustnessTests;
```

本计划将按同一模式给 `BackupService` 加 `friend class BackupServiceTests;`。

### 测试 fixture（`tests/BackupServiceTests.cpp:146-168`）

```cpp
private:
    QString dbPath() const { return m_tempDir->filePath(QStringLiteral("pomodoro.db")); }
    QString settingsPath() const { return m_tempDir->filePath(QStringLiteral("settings.ini")); }
    QString backupsDir() const { return m_tempDir->filePath(QStringLiteral("backups")); }
    QString backupFile() const { return m_tempDir->filePath(QStringLiteral("manual.tomatobackup")); }

    QTemporaryDir* m_tempDir = nullptr;
};

void BackupServiceTests::init()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(dbPath()));
    BackupService::instance()->configure(settingsPath(), backupsDir());
}

void BackupServiceTests::cleanup()
{
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}
```

### 现有异步用例的写法（`tests/BackupServiceTests.cpp:455-470`），新用例照此结构

```cpp
void BackupServiceTests::asyncRestoreReloadsTaskSnapshots()
{
    QVERIFY(insertTask(QStringLiteral("备份内任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复前新增任务")) > 0);

    QSignalSpy restoredSpy(BackupService::instance(), &BackupService::restoreCompleted);
    QSignalSpy tasksChangedSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    BackupService::instance()->requestRestore(backupFile());

    QVERIFY2(restoredSpy.wait(10000), "异步恢复未在 10 秒内完成");
    QCOMPARE(restoredSpy.last().at(0).toBool(), true);
    QVERIFY(tasksChangedSpy.count() >= 1);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
    QVERIFY(!BackupService::instance()->busy());
}
```

## Commands you will need

Qt 前缀按本机实际安装位置传入。下面用一个**仓库外**的构建目录，并关闭自动部署
（`AGENTS.md` 要求构建目录放在仓库外；`-DPOMODORO_TODO_DEPLOY_LOCAL=OFF` 避免验证构建
覆盖 `/Applications/番茄Todo.app`）。

| 用途 | 命令 | 成功标志 |
|---|---|---|
| 配置 | `cmake -B /tmp/pt-001 -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | 退出码 0，末尾出现 `Build files have been written to` |
| 构建本套件 | `cmake --build /tmp/pt-001 --target BackupServiceTests -j8` | 退出码 0，无 error |
| 跑本套件 | `QT_QPA_PLATFORM=offscreen /tmp/pt-001/BackupServiceTests` | `Totals: N passed, 0 failed` |
| 全量构建 | `cmake --build /tmp/pt-001 -j8` | 退出码 0 |
| 全量测试 | `cd /tmp/pt-001 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | `100% tests passed, 0 tests failed out of 12` |

如果 `/Users/zerionlito/Qt/6.9.0/macos` 不存在，用 `ls ~/Qt` 找到实际版本目录替换；
仍找不到就按 STOP condition 处理。

## Scope

**In scope（只允许修改这三个文件）**：

- `src/services/BackupService.cpp`
- `src/services/BackupService.h`
- `tests/BackupServiceTests.cpp`

**Out of scope（即使看起来相关也不要动）**：

- `src/services/BackupOperations.cpp` / `.h` —— 纯后台文件操作层，本缺陷不在这里；
  改它会影响备份创建路径，超出本计划的验证范围。
- `src/services/DatabaseManager.cpp` —— `initialize()` 本身没问题，问题在调用时机。
- `src/services/BackupService.cpp` 里 `verifyRestoredDatabase()`（:278-296）的表白名单 ——
  **刻意不含 `long_goals`**，这是已决定的取舍（加进去会让早于长期目标功能的旧备份恢复失败）。不要改。
- 备份文件格式、`inspectBackup` 的校验规则 —— 属于另一条独立的安全议题，不在本计划内。
- `CMakeLists.txt` —— 本计划不新增文件，不需要改构建。

## Git workflow

- 分支：`advisor/001-restore-rollback-reopen`
- 每个 Step 一次提交，提交说明用中文。参考现有风格（`git log --oneline -5`）：
  `新增六项功能:番茄预估/菜单栏计时/备份恢复/撤销/计时校准/每周复盘`、`导出日期校验只认 yyyy-MM-dd`
- 建议的提交说明：
  - Step 1：`恢复回滚失败时无条件重新打开数据库`
  - Step 2：`备份服务增加回滚拷贝失败的测试钩子`
  - Step 3：`补异步恢复回滚失败路径测试`
- **不要 push，不要开 PR**，除非派发你的人明确要求。

## Steps

### Step 1: 让两处回滚都无条件重新打开数据库

**1a.** 在 `src/services/BackupService.cpp` 的 `rollbackAsyncRestore` 里，把 lambda 内计算
`rolledBack` 的那一段改成先无条件重开、再计算结果，并把提示语分成三种结局。
把原来的这一段：

```cpp
        bool rolledBack = result.success
            && DatabaseManager::instance()->initialize(context->databasePath)
            && verifyRestoredDatabase()
            && cleanBackupTables()
            && applySettingsSnapshot(context->originalSettings);
```

替换为：

```cpp
        // 无论回滚拷贝成败，都必须先把数据库重新打开：拷贝失败时原库文件通常仍完好，
        // 只是连接被关掉了。若把 initialize 挂在 && 链后半段，拷贝一失败就会短路，
        // 应用会一直停在"数据库未打开"的僵尸态，连再试一次恢复都做不到。
        const bool reopened =
            DatabaseManager::instance()->initialize(context->databasePath);

        bool rolledBack = result.success
            && reopened
            && verifyRestoredDatabase()
            && cleanBackupTables()
            && applySettingsSnapshot(context->originalSettings);
```

**1b.** 同一个 lambda 里，把 `message` 的三元表达式改成区分三种结局：

```cpp
        QString message;
        if (rolledBack) {
            message = reason + QStringLiteral("，已回滚到恢复前数据");
        } else if (reopened) {
            // 数据库能打开就说明用户还能继续用，提示语必须和"彻底不可用"区分开。
            message = reason + QStringLiteral("；自动回滚未完成，当前数据可能不完整，"
                                              "恢复前备份保留在 ")
                + context->preRestorePath;
        } else {
            message = reason + QStringLiteral("；自动回滚失败且数据库无法打开，"
                                              "请重启应用；恢复前备份保留在 ")
                + context->preRestorePath;
        }
```

**1c.** 在 `restoreFromPreRestoreSnapshot`（`src/services/BackupService.cpp:315`）里，
把拷贝失败的早退分支补上重开：

```cpp
    if (!copy.success) {
        // 与异步回滚同理：拷贝失败不代表原库损坏，必须把连接重新打开，
        // 否则调用方拿到 false 之后整个应用没有数据库可用。
        const bool reopened = DatabaseManager::instance()->initialize(dbPath);
        if (error) {
            *error = reopened
                ? QStringLiteral("自动回滚失败：%1。恢复前备份仍保留在 %2")
                      .arg(copy.error, preRestorePath)
                : QStringLiteral("自动回滚失败且数据库无法打开：%1。恢复前备份仍保留在 %2")
                      .arg(copy.error, preRestorePath);
        }
        return false;
    }
```

**Verify**：
`cmake --build /tmp/pt-001 --target BackupServiceTests -j8` → 退出码 0，无编译错误
`QT_QPA_PLATFORM=offscreen /tmp/pt-001/BackupServiceTests` → `Totals: 21 passed, 0 failed`
（本步不新增用例，既有 21 个必须全绿。若数字不是 21，说明代码已漂移，见 STOP conditions。）

### Step 2: 加一个受控测试钩子，让回滚拷贝失败可被确定性构造

回滚拷贝的失败在真实运行中由磁盘满/文件被占用触发，测试里无法稳定复现——
拷贝的源文件（恢复前快照）刚刚才成功写出，正常情况下必然能拷贝成功。
因此按仓库既有约定（`FocusTimer.h:88-95` 的受控友元）加一个测试专用开关。

**2a.** 在 `src/services/BackupService.h` 的 `private:` 区（:74 之后、`struct RestoreContext;` 之前）加入：

```cpp
private:
    // 回滚拷贝失败在真实环境由磁盘满/文件占用触发，测试无法稳定复现（快照刚写出，必然可拷）。
    // 沿用 FocusTimer 的受控友元约定，用一个测试专用开关强制该分支，
    // 避免测试侧 #define private public 的未定义行为写法。
    friend class BackupServiceTests;

    struct RestoreContext;
```

**2b.** 在同文件的成员变量区（`QString m_operationText;` 之后、`};` 之前）加入：

```cpp
    // 仅供 BackupServiceTests 置位：强制下一次回滚的拷贝返回失败。生产代码永远不写它。
    bool m_forceRollbackCopyFailureForTest = false;
```

**2c.** 在 `src/services/BackupService.cpp` 的 `rollbackAsyncRestore` 末尾，
把 `watcher->setFuture(...)` 改成读取该开关：

```cpp
    const bool forceFailure = m_forceRollbackCopyFailureForTest;
    m_forceRollbackCopyFailureForTest = false;   // 一次性开关，用完即清
    watcher->setFuture(QtConcurrent::run([context, forceFailure]() {
        if (forceFailure) {
            BackupOperations::OperationResult forced;
            forced.success = false;
            forced.error = QStringLiteral("测试注入的回滚拷贝失败");
            return forced;
        }
        return BackupOperations::atomicCopy(
            context->preRestorePath, context->databasePath);
    }));
```

若 `BackupOperations::OperationResult` 的字段名不是 `success` / `error`，
打开 `src/services/BackupOperations.h` 按实际字段名调整（其余逻辑不变）。

**Verify**：
`cmake --build /tmp/pt-001 --target BackupServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-001/BackupServiceTests` → `Totals: 21 passed, 0 failed`
`grep -n "m_forceRollbackCopyFailureForTest" src/services/BackupService.cpp src/services/BackupService.h` → 恰好 4 处命中（头文件声明 1 处，cpp 读取与清零 2 处，头文件注释不计）

### Step 3: 补两个异步失败路径用例

在 `tests/BackupServiceTests.cpp` 的 `private slots:` 区（:141 `asyncRestoreReloadsTaskSnapshots();` 之后）声明：

```cpp
    void asyncRestoreRollbackReopensDatabaseWhenCopyFails();
    void asyncRestoreRollbackRestoresOriginalTaskCount();
```

在 `asyncRestoreReloadsTaskSnapshots()` 的实现之后追加两个实现。

**用例 1 —— 本计划要守住的核心行为**：回滚拷贝失败后，数据库仍然可用。

要触发回滚，恢复的**安装**必须先成功、随后的校验再失败。最稳的构造方式是把设置文件设为只读：
`applySettingsSnapshot` 内部 `settings->sync()` 会失败，`installPreparedRestore` 据此走进
`rollbackAsyncRestore`。再配合 Step 2 的开关强制回滚拷贝失败。

```cpp
void BackupServiceTests::asyncRestoreRollbackReopensDatabaseWhenCopyFails()
{
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复前新增")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    // 设置文件只读 → applySettingsSnapshot 失败 → 安装阶段判定失败 → 触发回滚。
    QFile settingsFile(settingsPath());
    if (!settingsFile.exists()) {
        QSettings seed(settingsPath(), QSettings::IniFormat);
        seed.setValue(QStringLiteral("backup/seed"), 1);
        seed.sync();
    }
    QVERIFY(QFile::setPermissions(settingsPath(), QFileDevice::ReadOwner));

    // Step 2 的受控开关：让回滚阶段的拷贝返回失败，模拟磁盘满。
    BackupService::instance()->m_forceRollbackCopyFailureForTest = true;

    QSignalSpy restoredSpy(BackupService::instance(), &BackupService::restoreCompleted);
    BackupService::instance()->requestRestore(backupFile());
    QVERIFY2(restoredSpy.wait(10000), "异步恢复未在 10 秒内结束");
    QCOMPARE(restoredSpy.last().at(0).toBool(), false);

    // 核心断言：回滚拷贝失败了，但数据库必须仍然是打开且可用的。
    QVERIFY2(DatabaseManager::instance()->isOpen(),
             "回滚拷贝失败后数据库仍处于关闭状态，应用会变成僵尸态");
    QSqlQuery probe(DatabaseManager::instance()->database());
    QVERIFY2(probe.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")) && probe.next(),
             "数据库虽然标记为打开，但已经无法查询");

    // 提示语必须告诉用户数据库还能用，而不是笼统地说"回滚失败"。
    const QString message = restoredSpy.last().at(1).toString();
    QVERIFY2(!message.contains(QStringLiteral("请重启应用")),
             "数据库已重新打开，提示语不应要求用户重启");

    QVERIFY(QFile::setPermissions(settingsPath(),
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner));
    QVERIFY(!BackupService::instance()->busy());
}
```

**用例 2 —— 回滚成功时数据确实回到恢复前**：

```cpp
void BackupServiceTests::asyncRestoreRollbackRestoresOriginalTaskCount()
{
    QVERIFY(insertTask(QStringLiteral("原始任务")) > 0);
    QVERIFY(BackupService::instance()->createBackup(backupFile()));
    QVERIFY(insertTask(QStringLiteral("恢复前新增")) > 0);
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    QFile settingsFile(settingsPath());
    if (!settingsFile.exists()) {
        QSettings seed(settingsPath(), QSettings::IniFormat);
        seed.setValue(QStringLiteral("backup/seed"), 1);
        seed.sync();
    }
    QVERIFY(QFile::setPermissions(settingsPath(), QFileDevice::ReadOwner));

    QSignalSpy restoredSpy(BackupService::instance(), &BackupService::restoreCompleted);
    BackupService::instance()->requestRestore(backupFile());
    QVERIFY2(restoredSpy.wait(10000), "异步恢复未在 10 秒内结束");
    QCOMPARE(restoredSpy.last().at(0).toBool(), false);

    // 回滚拷贝这次没有被强制失败，数据应回到恢复前的 2 条。
    QVERIFY(DatabaseManager::instance()->isOpen());
    QCOMPARE(scalarCount(QStringLiteral("SELECT COUNT(*) FROM tasks")), 2);

    QVERIFY(QFile::setPermissions(settingsPath(),
                                  QFileDevice::ReadOwner | QFileDevice::WriteOwner));
}
```

若 `tests/BackupServiceTests.cpp` 顶部还没有 `#include <QFile>` / `#include <QSettings>` /
`#include <QSqlQuery>`，补上。

**Verify**：
`cmake --build /tmp/pt-001 --target BackupServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-001/BackupServiceTests` → `Totals: 23 passed, 0 failed`

**关键回归确认（必须做）**：临时把 Step 1a 的 `&& reopened` 改回
`&& DatabaseManager::instance()->initialize(context->databasePath)`，重新构建并只跑
`QT_QPA_PLATFORM=offscreen /tmp/pt-001/BackupServiceTests asyncRestoreRollbackReopensDatabaseWhenCopyFails`
→ **必须失败**（这证明新用例真的锁住了这个缺陷）。确认失败后把改动改回来，重新构建确认恢复全绿。
如果改回旧写法后用例**仍然通过**，说明用例没有真正覆盖该分支，按 STOP condition 处理。

### Step 4: 全量回归

**Verify**：
`cmake --build /tmp/pt-001 -j8` → 退出码 0
`cd /tmp/pt-001 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure`
→ `100% tests passed, 0 tests failed out of 12`

## Test plan

- 新增文件：无。新增用例写在 `tests/BackupServiceTests.cpp`。
- 结构范式：照 `tests/BackupServiceTests.cpp:455` 的 `asyncRestoreReloadsTaskSnapshots`
  （`QSignalSpy` + `restoredSpy.wait(10000)`，**不要用固定 `QTest::qSleep`**）。
- 覆盖的用例：
  1. `asyncRestoreRollbackReopensDatabaseWhenCopyFails` —— 本计划修的缺陷本身：
     回滚拷贝失败后数据库仍打开、仍可查询、提示语不要求重启。
  2. `asyncRestoreRollbackRestoresOriginalTaskCount` —— 回滚成功路径：任务数回到恢复前。
- 验证：`QT_QPA_PLATFORM=offscreen /tmp/pt-001/BackupServiceTests` → 23 passed（原 21 + 新 2）。

## Done criteria

全部必须成立：

- [ ] `cmake --build /tmp/pt-001 -j8` 退出码 0，无新增编译警告
- [ ] `cd /tmp/pt-001 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` → `100% tests passed ... out of 12`
- [ ] `QT_QPA_PLATFORM=offscreen /tmp/pt-001/BackupServiceTests` → `Totals: 23 passed, 0 failed`
- [ ] Step 3 的「关键回归确认」已执行：还原旧写法后新用例确实失败
- [ ] `grep -n "&& DatabaseManager::instance()->initialize" src/services/BackupService.cpp` → **无命中**（重开不再挂在 && 链上）
- [ ] `git status --porcelain` 只显示这三个文件被修改：`src/services/BackupService.cpp`、`src/services/BackupService.h`、`tests/BackupServiceTests.cpp`
- [ ] `plans/README.md` 中 001 的状态行已更新

## STOP conditions

出现以下任一情况，停下来报告，不要自行发挥：

- Drift check 显示 in-scope 文件有改动，且 "Current state" 的代码摘录与实际代码对不上。
- 修改前 `BackupServiceTests` 的用例数不是 21，或修改前就有用例失败（说明基线已变，先报告）。
- Step 3 的「关键回归确认」中，还原旧写法后新用例**仍然通过** —— 用例没覆盖到目标分支，
  不要为了让数字好看而放行。
- 只读设置文件的手法在本机不生效（例如以 root 运行，权限位被忽略），导致回滚根本没被触发
  （表现：`restoredSpy.last().at(0)` 是 `true`）。此时报告，不要改用 sleep 或其他不确定的手法。
- 修复看起来需要改 `BackupOperations.cpp` 或 `DatabaseManager.cpp`。
- 找不到可用的 Qt 安装路径。
- 你发现「`atomicCopy` 失败时原数据库文件仍然完好」这个前提不成立
  （即失败可能发生在目标文件已被破坏之后）—— 那样单纯重开数据库就不够了，需要重新设计。

## Maintenance notes

- **未来交互点**：如果以后给恢复流程加"重试"按钮，它依赖的正是本计划保证的
  「失败后数据库仍可用」——`requestRestore` 自身要求数据库处于打开状态。
- **评审重点**：
  1. `reopened` 必须在 `&&` 链之外**先行**求值，不能被改回短路写法（这是缺陷本身）；
  2. 测试开关 `m_forceRollbackCopyFailureForTest` 是一次性的（用完立即清零），
     不能出现某个用例置位后污染后续用例；
  3. 三种结局的提示语区分是给用户看的，措辞改动无妨，但"数据库无法打开"这一档必须保留
     并明确要求重启。
- **本计划显式推迟的事项**：
  - `restoreFromPreRestoreSnapshot`（同步路径）的其余失败分支（:331-355）也各自返回 false，
    但那些分支**已经**调用过 `initialize`，数据库是打开的，不属于本缺陷。未改。
  - 异步**备份**（`startBackupJob`）同样缺测试覆盖，不在本计划内，见 plans/README.md 的
    「已考虑」清单。
  - `before-restore-*` 快照永不清理（`pruneAutoBackups` 的过滤器只匹配 `auto-*`）是另一条
    独立缺陷，本计划不碰。
