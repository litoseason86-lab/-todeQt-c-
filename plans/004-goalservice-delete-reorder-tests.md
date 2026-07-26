# Plan 004: 为长期目标的删除与重排补单元测试

> **Executor instructions**: 按步骤执行本计划。每一步都要运行验证命令并确认预期结果，
> 再进入下一步。若触发 "STOP conditions" 里的任何一条，立即停下来报告，**不要自行发挥**。
> 完成后更新 `plans/README.md` 里本计划的状态行（除非派发你的评审者说明由他维护索引）。
>
> **Drift check（先跑这个，注意本计划的特殊情况）**：
> `src/services/GoalService.cpp` 与 `tests/GoalServiceTests.cpp` 在 `43ba2ee` 时是**未提交的新文件**，
> `git diff` 对它们无效。改用直接比对：
> `grep -n "bool GoalService::reorderGoal" -A 45 src/services/GoalService.cpp`
> 的输出必须与下面 "Current state" 的第二段摘录一致。不一致就按 STOP condition 处理。

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/002-goalservice-validation-and-error-semantics.md
- **Category**: tests
- **Planned at**: commit `43ba2ee`, 2026-07-26

## Why this matters

「长期目标」的服务层已经有 15 个单元测试，覆盖了这个功能里最难的部分：里程碑位掩码去重、
进度回退后不重复庆祝、逻辑日边界、完成天数预测。但**两个写路径完全没有测试**：
`deleteGoal` 和 `reorderGoal`。

`reorderGoal` 不是一个平凡函数——它做整表重写 `display_order`，带事务、逐行 UPDATE、
下标越界校验和失败回滚。它出错的表现是**目标顺序静默错乱**，或者 `display_order` 全部塌成同一个值，
而界面上看不出和「用户自己拖成这样」的区别。

时机上这是最便宜的一刻：设计方案里的阶段 3（目标列表页，含拖拽排序）还没开始写，
一旦 QML 接上去，这两个函数的语义就被界面钉死了，改起来要连带改界面。现在补测试，
既锁住当前行为，也让阶段 3 的开发者有一份可执行的语义说明。

## Current state

### 相关文件

- `src/services/GoalService.cpp` — 长期目标服务实现。本计划**只读不改**。
- `tests/GoalServiceTests.cpp` — 15 个用例（若 plans/002 已执行则是 17 个）。本计划只改这一个文件。

### 被测函数 1：`deleteGoal`（`src/services/GoalService.cpp:435-456`）

```cpp
bool GoalService::deleteGoal(int goalId)
{
    if (!ensureDatabaseReady()) {
        return false;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("DELETE FROM long_goals WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), goalId);

    if (!query.exec()) {
        reportFailure(QStringLiteral("删除目标失败: ") + query.lastError().text());
        return false;
    }
    if (query.numRowsAffected() <= 0) {
        reportFailure(QStringLiteral("目标不存在"));
        return false;
    }

    emit goalsChanged();
    return true;
}
```

要锁住的语义：删除不存在的 id 返回 `false`；删除成功后该目标不再出现在 `getGoals()` 里；
**删除一个目标不影响其他目标的进度**（因为进度是从 `focus_sessions` 现算的，不是存在目标行里的）。

### 被测函数 2：`reorderGoal`（`src/services/GoalService.cpp:458-502`）

