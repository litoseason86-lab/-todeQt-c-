# 任务管理补洞第一部分：数据层 + 未完成结转 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** schema v4 给 tasks 加 routine_id 血缘列；TaskManager 三个新接口（updateTask / getOverdueUncompletedTasks / moveTasksToToday）；今日页结转横幅一键把逾期未完成任务移到今天。

**Architecture:** 迁移沿用 v2/v3 模式（user_version + 事务 + 改数据前备份）；`materializeToday` 写入血缘，结转查询以 `routine_id IS NULL` 排除例行任务；横幅是 TodayTaskView 内部区块（非全局组件），忽略状态存 AppSettings。

**Tech Stack:** Qt 6.9 / C++17 / SQLite / Qt Quick(QML) / Qt Test / CMake。

**对应规格:** `docs/superpowers/specs/2026-07-06-task-management-gaps-design.md` 的「结构性决策」「数据层」「结转横幅」。

## Global Constraints

- git 提交说明用**中文**；非显然逻辑加**中文注释**（解释为什么/边界）。
- 不改 `build/`；每个任务改完跑构建与相关测试再提交。
- C++ 测试：`cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`；单文件 QML：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<file>.qml 2>/dev/null | grep -E "FAIL|Totals"`；qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <file>`。
- 开始前从 `main` 创建并检出分支 `task-management-gaps`（若已存在则直接检出）。
- **QML 测试纪律**：绝不断言 `something.visible === true`；断言驱动它的源头属性。整套 QML 存在既有偶发失败（`tst_ui_optimization.qml`），判定以单文件连跑 2 次全绿为准。
- 时长/文案：裸中文，不加 `qsTr()`。
- `ServiceTests` 夹具：每个用例 `init()` 用临时目录重建数据库（`DatabaseManager::instance()->initialize(m_tempDir->filePath("test.sqlite"))`），测试间天然隔离；`insertTaskRow(title, date, category, completed, createdAt)` 是文件内既有辅助函数。

---

### Task 1: schema v4 —— tasks.routine_id 列 + 存量回填

**Files:**

- Modify: `src/services/DatabaseManager.h`（私有函数声明加一行）
- Modify: `src/services/DatabaseManager.cpp`（createTables 分发 + migrateToVersion4 实现）
- Test: `tests/ServiceTests.cpp`

**Interfaces:**

- Produces: tasks 表新增列 `routine_id INTEGER REFERENCES routines(id)`（默认 NULL）；`user_version` 升到 4；迁移时按标题回填存量。后续任务依赖该列做插入与过滤。

- [x] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` 的 `private slots:` 区加：

```cpp
    void freshDatabaseHasRoutineIdColumn();
    void migrationV4BackfillsRoutineIdAndIsIdempotent();
```

实现区加：

```cpp
void ServiceTests::freshDatabaseHasRoutineIdColumn()
{
    // 新库直建路径也必须带 routine_id 列，SELECT 不报错即证明列存在。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks LIMIT 1")));
}

void ServiceTests::migrationV4BackfillsRoutineIdAndIsIdempotent()
{
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1));
    const QDate yesterday = QDate::currentDate().addDays(-1);
    const int routineLikeId = insertTaskRow(QStringLiteral("背单词"), yesterday);
    const int plainId = insertTaskRow(QStringLiteral("普通任务"), yesterday);
    QVERIFY(routineLikeId > 0);
    QVERIFY(plainId > 0);

    // 把版本拨回 3 重跑建表流程，模拟老库升级路径：
    // 列已存在（走幂等分支）+ 回填逻辑对存量行生效。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 3")));
    QVERIFY(DatabaseManager::instance()->createTables());

    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks WHERE id = %1").arg(routineLikeId)));
    QVERIFY(query.next());
    QVERIFY(!query.value(0).isNull()); // 标题命中例行 → 回填

    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks WHERE id = %1").arg(plainId)));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull()); // 普通任务保持 NULL

    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 4); // 版本已推进
}
```

- [x] **Step 2: 运行确认失败**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure 2>&1 | tail -15`
Expected: 两个新用例 FAIL（`no such column: routine_id`）。

