# Plan 002: 长期目标必须绑定科目，且写入要么整体成功要么整体失败

> **Executor instructions**: 按步骤执行本计划。每一步都要运行验证命令并确认预期结果，
> 再进入下一步。若触发 "STOP conditions" 里的任何一条，立即停下来报告，**不要自行发挥**。
> 完成后更新 `plans/README.md` 里本计划的状态行（除非派发你的评审者说明由他维护索引）。
>
> **Drift check（先跑这个，注意本计划的特殊情况）**：
> 本计划涉及的 `src/services/GoalService.*`、`src/models/LongGoal.*`、`tests/GoalServiceTests.cpp`
> 在 `43ba2ee` 时是**未提交的新文件**，因此 `git diff` 对它们无效。
> 改用直接比对：`grep -n "bool GoalService::validateInput" -A 21 src/services/GoalService.cpp`
> 的输出必须与下面 "Current state" 的第一段摘录逐行一致。不一致就按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `43ba2ee`, 2026-07-26
- **备注**: 本计划针对的是尚未提交的在途功能代码（长期目标，阶段 1-2 已完成，阶段 3+ 的 QML 界面尚未开始）。趁界面还没写，语义还能改，改动成本最低。

## Why this matters

「长期目标」功能的进度算法是：统计**该目标所绑科目**下、起始日之后的有效番茄数。
科目是这个算法的唯一输入维度。但服务层的输入校验只检查了标题和目标番茄数，
**完全没有校验科目**，非法的科目编号会被安静地写成 NULL。

后果是一个看起来一切正常、实际永远坏掉的目标：进度恒为 0%、预计完成天数永远隐藏、
里程碑永不触发，而且全程没有任何错误提示。用户看到的现象和「这个功能是坏的」一模一样。
设计文档 `docs/长期目标与奖励机制落地方案.md` 明确记录了「目标必须绑定一个科目」这条取舍，
但这条约束没有落到代码里。

第二个问题在同一个文件：`addGoal` 的两次写入（插入目标行 + 对齐里程碑位掩码）**没有事务**，
中间那次回读失败会被静默跳过，函数照样返回 `true`。此时目标行已落库但位掩码是 0，
用户下一次随便完成一个番茄，就会收到一条「你已达成 100%！」的庆祝——
庆祝的是他建目标**之前**就做完的历史。这正是现有用例
`newGoalWithBackfilledHistoryDoesNotCelebrate` 想守住的语义，但它只覆盖了成功路径。

第三个问题：`loadGoals` 把「SQL 执行失败」和「没有这一行」返回成同一个空列表，
导致 `updateGoal` 在数据库出错时告诉用户「目标不存在」——用户可能因此去重建一个本来好好存在的目标。

## Current state

### 相关文件

- `src/services/GoalService.cpp` — 长期目标服务实现（约 530 行）。
- `src/services/GoalService.h` — 服务声明；私有方法区在文件末尾。
- `src/models/LongGoal.h` / `.cpp` — 值对象与里程碑位掩码计算。**本计划不改这两个文件。**
- `tests/GoalServiceTests.cpp` — 15 个用例，已覆盖里程碑去重、进度回退、逻辑日边界、完成预测。

### 缺陷 1：`validateInput` 不校验科目（`src/services/GoalService.cpp:259-279`）

```cpp
bool GoalService::validateInput(const QString& title,
                                int targetPomodoros,
                                QString* normalizedTitle)
{
    const QString trimmed = title.trimmed();
    if (trimmed.isEmpty()) {
        reportFailure(QStringLiteral("目标名称不能为空"));
        return false;
    }
    if (trimmed.length() > kMaxTitleLength) {
        // 与任务标题一致：拒绝而不是截断，避免用户以为存下去了却少了一截。
        reportFailure(QStringLiteral("目标名称不能超过 %1 个字").arg(kMaxTitleLength));
        return false;
    }
    if (targetPomodoros <= 0 || targetPomodoros > kMaxTargetPomodoros) {
        reportFailure(QStringLiteral("目标番茄数需在 1 到 %1 之间").arg(kMaxTargetPomodoros));
        return false;
    }
    *normalizedTitle = trimmed;
    return true;
}
```