```cpp
bool GoalService::reorderGoal(int fromIndex, int toIndex)
{
    if (fromIndex == toIndex) {
        return true;
    }
    if (!ensureDatabaseReady()) {
        return false;
    }

    QList<LongGoal> goals = loadGoals(-1);
    if (fromIndex < 0 || fromIndex >= goals.size() || toIndex < 0 || toIndex >= goals.size()) {
        reportFailure(QStringLiteral("目标排序下标越界"));
        return false;
    }

    goals.move(fromIndex, toIndex);

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        reportFailure(QStringLiteral("目标排序开启事务失败: ") + db.lastError().text());
        return false;
    }

    // 整表重写 display_order：目标数量是个位数量级，比维护稀疏序号简单且不会退化。
    for (int i = 0; i < goals.size(); ++i) {
        QSqlQuery query(db);
        query.prepare(QStringLiteral("UPDATE long_goals SET display_order = :order WHERE id = :id"));
        query.bindValue(QStringLiteral(":order"), i);
        query.bindValue(QStringLiteral(":id"), goals.at(i).id);
        if (!query.exec()) {
            const QString error = query.lastError().text();
            db.rollback();
            reportFailure(QStringLiteral("目标排序失败: ") + error);
            return false;
        }
    }

    if (!db.commit()) {
        reportFailure(QStringLiteral("目标排序提交失败: ") + db.lastError().text());
        return false;
    }

    emit goalsChanged();
    return true;
}
```

关键语义（测试要逐条锁住）：

1. 参数是**列表下标**（0 起），不是目标 id。
2. `fromIndex == toIndex` 直接返回 `true`，不写库、不发信号。
3. 任一下标越界返回 `false`，且**不改动任何数据**。
4. 语义是 `QList::move`：把 `fromIndex` 处的元素**移动到** `toIndex` 位置，其余元素依次顺移
   （不是「交换两个位置」）。例如 `[A,B,C]` 执行 `move(0, 2)` 得到 `[B,C,A]`。
5. 重写后 `display_order` 是从 0 开始的连续整数。
6. `getGoals()` 的排序依据是 `ORDER BY g.display_order ASC, g.id ASC`（见 `loadGoals` :156）。

### 现有测试文件的结构（`tests/GoalServiceTests.cpp`）

私有辅助方法（直接复用，不要重写）：

```cpp
private:
    void clearAll();
    int addCategory(const QString& name);
    int addTask(const QString& title, int categoryId);
    void insertSession(int taskId, const QDateTime& startTime, int durationSeconds, int mode);
    int addGoalReturningId(const QString& title, int categoryId, int target, const QDate& startDate);
```

fixture：

```cpp
void GoalServiceTests::init()
{
    clearAll();
    // 绝大多数用例把逻辑日对齐到物理日，避免断言受当前钟点影响；
    // 只有 progressFollowsLogicalDayBoundary 会单独改成 4 点。
    AppSettings::instance()->setDayStartHour(0);
}
```

`clearAll()` 会清空 `long_goals`、`focus_sessions`、`tasks`、`categories` 及其自增序列。

一个可作结构范式的现有用例：

```cpp
void GoalServiceTests::progressCountsOnlyValidPomodorosOfBoundCategory()
{
    GoalService* service = GoalService::instance();
    const int englishId = addCategory(QStringLiteral("英语"));
    ...
    const int goalId = addGoalReturningId(QStringLiteral("英语精读"), englishId, 100,
                                          QDate::currentDate().addDays(-1));
    QVERIFY(goalId > 0);

    const QVariantMap goal = service->getGoal(goalId);
    QCOMPARE(goal.value(QStringLiteral("doneCount")).toInt(), 2);
}
```

注意 `addGoalReturningId` 的实现是「addGoal 后取 `getGoals().last()` 的 id」——
它依赖新目标排在列表末尾。这在本计划的重排用例里**不成立**（重排之后末尾不再是最新建的），
所以重排用例要在**所有目标都建完之后**再取 id 序列，不要在重排之后调用 `addGoalReturningId`。

### 有效番茄的口径（写进度相关断言时需要）

摘自 `src/services/FocusSessionRules.h`：

- `kMinimumValidDurationSeconds = 3 * 60` —— 少于 3 分钟的会话不计入。
- `kPomodoroMode = 1` —— 只有番茄模式（`focus_sessions.mode = 1`）折算番茄；自由计时（0）不算。

测试文件顶部已定义：

```cpp
constexpr int kValidPomodoroSeconds = FocusSessionRules::kMinimumValidDurationSeconds + 60;
```