- [x] **Step 3: 写实现**

`src/services/DatabaseManager.h`：`migrateToVersion3();` 声明之后加：

```cpp
    // v4 给 tasks 增加 routine_id 血缘列，结转功能靠它排除例行任务。
    bool migrateToVersion4();
```

`src/services/DatabaseManager.cpp`：

`createTables()` 里 v3 迁移块之后（建索引之前）加：

```cpp
    // 版本 4 给 tasks 增加 routine_id 血缘列；列缺失时无论版本号都要补（防御半迁移状态）。
    if (getDatabaseVersion() < 4
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("routine_id"))) {
        if (!migrateToVersion4()) {
            return false;
        }
    }
```

`migrateToVersion3()` 实现之后加：

```cpp
bool DatabaseManager::migrateToVersion4()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // v4 会回填改写既有 tasks 行，沿用 v2 的迁移前备份策略。
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }

    if (!m_db.transaction()) {
        qWarning() << "Failed to start database migration transaction:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("routine_id"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE tasks ADD COLUMN routine_id INTEGER REFERENCES routines(id)"))) {
            qWarning() << "Failed to add routine_id column:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    // 尽力回填：标题与某条例行完全一致的存量任务视为该例行生成。
    // 误标同名普通任务的代价只是不参与结转；漏标会在结转横幅出现一次，由用户处置。
    if (!query.exec(QStringLiteral(
            "UPDATE tasks SET routine_id = ("
            "  SELECT r.id FROM routines r WHERE r.title = tasks.title"
            ") WHERE routine_id IS NULL AND EXISTS ("
            "  SELECT 1 FROM routines r WHERE r.title = tasks.title)"))) {
        qWarning() << "Failed to backfill routine_id:" << query.lastError().text();
        m_db.rollback();
        return false;
    }

    if (!setDatabaseVersion(4)) {
        m_db.rollback();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit database migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 4";
    return true;
}
```

- [x] **Step 4: 运行确认通过（含全量 C++ 回归）**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure 2>&1 | tail -5`
Expected: PASS（既有迁移/任务用例不受影响）。

- [x] **Step 5: 提交**

```bash
git add src/services/DatabaseManager.h src/services/DatabaseManager.cpp tests/ServiceTests.cpp
git commit -m "schema v4 新增 tasks.routine_id 血缘列并回填存量"
```

---

### Task 2: materializeToday 写入 routine_id

**Files:**

- Modify: `src/services/RoutineManager.cpp`（INSERT 语句一处）
- Test: `tests/ServiceTests.cpp`

**Interfaces:**

- Consumes: Task 1 的 routine_id 列
- Produces: 例行生成的任务行 `routine_id` = 来源例行 id（后续结转查询据此排除）

- [x] **Step 1: 写失败测试**

`private slots:` 区加：

```cpp
    void materializeTodayStampsRoutineId();
```

实现区加：

```cpp
void ServiceTests::materializeTodayStampsRoutineId()
{
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("晨间背单词"), -1));
    QCOMPARE(RoutineManager::instance()->materializeToday(), 1);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT t.routine_id FROM tasks t JOIN routines r ON r.id = t.routine_id "
        "WHERE t.title = '晨间背单词'")));
    QVERIFY(query.next());
    QVERIFY(query.value(0).toInt() > 0);
}
```

- [x] **Step 2: 运行确认失败**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure 2>&1 | tail -10`
Expected: 新用例 FAIL（routine_id 为 NULL，JOIN 无结果）。

- [x] **Step 3: 写实现**

`src/services/RoutineManager.cpp` 的 `materializeToday()` 中 INSERT 改为（在 `insertTask.prepare` 与绑定处）：