调用点两处：`addGoal`（:295）和 `updateGoal`（:374），签名都是
`validateInput(title, targetPomodoros, &normalizedTitle)`。

写入时非法科目被安静转成 NULL（`addGoal` :322-323，`updateGoal` :397-398 同形）：

```cpp
    insertQuery.bindValue(QStringLiteral(":categoryId"),
                          categoryId > 0 ? QVariant(categoryId) : QVariant());
```

进度子查询的条件是 `WHERE t.category_id = g.category_id`（:135）；
`g.category_id` 为 NULL 时该比较恒为 NULL，子查询无行，`COALESCE(..., 0)` 得 0。

### 缺陷 2：`loadGoals` 混淆「失败」与「空」（`src/services/GoalService.cpp:143-174`）

```cpp
QList<LongGoal> GoalService::loadGoals(int singleGoalId)
{
    QList<LongGoal> goals;

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        return goals;                      // ← 失败，返回空
    }
    ...
    if (!query.exec()) {
        reportFailure(QStringLiteral("读取长期目标失败: ") + query.lastError().text());
        return goals;                      // ← 失败，返回空
    }

    while (query.next()) {
        goals.append(LongGoal::fromQuery(query));
    }
    return goals;                          // ← 成功，可能为空
}
```

三个调用方据此做出错误判断：
- `updateGoal`（:381-385）：`if (existing.isEmpty())` → 报「目标不存在」
- `getGoal`（:249-252）：失败返回空 `QVariantMap()`，界面会当成「目标被删了」
- `addGoal`（:339-341）：失败时静默跳过里程碑对齐（见缺陷 3）

**同文件内已有正确写法可参照** —— `activeDaysSince`（:205-208）明确区分了两者：

```cpp
    if (!query.exec() || !query.next()) {
        reportFailure(QStringLiteral("统计目标活跃天数失败: ") + query.lastError().text());
        return 0;
    }
```

### 缺陷 3：`addGoal` 无事务、对齐失败被吞（`src/services/GoalService.cpp:337-363`）

```cpp
    // 新目标可能因为起始日回填而立刻就有进度，甚至一建出来就已达标。
    // 这里先对齐一次里程碑，避免把"建目标之前就完成的部分"当成新达成连弹几个窗。
    const int newId = insertQuery.lastInsertId().toInt();
    const QList<LongGoal> created = loadGoals(newId);
    if (!created.isEmpty()) {                      // ← 回读失败时整块被跳过
        const LongGoal& goal = created.first();
        const int mask = LongGoal::milestonesForProgress(goal.doneCount, goal.targetPomodoros);
        if (mask != 0) {
            QSqlQuery seedQuery(db);
            seedQuery.prepare(QStringLiteral(
                "UPDATE long_goals SET fired_milestones = :mask, "
                "achieved_at = CASE WHEN :achieved = 1 THEN :now ELSE achieved_at END "
                "WHERE id = :id"));
            ...
            if (!seedQuery.exec()) {
                reportFailure(QStringLiteral("初始化目标里程碑失败: ") + seedQuery.lastError().text());
            }                                      // ← 只报错，不回滚，不改返回值
        }
    }

    emit goalsChanged();
    return true;                                   // ← 无论对齐成败都返回 true
```

`addGoal` 全程没有 `db.transaction()`。同文件的 `reorderGoal`（:475-498）**已经用了事务**，
可作为写法范式：

```cpp
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        reportFailure(QStringLiteral("目标排序开启事务失败: ") + db.lastError().text());
        return false;
    }
    ...
        if (!query.exec()) {
            const QString error = query.lastError().text();
            db.rollback();
            reportFailure(QStringLiteral("目标排序失败: ") + error);
            return false;
        }
    ...
    if (!db.commit()) {
        reportFailure(QStringLiteral("目标排序提交失败: ") + db.lastError().text());
        return false;
    }
```