### 仓库约定

- 注释必须用中文，解释「为什么这样做」和「边界条件是什么」。
  `AGENTS.md` 特别要求注释「测试中为了稳定性或隔离环境而做的特殊处理」。
- Git 提交说明必须用中文。
- **QML 测试的已知约束**（本计划不涉及 QML，但供参考）：不要断言 `item.visible === true`。

## Commands you will need

| 用途 | 命令 | 成功标志 |
|---|---|---|
| 配置 | `cmake -B /tmp/pt-004 -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | 退出码 0 |
| 构建本套件 | `cmake --build /tmp/pt-004 --target GoalServiceTests -j8` | 退出码 0 |
| 跑本套件 | `QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests` | `Totals: N passed, 0 failed` |
| 跑单个用例 | `QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests <用例名>` | 该用例 PASS |
| 全量测试 | `cd /tmp/pt-004 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | `100% tests passed ... out of 12` |

`<Qt前缀>`：`ls ~/Qt` 找实际版本目录；找不到用 `brew --prefix qt`。两者都没有按 STOP condition 处理。

## Scope

**In scope（只允许修改这一个文件）**：

- `tests/GoalServiceTests.cpp`

**Out of scope（不要动）**：

- `src/services/GoalService.cpp` / `.h` —— **本计划只补测试，不改被测代码。**
  如果测试暴露出 `deleteGoal` / `reorderGoal` 的真实缺陷，**报告，不要顺手修**
  （修复需要单独评估影响面，且会让"测试锁住的是当前行为还是新行为"变得含糊）。
- `src/models/LongGoal.h` / `.cpp`
- `CMakeLists.txt` —— `GoalServiceTests` 目标已存在，不需要改构建。
- 其他任何测试文件。

## Git workflow

- 分支：`advisor/004-goalservice-delete-reorder-tests`
- 一次提交即可，说明用中文。参考现有风格：`新增 CoreLogicTests 补齐核心逻辑覆盖缺口`
- 建议：`补长期目标删除与重排的单元测试`
- **不要 push，不要开 PR**。

## Steps

### Step 1: 确认基线

```bash
cmake -B /tmp/pt-004 -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /tmp/pt-004 --target GoalServiceTests -j8
QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests
```

**Verify**：`Totals: 15 passed, 0 failed`
（若 plans/002 已经执行过，基线是 `17 passed`。两者之一都可以，记下这个数字，
后面的期望值 = 基线 + 5。若既不是 15 也不是 17，按 STOP condition 处理。）

### Step 2: 声明 5 个新用例

在 `tests/GoalServiceTests.cpp` 的 `private slots:` 区，
最后一个用例声明（`raisingTargetClearsStaleMilestonesSoTheyCanFireAgain();`）之后加入：

```cpp
    // 删除与重排（阶段 3 的目标列表页会直接调用这两个写路径）
    void deleteGoalRemovesItAndLeavesOtherProgressIntact();
    void deleteGoalRejectsUnknownId();
    void reorderGoalMovesEntryAndRewritesDisplayOrder();
    void reorderGoalRejectsOutOfRangeIndexWithoutTouchingData();
    void reorderGoalWithSameIndexIsNoOp();
```

### Step 3: 实现删除相关的两个用例

在文件末尾 `QTEST_MAIN(GoalServiceTests)` **之前**追加：