```cpp
        QSqlQuery insertTask(db);
        insertTask.prepare(QStringLiteral(
            "INSERT INTO tasks (title, category, category_id, date, completed, routine_id) "
            "VALUES (:title, COALESCE((SELECT name FROM categories WHERE id = :categoryId), ''), :categoryId, :date, 0, :routineId)"));
        insertTask.bindValue(QStringLiteral(":title"), routine.title);
        insertTask.bindValue(QStringLiteral(":categoryId"), routine.categoryId);
        insertTask.bindValue(QStringLiteral(":date"), today);
        // 血缘列：结转功能靠它区分"例行生成"与"手工任务"，例行残留不参与结转。
        insertTask.bindValue(QStringLiteral(":routineId"), routine.id);
```

（其余行保持不变，只是 SQL 多一列、多一个绑定。）

- [x] **Step 4: 运行确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure 2>&1 | tail -5`
Expected: PASS（既有例行生成用例不受影响——它们不检查 routine_id）。

- [x] **Step 5: 提交**

```bash
git add src/services/RoutineManager.cpp tests/ServiceTests.cpp
git commit -m "例行生成任务写入 routine_id 血缘"
```

---

### Task 3: TaskManager::updateTask

**Files:**

- Modify: `src/services/TaskManager.h`
- Modify: `src/services/TaskManager.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**

- Produces: `Q_INVOKABLE bool updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue)` —— 校验规则与 addTask 一致（trim 非空、normalizeDate、categoryId>0 时校验存在并同步 category 文本列）；成功发 `tasksChanged`。QML 侧日期可传 `"yyyy-MM-dd"` 字符串。

- [x] **Step 1: 写失败测试**

`private slots:` 区加：

```cpp
    void updateTaskChangesTitleCategoryAndDate();
    void updateTaskRejectsBlankTitleAndInvalidId();
```

实现区加：

```cpp
void ServiceTests::updateTaskChangesTitleCategoryAndDate()
{
    TaskManager* manager = TaskManager::instance();
    const QDate today = QDate::currentDate();
    const int taskId = insertTaskRow(QStringLiteral("原标题"), today);
    QVERIFY(taskId > 0);

    // addCategory 直接返回新科目 id（既有接口，返回 int，失败为 -1）。
    const int categoryId = CategoryManager::instance()->addCategory(
        QStringLiteral("数学编辑"), QStringLiteral("#d4a574"));
    QVERIFY(categoryId > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    const QDate tomorrow = today.addDays(1);
    QVERIFY(manager->updateTask(taskId, QStringLiteral("  新标题  "),
                                categoryId, tomorrow.toString(Qt::ISODate)));
    QCOMPARE(changedSpy.count(), 1);

    const QVariantList tasks = manager->getTasksByDate(tomorrow);
    QCOMPARE(tasks.size(), 1);
    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("新标题"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), categoryId);
}

void ServiceTests::updateTaskRejectsBlankTitleAndInvalidId()
{
    TaskManager* manager = TaskManager::instance();
    const int taskId = insertTaskRow(QStringLiteral("保持不变"), QDate::currentDate());
    QVERIFY(taskId > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    QVERIFY(!manager->updateTask(taskId, QStringLiteral("   "), -1,
                                 QDate::currentDate().toString(Qt::ISODate)));
    QVERIFY(!manager->updateTask(-5, QStringLiteral("有效标题"), -1,
                                 QDate::currentDate().toString(Qt::ISODate)));
    QVERIFY(!manager->updateTask(999999, QStringLiteral("有效标题"), -1,
                                 QDate::currentDate().toString(Qt::ISODate)));
    QCOMPARE(changedSpy.count(), 0);

    const QVariantList tasks = manager->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("保持不变"));
}
```

（`CategoryManager::addCategory(name, color)` 与 `getCategories()` 为既有接口，其他用例已这样使用；若签名有出入，以 `src/services/CategoryManager.h` 为准调整取 id 方式。）