### 必须遵守的设计约束（摘自 `docs/长期目标与奖励机制落地方案.md`）

执行者没读过这份文档，以下三条直接内联，**改动不得违背它们**：

1. **进度不落库**：`LongGoal` 不存已完成数量，进度一律由 `focus_sessions` 子查询现算。
   > 「删掉一条专注记录，进度自动回退，不需要任何补偿逻辑。」
   本计划不得引入任何缓存的进度字段。
2. **目标必须绑定一个科目**：
   > 「代价：目标必须绑定一个科目，无法表达『读完 30 本书』这种和专注无关的目标。这个取舍我认为值。」
   本计划就是把这条约束落到代码里。
3. **位掩码只增不减**：`refreshMilestones` 只做按位或，绝不清位（防止撤销专注记录后重复庆祝）；
   只有 `updateGoal` 改目标值时才重算掩码。本计划**不改动**这条语义。

### 科目被删除时的既定行为（`src/models/LongGoal.h:33-36`，不要改）

```cpp
    // 目标绑定的科目；进度只统计该科目下任务的专注记录。
    // 科目被删除时置空（外键 ON DELETE SET NULL），此时进度恒为 0，但目标本身保留，
    // 让用户能改绑而不是连目标一起消失。
    int categoryId = -1;
```

**这意味着新校验只能加在写入路径，不能加在读取路径** ——
库里存量的 NULL 科目目标必须仍然能被 `getGoals()` / `getGoal()` 读出来并改绑。

### 仓库约定（摘自 `AGENTS.md`）

- 注释必须用中文，解释「为什么这样做」和「边界条件是什么」，不要逐行翻译代码。
- 优先注释：事务、跨层调用、兼容旧数据的逻辑。
- 不要给简单赋值和显而易见的属性加噪音注释。
- Git 提交说明必须用中文。

## Commands you will need

| 用途 | 命令 | 成功标志 |
|---|---|---|
| 配置 | `cmake -B /tmp/pt-002 -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | 退出码 0 |
| 构建本套件 | `cmake --build /tmp/pt-002 --target GoalServiceTests -j8` | 退出码 0 |
| 跑本套件 | `QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests` | `Totals: N passed, 0 failed` |
| 跑服务层主套件 | `cmake --build /tmp/pt-002 --target PomodoroTodoTests -j8 && QT_QPA_PLATFORM=offscreen /tmp/pt-002/PomodoroTodoTests` | 全绿 |
| 全量测试 | `cd /tmp/pt-002 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | `100% tests passed ... out of 12` |

Qt 路径不存在时用 `ls ~/Qt` 找实际版本目录替换；仍找不到按 STOP condition 处理。

**注意**：`tests/ServiceTests.cpp` 里有一个端到端用例
`realPomodoroSessionAdvancesLongGoalAndFiresMilestone` 会调用 `GoalService::addGoal`，
本计划改了 `addGoal` 的校验后**必须**跑 `PomodoroTodoTests` 确认它仍然通过。

## Scope

**In scope（只允许修改这三个文件）**：

- `src/services/GoalService.cpp`
- `src/services/GoalService.h`
- `tests/GoalServiceTests.cpp`

**Out of scope（即使看起来相关也不要动）**：

- `src/models/LongGoal.h` / `.cpp` —— 值对象与位掩码算法本身没有问题，且
  `milestonesForProgress` 的「向上取整、不提前庆祝」语义已被测试锁定，不要碰。
- `src/services/GoalService.cpp` 里 `refreshMilestones`（:505 起）的「只增不减」逻辑 ——
  这是刻意设计（防止撤销专注记录后重复庆祝），不是缺陷。
- `goalSelectSql()`（:121-141）的进度子查询 —— 「进度不落库、每次现算」是既定取舍。
- `tests/ServiceTests.cpp` —— 端到端用例只需**通过**，不需要修改。
  如果它因为新校验而失败，说明它建目标时没传有效科目，那是它的问题；
  但**先报告**，不要擅自改动这个 4000 行的文件。