```cpp
void GoalServiceTests::deleteGoalRemovesItAndLeavesOtherProgressIntact()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int taskId = addTask(QStringLiteral("精读"), categoryId);
    QVERIFY(categoryId > 0 && taskId > 0);

    const QDateTime now = QDateTime::currentDateTime();
    for (int i = 0; i < 3; ++i) {
        insertSession(taskId, now, kValidPomodoroSeconds, FocusSessionRules::kPomodoroMode);
    }

    const QDate start = QDate::currentDate().addDays(-1);
    const int firstId = addGoalReturningId(QStringLiteral("要删掉的"), categoryId, 100, start);
    const int secondId = addGoalReturningId(QStringLiteral("要保留的"), categoryId, 100, start);
    QVERIFY(firstId > 0 && secondId > 0);
    QCOMPARE(service->getGoals().size(), 2);

    QVERIFY(service->deleteGoal(firstId));
    const QVariantList remaining = service->getGoals();
    QCOMPARE(remaining.size(), 1);
    QCOMPARE(remaining.first().toMap().value(QStringLiteral("id")).toInt(), secondId);
    QVERIFY(service->getGoal(firstId).isEmpty());

    // 进度是从 focus_sessions 现算的，不存在目标行里，所以删掉一个目标
    // 绝不该影响另一个目标的进度。这条断言就是守住"进度不落库"这个设计前提。
    QCOMPARE(service->getGoal(secondId).value(QStringLiteral("doneCount")).toInt(), 3);
}

void GoalServiceTests::deleteGoalRejectsUnknownId()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const int goalId = addGoalReturningId(QStringLiteral("唯一目标"), categoryId, 100,
                                          QDate::currentDate());
    QVERIFY(goalId > 0);

    // 删一个不存在的 id 必须失败，而不是静默"成功"——界面据此判断要不要刷新列表。
    QVERIFY(!service->deleteGoal(goalId + 999));
    QCOMPARE(service->getGoals().size(), 1);

    // 同一个 id 删两次：第二次也必须失败。
    QVERIFY(service->deleteGoal(goalId));
    QVERIFY(!service->deleteGoal(goalId));
    QVERIFY(service->getGoals().isEmpty());
}
```

**Verify**：
`cmake --build /tmp/pt-004 --target GoalServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests deleteGoalRemovesItAndLeavesOtherProgressIntact` → PASS
`QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests deleteGoalRejectsUnknownId` → PASS

### Step 4: 实现重排相关的三个用例

继续在 `QTEST_MAIN` 之前追加。**注意**：`reorderGoal` 的参数是列表下标不是目标 id；
移动语义是 `QList::move`（移动+顺移），不是交换。