- [x] **Step 2: 运行确认编译失败**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译错误（`updateTask` 不是成员）。

- [x] **Step 3: 写实现**

`src/services/TaskManager.h`：`setTaskCompleted` 声明之后加：

```cpp
    // 编辑任务三字段；校验规则与 addTask 对齐，行内改标题时其余字段传原值即可。
    Q_INVOKABLE bool updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue);
```

`src/services/TaskManager.cpp`：`setTaskCompleted` 实现之后加（`normalizeDate`/`isValidTaskId`/`bindCategoryTextFromId` 均为文件内既有辅助，用法与 addTask 相同）：

```cpp
bool TaskManager::updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to update task: invalid task id" << taskId;
        return false;
    }

    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to update task: title is empty after trimming";
        return false;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to update task: invalid date";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update task: database is not open";
        return false;
    }

    QString categoryName;
    QVariant categoryIdValue;
    if (categoryId > 0) {
        QSqlQuery categoryQuery(db);
        if (!bindCategoryTextFromId(categoryQuery, categoryId, &categoryName)) {
            return false;
        }
        categoryIdValue = categoryId;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE tasks SET title = :title, category = :category, "
        "category_id = :categoryId, date = :date WHERE id = :id"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":category"), categoryName);
    query.bindValue(QStringLiteral(":categoryId"), categoryIdValue);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to update task:" << query.lastError().text();
        return false;
    }
    if (query.numRowsAffected() <= 0) {
        qWarning() << "Failed to update task: task not found" << taskId;
        return false;
    }

    emit tasksChanged();
    return true;
}
```

- [x] **Step 4: 运行确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure 2>&1 | tail -5`
Expected: PASS。

- [x] **Step 5: 提交**

```bash
git add src/services/TaskManager.h src/services/TaskManager.cpp tests/ServiceTests.cpp
git commit -m "TaskManager 新增 updateTask 编辑接口"
```

---

### Task 4: getOverdueUncompletedTasks + moveTasksToToday

**Files:**

- Modify: `src/services/TaskManager.h`
- Modify: `src/services/TaskManager.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**

- Produces:

  - `Q_INVOKABLE QVariantList getOverdueUncompletedTasks() const` —— `date < today AND completed = 0 AND routine_id IS NULL`，`date ASC, id ASC`，返回结构同 getTodayTasks
  - `Q_INVOKABLE bool moveTasksToToday(const QVariantList& taskIds)` —— 事务批量改 date；空列表返回 true；任一 id 无效或未命中整体回滚；成功发 `tasksChanged`

- [x] **Step 1: 写失败测试**

`private slots:` 区加：

```cpp
    void overdueQueryExcludesTodayCompletedAndRoutine();
    void moveTasksToTodayIsTransactional();
```

实现区加：