- `src/main.cpp` 的 `FocusTimer::focusCompleted → GoalService::refreshMilestones` 连接 —— 不动。
- 任何 QML 文件 —— 长期目标的界面尚未开始，本计划纯 C++。

## Git workflow

- 分支：`advisor/002-goalservice-validation`
- 每个 Step 一次提交，说明用中文。参考现有风格（`git log --oneline -5`）：
  `导出日期校验只认 yyyy-MM-dd`、`忽略 build-* 变体构建目录`
- 建议：
  - Step 1：`长期目标必须绑定科目`
  - Step 2：`区分目标读取失败与目标不存在`
  - Step 3：`新建目标的插入与里程碑对齐纳入同一事务`
- **不要 push，不要开 PR**。

## Steps

### Step 1: `validateInput` 增加科目校验

**1a.** 在 `src/services/GoalService.h` 里把私有方法声明改成带 `categoryId`：

```cpp
    bool validateInput(const QString& title,
                       int categoryId,
                       int targetPomodoros,
                       QString* normalizedTitle);
```

**1b.** 在 `src/services/GoalService.cpp:259` 修改实现，在目标番茄数校验**之后**、
`*normalizedTitle = trimmed;` **之前**插入科目校验：

```cpp
bool GoalService::validateInput(const QString& title,
                                int categoryId,
                                int targetPomodoros,
                                QString* normalizedTitle)
{
    ...（标题与目标番茄数的三段校验保持原样）...

    // 进度只统计所绑科目下的专注记录，没有科目的目标进度恒为 0、里程碑永不触发，
    // 表现和"功能坏了"完全一样。所以科目在写入路径是必填项，宁可拒绝也不要静默存成 NULL。
    // 注意：读取路径不做这个校验——科目被删除时外键会把已有目标的 category_id 置空，
    // 那些存量目标必须仍能被读出来并改绑。
    if (categoryId <= 0) {
        reportFailure(QStringLiteral("请先为目标选择科目"));
        return false;
    }

    *normalizedTitle = trimmed;
    return true;
}
```

**1c.** 更新两个调用点：
- `addGoal`（:295）：`if (!validateInput(title, categoryId, targetPomodoros, &normalizedTitle)) {`
- `updateGoal`（:374）：同上

**Verify**：
`cmake --build /tmp/pt-002 --target GoalServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests` → `Totals: 15 passed, 0 failed`
（本步不新增用例；15 个既有用例必须全绿。若基线不是 15，见 STOP conditions。）

### Step 2: 区分「读取失败」与「目标不存在」

**2a.** 在 `src/services/GoalService.h` 给 `loadGoals` 加一个可选出参：

```cpp
    // ok 为可选出参：区分"查询失败"（false）与"查询成功但没有匹配行"（true + 空列表）。
    // 两者合并会让数据库出错时被误报成"目标不存在"，用户可能因此去重建一个本来存在的目标。
    QList<LongGoal> loadGoals(int singleGoalId, bool* ok = nullptr);
```

**2b.** 在 `src/services/GoalService.cpp:143` 的实现里，三个返回点分别置位：

```cpp
QList<LongGoal> GoalService::loadGoals(int singleGoalId, bool* ok)
{
    QList<LongGoal> goals;
    if (ok) {
        *ok = false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        return goals;
    }
    ...
    if (!query.exec()) {
        reportFailure(QStringLiteral("读取长期目标失败: ") + query.lastError().text());
        return goals;
    }

    while (query.next()) {
        goals.append(LongGoal::fromQuery(query));
    }
    if (ok) {
        *ok = true;
    }
    return goals;
}
```

**2c.** 在 `updateGoal`（:379 附近）区分两种情况：

```cpp
    bool loadOk = false;
    const QList<LongGoal> existing = loadGoals(goalId, &loadOk);
    if (!loadOk) {
        // 读取本身失败时不能说"目标不存在"——目标可能好好地在库里，
        // 用户按这句提示去重建会得到一个重复目标。
        reportFailure(QStringLiteral("读取目标失败，请重试"));
        return false;
    }
    if (existing.isEmpty()) {
        reportFailure(QStringLiteral("目标不存在"));
        return false;
    }
```