```cpp
void GoalServiceTests::reorderGoalMovesEntryAndRewritesDisplayOrder()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(categoryId > 0);

    const QDate start = QDate::currentDate();
    // 三个目标必须一次性建完再取 id 序列：addGoalReturningId 依赖"新目标排在末尾"，
    // 这个前提在重排之后就不再成立了。
    QVERIFY(service->addGoal(QStringLiteral("甲"), categoryId, 100, start, QVariant()));
    QVERIFY(service->addGoal(QStringLiteral("乙"), categoryId, 100, start, QVariant()));
    QVERIFY(service->addGoal(QStringLiteral("丙"), categoryId, 100, start, QVariant()));

    auto titlesInOrder = [service]() {
        QStringList titles;
        const QVariantList goals = service->getGoals();
        for (const QVariant& entry : goals) {
            titles.append(entry.toMap().value(QStringLiteral("title")).toString());
        }
        return titles;
    };

    QCOMPARE(titlesInOrder(), QStringList({QStringLiteral("甲"),
                                           QStringLiteral("乙"),
                                           QStringLiteral("丙")}));

    // move(0, 2)：把第 0 项移动到第 2 位，其余顺移 → 乙丙甲。不是"交换首尾"。
    QVERIFY(service->reorderGoal(0, 2));
    QCOMPARE(titlesInOrder(), QStringList({QStringLiteral("乙"),
                                           QStringLiteral("丙"),
                                           QStringLiteral("甲")}));

    // 重排后 display_order 必须是从 0 开始的连续整数，
    // 否则后续插入新目标时取 MAX(display_order)+1 会算出错位的序号。
    const QVariantList goals = service->getGoals();
    for (int i = 0; i < goals.size(); ++i) {
        QCOMPARE(goals.at(i).toMap().value(QStringLiteral("displayOrder")).toInt(), i);
    }

    // 反向移动一次，确认不是只在某个方向上正确。
    QVERIFY(service->reorderGoal(2, 0));
    QCOMPARE(titlesInOrder(), QStringList({QStringLiteral("甲"),
                                           QStringLiteral("乙"),
                                           QStringLiteral("丙")}));
}

void GoalServiceTests::reorderGoalRejectsOutOfRangeIndexWithoutTouchingData()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    const QDate start = QDate::currentDate();
    QVERIFY(service->addGoal(QStringLiteral("甲"), categoryId, 100, start, QVariant()));
    QVERIFY(service->addGoal(QStringLiteral("乙"), categoryId, 100, start, QVariant()));

    auto titlesInOrder = [service]() {
        QStringList titles;
        const QVariantList goals = service->getGoals();
        for (const QVariant& entry : goals) {
            titles.append(entry.toMap().value(QStringLiteral("title")).toString());
        }
        return titles;
    };
    const QStringList before = titlesInOrder();

    // 越界必须返回 false 并且分毫不动：拖拽 UI 传错下标时不能把顺序搅乱。
    QVERIFY(!service->reorderGoal(-1, 0));
    QVERIFY(!service->reorderGoal(0, -1));
    QVERIFY(!service->reorderGoal(2, 0));
    QVERIFY(!service->reorderGoal(0, 2));
    QVERIFY(!service->reorderGoal(99, 100));

    QCOMPARE(titlesInOrder(), before);
}

void GoalServiceTests::reorderGoalWithSameIndexIsNoOp()
{
    GoalService* service = GoalService::instance();
    const int categoryId = addCategory(QStringLiteral("英语"));
    QVERIFY(service->addGoal(QStringLiteral("甲"), categoryId, 100,
                             QDate::currentDate(), QVariant()));

    QSignalSpy changedSpy(service, &GoalService::goalsChanged);

    // 拖回原位是最常见的误操作，必须直接返回 true 且不写库、不发变更信号，
    // 否则界面会为一次无意义的操作整列表重建。
    QVERIFY(service->reorderGoal(0, 0));
    QCOMPARE(changedSpy.count(), 0);

    // 注意：空列表时 reorderGoal(0, 0) 也会因为 from == to 而提前返回 true，
    // 这是刻意的短路，不是漏判越界。
    QVERIFY(service->reorderGoal(5, 5));
    QCOMPARE(changedSpy.count(), 0);
}
```

若文件顶部还没有 `#include <QSignalSpy>` 或 `#include <QStringList>`，补上
（`<QtTest>` 通常已带 `QSignalSpy`，先构建看是否报错）。

**Verify**：
`cmake --build /tmp/pt-004 --target GoalServiceTests -j8` → 退出码 0
`QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests` → `Totals: <基线+5> passed, 0 failed`

如果 `reorderGoalMovesEntryAndRewritesDisplayOrder` 失败且失败点是移动语义
（例如实际得到「丙乙甲」说明是交换而不是移动），**不要改被测代码**，
按 STOP condition 报告——那说明本计划对 `QList::move` 语义的理解与实现不符，需要人来定夺哪个是对的。

### Step 5: 全量回归

**Verify**：
`cmake --build /tmp/pt-004 -j8` → 退出码 0
`cd /tmp/pt-004 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure`
→ `100% tests passed, 0 tests failed out of 12`

## Test plan

- 新增文件：无。5 个用例全部写在 `tests/GoalServiceTests.cpp`。
- 结构范式：照同文件的 `progressCountsOnlyValidPomodorosOfBoundCategory`
  （建科目 → 建任务 → 插专注记录 → 建目标 → 断言）。