```cpp
void ServiceTests::overdueQueryExcludesTodayCompletedAndRoutine()
{
    TaskManager* manager = TaskManager::instance();
    const QDate today = QDate::currentDate();
    const QDate yesterday = today.addDays(-1);
    const QDate lastWeek = today.addDays(-6);

    const int oldPending = insertTaskRow(QStringLiteral("上周残留"), lastWeek);
    const int yesterdayPending = insertTaskRow(QStringLiteral("昨天残留"), yesterday);
    insertTaskRow(QStringLiteral("昨天已完成"), yesterday, QString(), true);
    insertTaskRow(QStringLiteral("今天的任务"), today);

    // 例行残留：真实建例行拿 id，再把任务行标上血缘。
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("结转排除例行"), -1));
    const int routineLeftover = insertTaskRow(QStringLiteral("结转排除例行"), yesterday);
    QSqlQuery mark(DatabaseManager::instance()->database());
    QVERIFY(mark.exec(QStringLiteral(
        "UPDATE tasks SET routine_id = (SELECT id FROM routines WHERE title = '结转排除例行') "
        "WHERE id = %1").arg(routineLeftover)));

    const QVariantList overdue = manager->getOverdueUncompletedTasks();
    QCOMPARE(overdue.size(), 2);
    // date ASC：上周的排前面。
    QCOMPARE(overdue.at(0).toMap().value(QStringLiteral("id")).toInt(), oldPending);
    QCOMPARE(overdue.at(1).toMap().value(QStringLiteral("id")).toInt(), yesterdayPending);
}

void ServiceTests::moveTasksToTodayIsTransactional()
{
    TaskManager* manager = TaskManager::instance();
    const QDate yesterday = QDate::currentDate().addDays(-1);
    const int first = insertTaskRow(QStringLiteral("结转一"), yesterday);
    const int second = insertTaskRow(QStringLiteral("结转二"), yesterday);

    // 含无效 id：整体回滚，两条任务日期都不变。
    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    QVERIFY(!manager->moveTasksToToday(QVariantList{first, 999999}));
    QCOMPARE(changedSpy.count(), 0);
    QCOMPARE(manager->getTasksByDate(yesterday).size(), 2);

    // 全部有效：一次移完，今日可见，逾期清零。
    QVERIFY(manager->moveTasksToToday(QVariantList{first, second}));
    QCOMPARE(changedSpy.count(), 1);
    QCOMPARE(manager->getTasksByDate(yesterday).size(), 0);
    QCOMPARE(manager->getTodayTasks().size(), 2);
    QCOMPARE(manager->getOverdueUncompletedTasks().size(), 0);

    // 空列表是合法的无操作。
    QVERIFY(manager->moveTasksToToday(QVariantList{}));
}
```

- [x] **Step 2: 运行确认编译失败**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译错误（两个成员不存在）。

- [x] **Step 3: 写实现**

`src/services/TaskManager.h`：`getMonthTasks` 声明之后加：

```cpp
    // 结转：查所有逾期未完成的手工任务（例行残留靠 routine_id 排除，避免与当天新生成的撞车）。
    Q_INVOKABLE QVariantList getOverdueUncompletedTasks() const;
    Q_INVOKABLE bool moveTasksToToday(const QVariantList& taskIds);
```

`src/services/TaskManager.cpp`：`getMonthTasks` 实现之后加：

```cpp
QVariantList TaskManager::getOverdueUncompletedTasks() const
{
    QVariantList tasks;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get overdue tasks: database is not open";
        return tasks;
    }

    QSqlQuery query(db);
    query.prepare(taskSelectSql() + QStringLiteral(
        "WHERE t.date < :today AND t.completed = 0 AND t.routine_id IS NULL "
        "ORDER BY t.date ASC, t.id ASC"));
    query.bindValue(QStringLiteral(":today"), QDate::currentDate().toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get overdue tasks:" << query.lastError().text();
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }
    return tasks;
}

bool TaskManager::moveTasksToToday(const QVariantList& taskIds)
{
    if (taskIds.isEmpty()) {
        return true; // 没有要移的任务不算失败，横幅一键路径不用特判。
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to move tasks: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start move tasks transaction:" << db.lastError().text();
        return false;
    }

    const QString today = QDate::currentDate().toString(Qt::ISODate);
    for (const QVariant& idValue : taskIds) {
        const int taskId = idValue.toInt();
        if (!isValidTaskId(taskId)) {
            qWarning() << "Failed to move tasks: invalid task id" << idValue;
            db.rollback();
            return false;
        }

        QSqlQuery query(db);
        query.prepare(QStringLiteral("UPDATE tasks SET date = :today WHERE id = :id"));
        query.bindValue(QStringLiteral(":today"), today);
        query.bindValue(QStringLiteral(":id"), taskId);

        // 任一条失败整体回滚：结转是"一键全部"语义，部分成功会让横幅计数和列表对不上。
        if (!query.exec() || query.numRowsAffected() <= 0) {
            qWarning() << "Failed to move task" << taskId << ":" << query.lastError().text();
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit move tasks:" << db.lastError().text();
        db.rollback();
        return false;
    }

    emit tasksChanged();
    return true;
}
```