**2d.** 在 `getGoal`（:243 附近）同样区分。失败与不存在都返回空 map（界面契约不变），
但失败时要经 `reportFailure` 发出 `operationFailed`，让界面能提示「读取失败」而不是静默变空：

```cpp
    bool loadOk = false;
    const QList<LongGoal> goals = loadGoals(goalId, &loadOk);
    if (!loadOk) {
        reportFailure(QStringLiteral("读取目标失败，请重试"));
        return QVariantMap();
    }
    if (goals.isEmpty()) {
        return QVariantMap();
    }
```

**Verify**：
`cmake --build /tmp/pt-002 --target GoalServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests` → `Totals: 15 passed, 0 failed`

### Step 3: `addGoal` 纳入单一事务

把 `addGoal` 里「插入目标行 → 回读进度 → 写里程碑掩码」三步包进一个事务，
任一步失败即整体回滚并返回 `false`。

在 `src/services/GoalService.cpp` 的 `addGoal` 中：

**3a.** 在取 `display_order` 之后、`insertQuery` 之前开启事务：

```cpp
    // 插入目标行与对齐里程碑掩码必须同生共死：只落库不对齐的话，
    // 用户下一次完成任意番茄时，refreshMilestones 会把"建目标之前就做完的历史"
    // 当成刚刚达成，一次性弹出最高档庆祝。
    if (!db.transaction()) {
        reportFailure(QStringLiteral("新建目标开启事务失败: ") + db.lastError().text());
        return false;
    }
```

**3b.** `insertQuery.exec()` 失败分支补 `db.rollback();`：

```cpp
    if (!insertQuery.exec()) {
        const QString error = insertQuery.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("新建目标失败: ") + error);
        return false;
    }
```

**3c.** 回读改用带 `ok` 的重载，失败即回滚：

```cpp
    const int newId = insertQuery.lastInsertId().toInt();
    bool loadOk = false;
    const QList<LongGoal> created = loadGoals(newId, &loadOk);
    if (!loadOk || created.isEmpty()) {
        db.rollback();
        reportFailure(QStringLiteral("新建目标后回读失败，已撤销本次新建"));
        return false;
    }
```

**3d.** 掩码写入失败改成回滚 + 返回 false（原来只报错就放过）：

```cpp
            if (!seedQuery.exec()) {
                const QString error = seedQuery.lastError().text();
                db.rollback();
                reportFailure(QStringLiteral("初始化目标里程碑失败: ") + error);
                return false;
            }
```

**3e.** 在 `emit goalsChanged();` 之前提交：

```cpp
    if (!db.commit()) {
        reportFailure(QStringLiteral("新建目标提交失败: ") + db.lastError().text());
        return false;
    }

    emit goalsChanged();
    return true;
```

**注意**：`loadGoals` 在事务内复用的是同一个数据库连接，SQLite 同连接内读自己未提交的写是正常的，
不需要额外处理。

**Verify**：
`cmake --build /tmp/pt-002 --target GoalServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests` → `Totals: 15 passed, 0 failed`
特别确认 `newGoalWithBackfilledHistoryDoesNotCelebrate` 仍然通过（事务不能破坏回填对齐语义）。

### Step 4: 补校验用例

在 `tests/GoalServiceTests.cpp` 的 `private slots:` 区，
`rejectsEmptyOverlongTitlesAndInvalidTargets();` 之后声明：

```cpp
    void rejectsGoalWithoutCategory();
    void goalWithClearedCategoryStaysReadableAndRebindable();
```

在 `rejectsEmptyOverlongTitlesAndInvalidTargets` 的实现之后追加：