- 覆盖清单：

  | 用例 | 锁住的语义 |
  |---|---|
  | `deleteGoalRemovesItAndLeavesOtherProgressIntact` | 删除生效；**删一个不影响另一个的进度**（守住"进度不落库"） |
  | `deleteGoalRejectsUnknownId` | 不存在的 id 返回 false；重复删除第二次失败 |
  | `reorderGoalMovesEntryAndRewritesDisplayOrder` | 下标语义、`QList::move`（非交换）、`display_order` 重写为 0..n-1、双向移动 |
  | `reorderGoalRejectsOutOfRangeIndexWithoutTouchingData` | 5 种越界组合返回 false 且数据不变 |
  | `reorderGoalWithSameIndexIsNoOp` | `from == to` 返回 true 且不发 `goalsChanged` |

- 验证：`QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests` → 基线 + 5 全部通过。

## Done criteria

全部必须成立：

- [ ] `QT_QPA_PLATFORM=offscreen /tmp/pt-004/GoalServiceTests` → `Totals: <基线+5> passed, 0 failed`
- [ ] `cd /tmp/pt-004 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` → `100% tests passed ... out of 12`
- [ ] `grep -c "void GoalServiceTests::reorderGoal\|void GoalServiceTests::deleteGoal" tests/GoalServiceTests.cpp` → 5
- [ ] `git status --porcelain` 中本计划新增的改动**只涉及** `tests/GoalServiceTests.cpp`
      （`src/services/GoalService.cpp` 必须**未被修改**）
- [ ] `plans/README.md` 中 004 的状态行已更新

## STOP conditions

出现以下任一情况，停下来报告，不要自行发挥：

- Drift check 的 `grep` 输出与 "Current state" 第二段摘录不一致。
- 基线用例数既不是 15 也不是 17，或修改前就有用例失败。
- 任一新用例暴露出 `deleteGoal` / `reorderGoal` 的**真实缺陷**（而不是用例写错）——
  **报告，不要修被测代码**。判断依据：如果实现的行为与本计划 "Current state" 里逐条列出的
  6 条关键语义不符，那是缺陷；如果只是本计划的断言写得太严，那是用例问题，可以调整用例。
  拿不准就报告。
- `reorderGoalWithSameIndexIsNoOp` 里 `goalsChanged` 的计数不是 0 ——
  可能是 `addGoal` 也发了这个信号导致计数被污染；此时把 `QSignalSpy` 的构造挪到
  所有 `addGoal` 之后（用例里已经这样写了）。若挪了仍不为 0，说明 `reorderGoal` 的
  短路分支没有生效，报告。
- 找不到可用的 Qt 安装路径。

## Maintenance notes

- **未来交互点**：设计方案的阶段 3 会给目标列表加拖拽排序。QML 的 `ListView` 拖拽拿到的是
  **视图下标**，而 `reorderGoal` 要的也是**列表下标**——两者只有在列表没有做任何筛选
  （例如按「进行中 / 已达成」过滤）时才一致。**一旦列表支持筛选，直接把视图下标传给
  `reorderGoal` 就是错的**，必须先映射回完整列表的下标，或者把接口改成按目标 id 排序。
  这是本计划的测试**没有**覆盖的风险，写界面时要特别注意。
- **评审重点**：
  1. 用例只读被测代码，`src/services/GoalService.cpp` 的 diff 必须为空；
  2. `reorderGoalMovesEntryAndRewritesDisplayOrder` 断言的是「移动+顺移」而不是「交换」——
     这两者在只有两个元素时结果相同，所以用例特意用了三个元素；
  3. `deleteGoalRemovesItAndLeavesOtherProgressIntact` 里对另一个目标进度的断言不是凑数，
     它守的是「进度不落库、每次现算」这个核心设计前提。
- **本计划显式推迟的事项**：
  - `deleteGoal` / `reorderGoal` 的 SQL 失败分支（`query.exec()` 返回 false、事务回滚）
    没有测试——需要注入 SQL 错误才能构造，成本高于收益。若以后给 `GoalService` 加了
    错误注入钩子（可参考 plans/001 给 `BackupService` 加的受控友元开关），应当补上。
  - `reorderGoal` 在目标数量很大时是整表重写，性能没有测试。目标数量是个位数量级，
    当前无需关心。