- [x] **Step 4: 运行确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure 2>&1 | tail -5`
Expected: PASS。

- [x] **Step 5: 提交**

```bash
git add src/services/TaskManager.h src/services/TaskManager.cpp tests/ServiceTests.cpp
git commit -m "TaskManager 新增逾期查询与批量结转接口"
```

---

### Task 5: AppSettings.rolloverIgnoredDate

**Files:**

- Modify: `src/services/AppSettings.h`
- Modify: `src/services/AppSettings.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**

- Produces: `Q_PROPERTY QString rolloverIgnoredDate`（默认 ""，键 `rollover/lastIgnoredDate`，NOTIFY `rolloverIgnoredDateChanged`）——横幅"忽略"按当天 ISO 日期记录。

- [x] **Step 1: 写失败测试**

`private slots:` 区加：

```cpp
    void appSettingsRolloverIgnoredDateRoundTrip();
```

实现区加：

```cpp
void ServiceTests::appSettingsRolloverIgnoredDateRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.rolloverIgnoredDate(), QString());
        QSignalSpy spy(&settings, &AppSettings::rolloverIgnoredDateChanged);
        settings.setRolloverIgnoredDate(QStringLiteral("2026-07-06"));
        QCOMPARE(spy.count(), 1);
        settings.setRolloverIgnoredDate(QStringLiteral("2026-07-06")); // 同值不发信号
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.rolloverIgnoredDate(), QStringLiteral("2026-07-06"));
}
```

- [x] **Step 2: 运行确认编译失败**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译错误（成员不存在）。

- [x] **Step 3: 写实现**

`src/services/AppSettings.h`：Q_PROPERTY 区加：

```cpp
    Q_PROPERTY(QString rolloverIgnoredDate READ rolloverIgnoredDate WRITE setRolloverIgnoredDate NOTIFY rolloverIgnoredDateChanged)
```

public 区加 `QString rolloverIgnoredDate() const; void setRolloverIgnoredDate(const QString& date);`，signals 区加 `void rolloverIgnoredDateChanged();`。

`src/services/AppSettings.cpp`：匿名命名空间加键，文件尾加实现（与既有 setter 同模式：同值早退、setValue+sync、发信号）：

```cpp
const auto kRolloverIgnoredDateKey = QStringLiteral("rollover/lastIgnoredDate");
```

```cpp
QString AppSettings::rolloverIgnoredDate() const
{
    return m_settings->value(kRolloverIgnoredDateKey, QString()).toString();
}

void AppSettings::setRolloverIgnoredDate(const QString& date)
{
    if (rolloverIgnoredDate() == date) {
        return;
    }
    m_settings->setValue(kRolloverIgnoredDateKey, date);
    m_settings->sync();
    emit rolloverIgnoredDateChanged();
}
```