```cpp
void GoalServiceTests::rejectsGoalWithoutCategory()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(categoryId > 0);

    // 没有科目的目标进度恒为 0、里程碑永不触发，必须在写入时就拒绝。
    QVERIFY(!service->addGoal(QStringLiteral("无科目目标"), 0, 100, QVariant(), QVariant()));
    QVERIFY(!service->addGoal(QStringLiteral("负数科目"), -1, 100, QVariant(), QVariant()));
    QVERIFY(service->getGoals().isEmpty());

    // 已存在的目标也不允许把科目清空。
    QVERIFY(service->addGoal(QStringLiteral("英语精读"), categoryId, 100, QVariant(), QVariant()));
    const int goalId = service->getGoals().first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(!service->updateGoal(goalId, QStringLiteral("英语精读"), 0, 100,
                                 QVariant(), QVariant()));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("categoryId")).toInt(), categoryId);
}

void GoalServiceTests::goalWithClearedCategoryStaysReadableAndRebindable()
{
    GoalService* service = GoalService::instance();
    const int oldCategory = addCategory(QStringLiteral("旧科目"));
    const int newCategory = addCategory(QStringLiteral("新科目"));
    QVERIFY(oldCategory > 0 && newCategory > 0);

    QVERIFY(service->addGoal(QStringLiteral("待改绑目标"), oldCategory, 100,
                             QVariant(), QVariant()));
    const int goalId = service->getGoals().first().toMap().value(QStringLiteral("id")).toInt();

    // 模拟科目被删除后外键把 category_id 置空的存量数据：
    // 校验只加在写入路径，这类目标必须仍能读出来并改绑，不能连读都读不到。
    QSqlQuery clearCategory(DatabaseManager::instance()->database());
    clearCategory.prepare(QStringLiteral(
        "UPDATE long_goals SET category_id = NULL WHERE id = :id"));
    clearCategory.bindValue(QStringLiteral(":id"), goalId);
    QVERIFY(clearCategory.exec());

    const QVariantMap orphan = service->getGoal(goalId);
    QVERIFY2(!orphan.isEmpty(), "科目被清空的存量目标必须仍能读出来");
    QCOMPARE(orphan.value(QStringLiteral("doneCount")).toInt(), 0);

    // 改绑到一个有效科目应当成功。
    QVERIFY(service->updateGoal(goalId, QStringLiteral("待改绑目标"), newCategory, 100,
                                QVariant(), QVariant()));
    QCOMPARE(service->getGoal(goalId).value(QStringLiteral("categoryId")).toInt(), newCategory);
}
```

`addCategory` 是该文件已有的私有辅助（返回新建科目 id），直接用。

**Verify**：
`cmake --build /tmp/pt-002 --target GoalServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests` → `Totals: 17 passed, 0 failed`

**关键回归确认（必须做）**：临时把 Step 1b 的科目校验整段注释掉，重新构建，只跑
`QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests rejectsGoalWithoutCategory`
→ **必须失败**。确认后恢复，重新构建确认全绿。若仍然通过，说明用例没锁住行为，按 STOP condition 处理。

### Step 5: 全量回归

**Verify**：
`cmake --build /tmp/pt-002 -j8` → 退出码 0
`cd /tmp/pt-002 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure`
→ `100% tests passed, 0 tests failed out of 12`

若 `PomodoroTodoTests` 里的 `realPomodoroSessionAdvancesLongGoalAndFiresMilestone` 失败，
**先报告**（见 Out of scope），不要修改 `tests/ServiceTests.cpp`。

## Test plan

- 新增文件：无。用例写在 `tests/GoalServiceTests.cpp`。
- 结构范式：照同文件的 `rejectsEmptyOverlongTitlesAndInvalidTargets`（纯服务层调用 + `QVERIFY`），
  以及 `progressCountsOnlyValidPomodorosOfBoundCategory`（造科目/任务/专注记录再断言聚合）。
- 覆盖的用例：
  1. `rejectsGoalWithoutCategory` —— 新建与编辑都拒绝空科目（`categoryId <= 0`）。
  2. `goalWithClearedCategoryStaysReadableAndRebindable` —— 科目被删后置空的存量目标
     仍可读、可改绑（确保新校验没有误伤读取路径）。