- [x] **Step 4: 运行确认通过 + 提交**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure 2>&1 | tail -5`
Expected: PASS。

```bash
git add src/services/AppSettings.h src/services/AppSettings.cpp tests/ServiceTests.cpp
git commit -m "AppSettings 新增结转忽略日期键"
```

---

### Task 6: 今日页结转横幅（QML）

**Files:**

- Modify: `qml/views/TodayTaskView.qml`
- Modify: `qml/MainWindow.qml`（TodayTaskView 实例注入 settingsRef）
- Create: `tests/qml/tst_today_rollover.qml`

**Interfaces:**

- Consumes: Task 4 的 `getOverdueUncompletedTasks()`/`moveTasksToToday(ids)`、Task 5 的 `rolloverIgnoredDate`
- Produces:

  - TodayTaskView `property var settingsRef: null`、`property var overdueTasks: []`、`readonly` 驱动属性 `property bool rolloverBannerActive: false`
  - 函数 `moveOverdueToToday()`、`ignoreOverdueForToday()`、`todayIsoDate()`
  - objectName：横幅 `rolloverBanner`、文本 `rolloverBannerText`、按钮 `rolloverMoveButton`/`rolloverIgnoreButton`

- [x] **Step 1: 写失败测试**

新建 `tests/qml/tst_today_rollover.qml`：

```qml
import QtQuick
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "TodayRollover"
    when: windowShown
    width: 860
    height: 620

    QtObject {
        id: taskManager

        signal tasksChanged

        property var todayTasksData: []
        property var overdueData: []
        property var movedIds: []
        property int moveCalls: 0

        function getTodayTasks() { return todayTasksData; }
        function getOverdueUncompletedTasks() { return overdueData; }
        function moveTasksToToday(ids) {
            moveCalls += 1;
            movedIds = ids;
            overdueData = [];
            return true;
        }
        function getTasksByDate(date) { return []; }
        function getWeekTasks(weekStart) { return []; }
        function getMonthTasks(year, month) { return []; }
        function addTask(title, date, categoryId) { return true; }
        function setTaskCompleted(id, completed) { return true; }
        function deleteTask(id) { return true; }
        function updateTask(id, title, categoryId, date) { return true; }
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 };
        }
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)

        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int mode: 0
        property int phase: 0
    }

    QtObject {
        id: settingsMock

        property string rolloverIgnoredDate: ""
    }

    TodayTaskView {
        id: view
        width: testCase.width
        height: testCase.height
        settingsRef: settingsMock
    }

    function init() {
        taskManager.todayTasksData = [];
        taskManager.overdueData = [];
        taskManager.movedIds = [];
        taskManager.moveCalls = 0;
        settingsMock.rolloverIgnoredDate = "";
        view.refresh();
        wait(20);
    }

    function makeOverdue(id, title) {
        return { id: id, title: title, completed: false, date: "2026-07-01", categoryId: -1 };
    }

    function test_bannerActiveWhenOverdueExists() {
        compare(view.rolloverBannerActive, false);

        taskManager.overdueData = [makeOverdue(11, "上周残留"), makeOverdue(12, "昨天残留")];
        view.refresh();
        wait(20);

        compare(view.rolloverBannerActive, true);
        const text = findChild(view, "rolloverBannerText");
        verify(text);
        verify(text.text.indexOf("2") !== -1);
    }

    function test_moveAllSendsIdsAndHidesBanner() {
        taskManager.overdueData = [makeOverdue(11, "上周残留"), makeOverdue(12, "昨天残留")];
        view.refresh();
        wait(20);

        view.moveOverdueToToday();
        wait(20);

        compare(taskManager.moveCalls, 1);
        compare(taskManager.movedIds.length, 2);
        compare(Number(taskManager.movedIds[0]), 11);
        compare(Number(taskManager.movedIds[1]), 12);
        compare(view.rolloverBannerActive, false);
    }

    function test_ignoreHidesForTodayAndPersistsDate() {
        taskManager.overdueData = [makeOverdue(11, "上周残留")];
        view.refresh();
        wait(20);
        compare(view.rolloverBannerActive, true);

        view.ignoreOverdueForToday();
        wait(20);

        compare(settingsMock.rolloverIgnoredDate, view.todayIsoDate());
        compare(view.rolloverBannerActive, false);

        // 再刷新也不再出现（当天已忽略）。
        view.refresh();
        wait(20);
        compare(view.rolloverBannerActive, false);
    }
}
```

- [x] **Step 2: 运行确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（`rolloverBannerActive`/`settingsRef` 不存在）。

- [x] **Step 3: 写实现**

`qml/views/TodayTaskView.qml`：

属性区（`countdownServiceRef` 之后）加：

```qml
    property var settingsRef: null
    property var overdueTasks: []
    property bool rolloverBannerActive: false
```

函数区加（`refresh()` 之前）：

```qml
    function todayIsoDate() {
        return Qt.formatDate(new Date(), "yyyy-MM-dd");
    }

    function loadOverdueTasks() {
        // 旧测试桩没有这个接口；缺失时静默当作无逾期，避免横幅逻辑拖垮整页。
        if (!taskManager.getOverdueUncompletedTasks) {
            root.overdueTasks = [];
            root.rolloverBannerActive = false;
            return;
        }
        root.overdueTasks = taskManager.getOverdueUncompletedTasks();
        var ignoredToday = root.settingsRef
                && root.settingsRef.rolloverIgnoredDate === root.todayIsoDate();
        root.rolloverBannerActive = root.overdueTasks.length > 0 && !ignoredToday;
    }

    function moveOverdueToToday() {
        var ids = [];
        for (var i = 0; i < root.overdueTasks.length; i++) {
            ids.push(Number(root.overdueTasks[i].id));
        }
        if (taskManager.moveTasksToToday(ids)) {
            root.refresh();
        } else {
            root.loadError = "结转失败，请重试";
        }
    }

    function ignoreOverdueForToday() {
        if (root.settingsRef) {
            root.settingsRef.rolloverIgnoredDate = root.todayIsoDate();
        }
        root.rolloverBannerActive = false;
    }
```

`refresh()` 里 `loadTasks();` 之前加一行 `loadOverdueTasks();`。

布局：`CountdownBanner` 与统计卡 RowLayout 之间加横幅（暖纸卡片语言，参照统计卡样式）：

```qml
        Rectangle {
            objectName: "rolloverBanner"
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            visible: root.rolloverBannerActive
            radius: Theme.radiusLg
            color: Theme.accentSoft
            border.color: Theme.accent
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.space16
                anchors.rightMargin: Theme.space12
                spacing: Theme.space12

                Text {
                    objectName: "rolloverBannerText"
                    Layout.fillWidth: true
                    text: "之前还有 " + root.overdueTasks.length + " 个未完成任务"
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    color: Theme.inkStrong
                    elide: Text.ElideRight
                }

                Button {
                    id: rolloverMoveButton
                    objectName: "rolloverMoveButton"
                    text: "全部移到今天"
                    implicitHeight: 34
                    onClicked: root.moveOverdueToToday()

                    background: Rectangle {
                        color: rolloverMoveButton.hovered ? Theme.accentStrong : Theme.accent
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: rolloverMoveButton.text
                        textFormat: Text.PlainText
                        color: Theme.surface
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: rolloverIgnoreButton
                    objectName: "rolloverIgnoreButton"
                    text: "忽略"
                    implicitHeight: 34
                    onClicked: root.ignoreOverdueForToday()

                    background: Rectangle {
                        color: rolloverIgnoreButton.hovered ? Theme.surfaceSunken : "transparent"
                        border.color: Theme.border
                        border.width: 1
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: rolloverIgnoreButton.text
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
```

`qml/MainWindow.qml` 的 TodayTaskView 实例加一行：

```qml
                    settingsRef: root.appSettingsRef
```

- [x] **Step 4: qmllint + 测试确认通过（含既有回归）**

Run:

```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/TodayTaskView.qml qml/MainWindow.qml
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml 2>/dev/null | grep -E "FAIL|Totals"
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml 2>/dev/null | grep -E "Totals"
```

Expected: lint 无输出；rollover 全 PASS 连跑 2 次；`tst_ui_optimization` 与既有偶发水平一致（其 taskManager 桩缺新接口，靠 `loadOverdueTasks` 的守卫不崩——若出现 `getOverdueUncompletedTasks is not a function` 之类新失败必须修复守卫）。

- [x] **Step 5: 全量构建 + 提交**

```bash
cmake --build build && ctest --test-dir build --output-on-failure
git add qml/views/TodayTaskView.qml qml/MainWindow.qml tests/qml/tst_today_rollover.qml
git commit -m "今日页新增逾期任务结转横幅"
```

（QML 整套若仅既有偶发失败，按惯例以单文件复跑判定。）