- 事务行为（Step 3）没有单独用例：要构造「插入成功但回读失败」需要注入 SQL 错误，
  成本高于收益。现有 `newGoalWithBackfilledHistoryDoesNotCelebrate` 覆盖了成功路径的语义。
  这一点在 Maintenance notes 里记为已知缺口。
- 验证：`QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests` → 17 passed（原 15 + 新 2）。

## Done criteria

全部必须成立：

- [ ] `cmake --build /tmp/pt-002 -j8` 退出码 0
- [ ] `cd /tmp/pt-002 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` → `100% tests passed ... out of 12`
- [ ] `QT_QPA_PLATFORM=offscreen /tmp/pt-002/GoalServiceTests` → `Totals: 17 passed, 0 failed`
- [ ] Step 4 的「关键回归确认」已执行：注释掉校验后 `rejectsGoalWithoutCategory` 确实失败
- [ ] `grep -n "validateInput(title, categoryId, targetPomodoros" src/services/GoalService.cpp` → 恰好 2 处命中（addGoal 与 updateGoal）
- [ ] `grep -n "db.transaction()" src/services/GoalService.cpp` → 至少 2 处命中（addGoal 与既有的 reorderGoal）
- [ ] `git status --porcelain` 只显示这三个文件被修改：`src/services/GoalService.cpp`、`src/services/GoalService.h`、`tests/GoalServiceTests.cpp`
- [ ] `plans/README.md` 中 002 的状态行已更新

## STOP conditions

出现以下任一情况，停下来报告，不要自行发挥：

- Drift check 的 `grep` 输出与 "Current state" 第一段摘录不一致。
- 修改前 `GoalServiceTests` 的用例数不是 15，或修改前就有用例失败。
- Step 4 的「关键回归确认」中，注释掉校验后 `rejectsGoalWithoutCategory` **仍然通过**。
- `tests/ServiceTests.cpp` 的 `realPomodoroSessionAdvancesLongGoalAndFiresMilestone` 因新校验失败
  ——**报告，不要改那个文件**。
- 你发现 `refreshMilestones` 或 `goalSelectSql` 也需要改才能让计划落地 ——
  它们在 Out of scope 里，说明本计划的前提有误。
- 你发现「科目被删除时目标的 `category_id` 会被置空」这个前提不成立
  （例如外键实际是 CASCADE，目标会被连带删除）—— 那样 Step 4 的第二个用例前提就不对了。
- 找不到可用的 Qt 安装路径。

## Maintenance notes

- **未来交互点**：长期目标的 QML 界面（设计方案里的阶段 3）还没开始写。
  新建/编辑目标的表单**必须**提供科目选择器且不允许留空，否则用户会撞上本计划新增的拒绝提示。
  `operationFailed(QString)` 信号是界面展示错误的唯一入口。
- **评审重点**：
  1. 科目校验只在写入路径（`validateInput`），**没有**渗进 `loadGoals` / `getGoal` /
     `goalSelectSql` —— 一旦渗进读取路径，科目被删后的存量目标会直接从列表里消失；
  2. `addGoal` 的每个失败分支都要有对应的 `db.rollback()`，不能有漏网的早退；
  3. `loadGoals` 的 `ok` 出参在**所有**返回点都被正确置位，尤其是 `!db.isOpen()` 那条早退。
- **本计划显式推迟的事项**：
  - 「插入成功但回读失败」这条事务分支没有单元测试（需要注入 SQL 错误，成本高于收益）。
    如果以后给 `GoalService` 加了测试用的错误注入钩子（可参考 plans/001 给 BackupService
    加的受控友元开关），应当补上。
  - `getGoals()` 对每个目标额外发一条 `activeDaysSince` 查询（N+1）。目标数量是个位数量级，
    当前不痛；若目标列表变长，应把 `COUNT(DISTINCT ...)` 并进 `goalSelectSql` 的第二个子查询。
    不在本计划内。
  - `deleteGoal` / `reorderGoal` 的测试缺口由 plans/004 覆盖。
