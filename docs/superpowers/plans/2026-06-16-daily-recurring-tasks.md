# 每日例行任务（自动出现）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户设一次「每日例行」任务后，每天自动在当天任务清单生成对应的真实任务行，免去每天手动重复录入。

**Architecture:** 新增 `routines` 表（DB 迁移 v3）+ `RoutineManager` 单例服务。`materializeToday()` 对每个启用且当天未生成的例行项插入一条当天任务行（幂等、删不复活、不补历史）。侧栏「每日例行」入口打开 `RoutineDialog` 管理；启动时与今日页刷新时触发生成。生成的就是普通任务行，完成/统计/专注全自动兼容。

**Tech Stack:** Qt 6.9 / C++17 / Qt Quick(QML) / SQLite / CMake / Qt Test（C++ ServiceTests + qmltestrunner）。

## Global Constraints

- 所有 git 提交说明用**中文**，清楚描述本次完成的功能（AGENTS.md）。
- 为非显然逻辑加**中文注释**，解释「为什么」与边界；不给显而易见处加噪音注释（AGENTS.md）。
- 保持分层：`src/services` 业务、`qml` 界面、`tests` 测试，职责不混（AGENTS.md）。
- **不改 `build/` 生成物。** 改完跑构建与测试再报告。
- 配置命令：`cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`
- 构建：`cmake --build build`　全部测试：`ctest --test-dir build --output-on-failure`
- 仅 C++ 服务测试：`ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
- 仅 QML 测试：`ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
- qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <file>`（`pyside6-qmllint` 未安装，用 Qt 自带的）
- 当前分支：`daily-recurring-tasks`（已检出，勿切换）。

---

## Task 1：数据库迁移 v3 —— routines 表

**Files:**
- Modify: `src/services/DatabaseManager.h`（加两个私有方法声明）
- Modify: `src/services/DatabaseManager.cpp`（建表 + 迁移 + initialize 调用 + 索引）
- Test: `tests/ServiceTests.cpp`（新增一个用例）

**Interfaces:**
- Produces: `routines` 表，列为 `id, title, category_id, active, display_order, last_generated_date, created_at`；数据库 user_version ≥ 3。

- [ ] **Step 1：写失败测试**

在 `tests/ServiceTests.cpp` 的 `private slots:` 区（约第 266 行起）声明：
```cpp
    void routinesTableExistsAfterInitialize();
```
在文件末尾的实现区（其它 `void ServiceTests::xxx()` 旁）加入：
```cpp
void ServiceTests::routinesTableExistsAfterInitialize()
{
    // init() 已用全新临时库初始化，迁移应已建好 routines 表。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY2(query.exec(QStringLiteral(
        "SELECT id, title, category_id, active, display_order, last_generated_date, created_at FROM routines")),
        qPrintable(query.lastError().text()));
}
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: `routinesTableExistsAfterInitialize` FAIL —— `no such table: routines`。

- [ ] **Step 3：在 DatabaseManager.h 声明私有方法**

在 `bool createCategoriesTable();`（约第 32 行）之后加：
```cpp
    bool migrateToVersion3();
    bool createRoutinesTable();
```

- [ ] **Step 4：在 DatabaseManager.cpp 实现建表与迁移**

在 `createCategoriesTable()` 实现之后，新增：
```cpp
bool DatabaseManager::createRoutinesTable()
{
    QSqlQuery query(m_db);
    const QString createRoutines = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS routines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            category_id INTEGER REFERENCES categories(id),
            active INTEGER NOT NULL DEFAULT 1,
            display_order INTEGER NOT NULL DEFAULT 0,
            last_generated_date TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    )SQL");
    return execSql(query, createRoutines, "Failed to create routines table:");
}

bool DatabaseManager::migrateToVersion3()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // v3 只新增一张表（非破坏性），且同一次初始化中 v2 迁移已做过备份，
    // 这里不再重复备份，避免同秒时间戳的备份文件命名冲突。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start database migration transaction:" << m_db.lastError().text();
        return false;
    }

    if (!createRoutinesTable() || !setDatabaseVersion(3)) {
        m_db.rollback();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit database migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 3";
    return true;
}
```

- [ ] **Step 5：在 initialize() 里接上 v3 迁移与索引**

在 `initialize()` 中、v2 迁移那段（`} else if (!createCategoriesTable() || !insertPresetCategories()) { return false; }`）之后、`const QStringList indexes = {` 之前，插入：
```cpp
    // 版本 3 引入每日例行表 routines（纯新增，向后兼容）。
    if (getDatabaseVersion() < 3 || !tableExists(QStringLiteral("routines"))) {
        if (!migrateToVersion3()) {
            return false;
        }
    }
```
并在 `indexes` 列表里追加一行：
```cpp
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_routines_active ON routines(active)"),
```

- [ ] **Step 6：运行测试，确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: 全部 PASS（含 `routinesTableExistsAfterInitialize`，且 `migrationCreatesDatabaseBackup` 等旧用例不回归）。

- [ ] **Step 7：提交**

```bash
git add src/services/DatabaseManager.h src/services/DatabaseManager.cpp tests/ServiceTests.cpp
git commit -m "新增 routines 表与数据库 v3 迁移"
```

---

## Task 2：RoutineManager —— 例行项增删改查

**Files:**
- Create: `src/services/RoutineManager.h`
- Create: `src/services/RoutineManager.cpp`
- Modify: `CMakeLists.txt`（加入 app 与测试目标的源）
- Test: `tests/ServiceTests.cpp`（新增用例）

**Interfaces:**
- Produces:
  - `static RoutineManager* instance();`
  - `Q_INVOKABLE bool addRoutine(const QString& title, int categoryId);`（categoryId ≤ 0 表示不设科目）
  - `Q_INVOKABLE bool updateRoutine(int id, const QString& title, int categoryId);`
  - `Q_INVOKABLE bool deleteRoutine(int id);`
  - `Q_INVOKABLE bool setRoutineActive(int id, bool active);`
  - `Q_INVOKABLE QVariantList getRoutines() const;`（每项 map：`id,title,categoryId,categoryName,categoryColor,active,displayOrder`）
  - `Q_INVOKABLE int materializeToday();`（Task 3 实现，本任务先留桩返回 0）
  - `signals: void routinesChanged();`

- [ ] **Step 1：写失败测试**

在 `tests/ServiceTests.cpp` 顶部包含区加：
```cpp
#include "../src/services/RoutineManager.h"
```
在 `private slots:` 区声明：
```cpp
    void routineCrudAddsGetsUpdatesDeletes();
```
实现区加入：
```cpp
void ServiceTests::routineCrudAddsGetsUpdatesDeletes()
{
    RoutineManager* manager = RoutineManager::instance();
    QSignalSpy spy(manager, &RoutineManager::routinesChanged);

    // 空标题被拒
    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: title is empty");
    QVERIFY(!manager->addRoutine(QStringLiteral("   "), -1));

    // 正常新增（带前后空格，应被 trim）
    QVERIFY(manager->addRoutine(QStringLiteral("  背单词 list  "), -1));
    QCOMPARE(spy.count(), 1);

    QVariantList routines = manager->getRoutines();
    QCOMPARE(routines.size(), 1);
    QVariantMap r = routines.first().toMap();
    QCOMPARE(r.value(QStringLiteral("title")).toString(), QStringLiteral("背单词 list"));
    QCOMPARE(r.value(QStringLiteral("active")).toBool(), true);
    const int id = r.value(QStringLiteral("id")).toInt();
    QVERIFY(id > 0);

    // 更新标题
    QVERIFY(manager->updateRoutine(id, QStringLiteral("背单词 list 2"), -1));
    QCOMPARE(manager->getRoutines().first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("背单词 list 2"));

    // 停用
    QVERIFY(manager->setRoutineActive(id, false));
    QCOMPARE(manager->getRoutines().first().toMap().value(QStringLiteral("active")).toBool(), false);

    // 删除
    QVERIFY(manager->deleteRoutine(id));
    QVERIFY(manager->getRoutines().isEmpty());
}
```

- [ ] **Step 2：创建 RoutineManager.h**

```cpp
#ifndef ROUTINEMANAGER_H
#define ROUTINEMANAGER_H

#include <QObject>
#include <QString>
#include <QVariantList>

class RoutineManager : public QObject
{
    Q_OBJECT

public:
    static RoutineManager* instance();

    // 例行项的增删改查，供「每日例行」管理弹窗使用。categoryId <= 0 表示不设科目。
    Q_INVOKABLE bool addRoutine(const QString& title, int categoryId);
    Q_INVOKABLE bool updateRoutine(int id, const QString& title, int categoryId);
    Q_INVOKABLE bool deleteRoutine(int id);
    Q_INVOKABLE bool setRoutineActive(int id, bool active);
    Q_INVOKABLE QVariantList getRoutines() const;

    // 生成「今天」的例行任务行：幂等、删不复活、不补历史（Task 3 实现）。
    Q_INVOKABLE int materializeToday();

signals:
    void routinesChanged();

private:
    explicit RoutineManager(QObject* parent = nullptr);
};

#endif // ROUTINEMANAGER_H
```

- [ ] **Step 3：创建 RoutineManager.cpp（CRUD 部分；materializeToday 先留桩）**

```cpp
#include "RoutineManager.h"

#include "DatabaseManager.h"

#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariantMap>

RoutineManager::RoutineManager(QObject* parent)
    : QObject(parent)
{
}

RoutineManager* RoutineManager::instance()
{
    static RoutineManager manager;
    return &manager;
}

QVariantList RoutineManager::getRoutines() const
{
    QVariantList result;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get routines: database is not open";
        return result;
    }

    QSqlQuery query(db);
    // 左连 categories 取科目名/色，供弹窗直接展示。
    if (!query.exec(QStringLiteral(
            "SELECT r.id, r.title, r.category_id, c.name AS category_name, c.color AS category_color, "
            "r.active, r.display_order "
            "FROM routines r LEFT JOIN categories c ON r.category_id = c.id "
            "ORDER BY r.display_order ASC, r.id ASC"))) {
        qWarning() << "Failed to get routines:" << query.lastError().text();
        return result;
    }

    while (query.next()) {
        QVariantMap map;
        map.insert(QStringLiteral("id"), query.value(0).toInt());
        map.insert(QStringLiteral("title"), query.value(1).toString());
        map.insert(QStringLiteral("categoryId"), query.value(2).isNull() ? -1 : query.value(2).toInt());
        map.insert(QStringLiteral("categoryName"), query.value(3).toString());
        map.insert(QStringLiteral("categoryColor"), query.value(4).toString());
        map.insert(QStringLiteral("active"), query.value(5).toInt() != 0);
        map.insert(QStringLiteral("displayOrder"), query.value(6).toInt());
        result.append(map);
    }
    return result;
}

bool RoutineManager::addRoutine(const QString& title, int categoryId)
{
    const QString normalized = title.trimmed();
    if (normalized.isEmpty()) {
        qWarning() << "Failed to add routine: title is empty";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add routine: database is not open";
        return false;
    }

    QSqlQuery orderQuery(db);
    if (!orderQuery.exec(QStringLiteral("SELECT COALESCE(MAX(display_order), 0) + 1 FROM routines"))
        || !orderQuery.next()) {
        qWarning() << "Failed to calculate routine display order:" << orderQuery.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO routines (title, category_id, active, display_order) "
        "VALUES (:title, :categoryId, 1, :displayOrder)"));
    query.bindValue(QStringLiteral(":title"), normalized);
    query.bindValue(QStringLiteral(":categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    query.bindValue(QStringLiteral(":displayOrder"), orderQuery.value(0).toInt());

    if (!query.exec()) {
        qWarning() << "Failed to add routine:" << query.lastError().text();
        return false;
    }

    emit routinesChanged();
    return true;
}

bool RoutineManager::updateRoutine(int id, const QString& title, int categoryId)
{
    const QString normalized = title.trimmed();
    if (id <= 0 || normalized.isEmpty()) {
        qWarning() << "Failed to update routine: invalid id or empty title";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update routine: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE routines SET title = :title, category_id = :categoryId WHERE id = :id"));
    query.bindValue(QStringLiteral(":title"), normalized);
    query.bindValue(QStringLiteral(":categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to update routine:" << query.lastError().text();
        return false;
    }

    emit routinesChanged();
    return true;
}

bool RoutineManager::setRoutineActive(int id, bool active)
{
    if (id <= 0) {
        qWarning() << "Failed to set routine active: invalid id";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to set routine active: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("UPDATE routines SET active = :active WHERE id = :id"));
    query.bindValue(QStringLiteral(":active"), active ? 1 : 0);
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to set routine active:" << query.lastError().text();
        return false;
    }

    emit routinesChanged();
    return true;
}

bool RoutineManager::deleteRoutine(int id)
{
    if (id <= 0) {
        qWarning() << "Failed to delete routine: invalid id";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete routine: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM routines WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to delete routine:" << query.lastError().text();
        return false;
    }

    emit routinesChanged();
    return true;
}

int RoutineManager::materializeToday()
{
    // Task 3 实现。
    return 0;
}
```

- [ ] **Step 4：把 RoutineManager.cpp 加入 CMake**

在 `CMakeLists.txt` 的 `set(APP_SOURCES` 列表里（`src/services/CountdownService.cpp` 一行附近）加：
```cmake
    src/services/RoutineManager.cpp
```
在 `add_executable(PomodoroTodoTests` 的源列表里（`src/services/FocusHistoryService.cpp` 一行后）加：
```cmake
    src/services/RoutineManager.cpp
```

- [ ] **Step 5：配置、构建、运行测试**

Run:
```bash
cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos
ctest --test-dir build -R PomodoroTodoTests --output-on-failure
```
Expected: 全部 PASS（含 `routineCrudAddsGetsUpdatesDeletes`）。

- [ ] **Step 6：提交**

```bash
git add src/services/RoutineManager.h src/services/RoutineManager.cpp CMakeLists.txt tests/ServiceTests.cpp
git commit -m "新增 RoutineManager 例行项增删改查"
```

---

## Task 3：materializeToday —— 当天例行任务生成

**Files:**
- Modify: `src/services/RoutineManager.cpp`（实现 `materializeToday`）
- Test: `tests/ServiceTests.cpp`（新增用例）

**Interfaces:**
- Consumes: Task 2 的 `RoutineManager`、`routines` 表、`tasks` 表。
- Produces: `int materializeToday()` —— 为每个 `active` 且 `last_generated_date` 为空或早于今天的例行项，插入一条今天的 `tasks` 行并把 `last_generated_date` 置为今天；返回新生成条数。**不发 `tasksChanged`/不递归**；调用方自行刷新。

- [ ] **Step 1：写失败测试**

`tests/ServiceTests.cpp` 顶部已包含 RoutineManager。声明：
```cpp
    void materializeTodayIsIdempotentAndDoesNotBackfill();
    void materializeTodayDoesNotResurrectDeletedTask();
    void materializeTodaySkipsInactiveRoutines();
```
实现：
```cpp
void ServiceTests::materializeTodayIsIdempotentAndDoesNotBackfill()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("背单词"), -1));

    const QString today = QDate::currentDate().toString(Qt::ISODate);

    // 首次生成：今天多一条任务
    QCOMPARE(manager->materializeToday(), 1);
    QCOMPARE(TaskManager::instance()->getTasksByDate(QDate::currentDate()).size(), 1);

    // 幂等：再次调用不重复生成
    QCOMPARE(manager->materializeToday(), 0);
    QCOMPARE(TaskManager::instance()->getTasksByDate(QDate::currentDate()).size(), 1);

    // 不补历史：把 last_generated_date 改到 3 天前，再调用只生成今天一条、不补中间天
    QSqlQuery upd(DatabaseManager::instance()->database());
    upd.exec(QStringLiteral("UPDATE routines SET last_generated_date = '2000-01-01'"));
    QCOMPARE(manager->materializeToday(), 1);
    QSqlQuery check(DatabaseManager::instance()->database());
    check.exec(QStringLiteral("SELECT last_generated_date FROM routines"));
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toString(), today);
}

void ServiceTests::materializeTodayDoesNotResurrectDeletedTask()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("数学真题"), -1));
    QCOMPARE(manager->materializeToday(), 1);

    QVariantList todays = TaskManager::instance()->getTasksByDate(QDate::currentDate());
    QCOMPARE(todays.size(), 1);
    const int taskId = todays.first().toMap().value(QStringLiteral("id")).toInt();

    // 删掉今天生成的任务后再生成 —— 当天不应复活
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    QCOMPARE(manager->materializeToday(), 0);
    QVERIFY(TaskManager::instance()->getTasksByDate(QDate::currentDate()).isEmpty());
}

void ServiceTests::materializeTodaySkipsInactiveRoutines()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("停用项"), -1));
    const int id = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(manager->setRoutineActive(id, false));

    QCOMPARE(manager->materializeToday(), 0);
    QVERIFY(TaskManager::instance()->getTasksByDate(QDate::currentDate()).isEmpty());
}
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: 三个新用例 FAIL（`materializeToday` 当前桩返回 0，生成数与任务数不符）。

- [ ] **Step 3：实现 materializeToday**

在 `RoutineManager.cpp` 顶部包含区加：
```cpp
#include <QDate>
```
把桩实现替换为：
```cpp
int RoutineManager::materializeToday()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to materialize routines: database is not open";
        return 0;
    }

    const QString today = QDate::currentDate().toString(Qt::ISODate);

    // 取所有启用、且今天还没生成过的例行项。last_generated_date 为空也算未生成。
    QSqlQuery due(db);
    due.prepare(QStringLiteral(
        "SELECT id, title, category_id FROM routines "
        "WHERE active = 1 AND (last_generated_date IS NULL OR last_generated_date < :today) "
        "ORDER BY display_order ASC, id ASC"));
    due.bindValue(QStringLiteral(":today"), today);
    if (!due.exec()) {
        qWarning() << "Failed to query due routines:" << due.lastError().text();
        return 0;
    }

    struct DueRoutine { int id; QString title; QVariant categoryId; };
    QList<DueRoutine> dueList;
    while (due.next()) {
        dueList.append({ due.value(0).toInt(), due.value(1).toString(), due.value(2) });
    }

    int generated = 0;
    for (const DueRoutine& routine : dueList) {
        // 直接插入任务行（不走 TaskManager.addTask，避免它发 tasksChanged 触发刷新递归）。
        // 同时按 category_id 子查询补写旧版 category 文本列，与 addTask 的双写保持一致。
        QSqlQuery insert(db);
        insert.prepare(QStringLiteral(
            "INSERT INTO tasks (title, category, category_id, date, completed) "
            "VALUES (:title, (SELECT name FROM categories WHERE id = :categoryId), :categoryId2, :date, 0)"));
        insert.bindValue(QStringLiteral(":title"), routine.title);
        insert.bindValue(QStringLiteral(":categoryId"), routine.categoryId);
        insert.bindValue(QStringLiteral(":categoryId2"), routine.categoryId);
        insert.bindValue(QStringLiteral(":date"), today);
        if (!insert.exec()) {
            qWarning() << "Failed to materialize routine task:" << insert.lastError().text();
            continue;
        }

        QSqlQuery mark(db);
        mark.prepare(QStringLiteral("UPDATE routines SET last_generated_date = :today WHERE id = :id"));
        mark.bindValue(QStringLiteral(":today"), today);
        mark.bindValue(QStringLiteral(":id"), routine.id);
        if (!mark.exec()) {
            qWarning() << "Failed to mark routine generated:" << mark.lastError().text();
            continue;
        }
        ++generated;
    }

    return generated;
}
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: 全部 PASS（含三个 materialize 用例与之前所有用例）。

- [ ] **Step 5：提交**

```bash
git add src/services/RoutineManager.cpp tests/ServiceTests.cpp
git commit -m "实现例行任务当天生成 materializeToday"
```

---

## Task 4：RoutineDialog 管理弹窗 + 侧栏入口 + 注册资源

**Files:**
- Create: `qml/components/RoutineDialog.qml`
- Modify: `qml/components/Sidebar.qml`（加「每日例行」入口与信号）
- Modify: `qml/MainWindow.qml`（放置 RoutineDialog 并接信号打开）
- Modify: `resources/qml.qrc`（注册 RoutineDialog.qml）
- Test: `tests/qml/tst_routine_dialog.qml`

**Interfaces:**
- Consumes: Task 2 的 `routineManager`（`getRoutines/addRoutine/deleteRoutine/setRoutineActive`、信号 `routinesChanged`）。
- Produces: `RoutineDialog`（Popup，`objectName: "routineDialog"`，属性 `routineManagerRef`、`categoryManagerRef`，函数 `submit()`）；Sidebar 信号 `dailyRoutineRequested()`。

- [ ] **Step 1：写失败测试**

`tests/qml/tst_routine_dialog.qml`：
```qml
import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "RoutineDialogUi"
    when: windowShown
    width: 1024
    height: 768

    property var added: []

    QtObject {
        id: fakeRoutineManager
        signal routinesChanged()
        function getRoutines() { return testCase.added }
        function addRoutine(title, categoryId) {
            testCase.added = testCase.added.concat([{
                id: testCase.added.length + 1, title: title, categoryId: categoryId,
                categoryName: "", categoryColor: "", active: true, displayOrder: 0
            }]);
            routinesChanged();
            return true;
        }
        function deleteRoutine(id) { return true }
        function setRoutineActive(id, active) { return true }
    }

    QtObject {
        id: fakeCategoryManager
        function getAllCategories() { return [] }
    }

    RoutineDialog {
        id: dialog
        routineManagerRef: fakeRoutineManager
        categoryManagerRef: fakeCategoryManager
    }

    function test_addRoutineShowsInList() {
        testCase.added = [];
        dialog.open();
        wait(120);

        var input = findChild(dialog, "routineTitleField");
        var addBtn = findChild(dialog, "routineAddButton");
        var list = findChild(dialog, "routineListView");
        verify(input !== null);
        verify(addBtn !== null);
        verify(list !== null);

        input.text = "背单词 list";
        dialog.submit();
        wait(120);

        compare(testCase.added.length, 1);
        compare(testCase.added[0].title, "背单词 list");
        compare(list.count, 1);
        dialog.close();
    }
}
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL —— `RoutineDialog is not a type` / 找不到组件。

- [ ] **Step 3：创建 RoutineDialog.qml**

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Popup {
    id: root

    objectName: "routineDialog"
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(460, parent ? Math.max(300, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    property var routineManagerRef: null
    property var categoryManagerRef: null
    property var routines: []
    // 第一项是「不设科目」占位，id 用 -1。
    property var categoryOptions: [{ id: -1, name: "不设置科目", color: "" }]

    function refresh() {
        if (root.routineManagerRef && root.routineManagerRef.getRoutines) {
            root.routines = root.routineManagerRef.getRoutines();
        } else {
            root.routines = [];
        }
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            root.categoryOptions = [{ id: -1, name: "不设置科目", color: "" }]
                .concat(root.categoryManagerRef.getAllCategories());
        }
    }

    function submit() {
        var title = titleField.text.trim();
        if (title.length === 0) {
            errorLabel.text = "请输入例行任务名称";
            titleField.forceActiveFocus();
            return;
        }
        var categoryId = root.categoryOptions.length > 0 && categoryCombo.currentIndex >= 0
            ? Number(root.categoryOptions[categoryCombo.currentIndex].id || -1) : -1;
        if (root.routineManagerRef && root.routineManagerRef.addRoutine(title, categoryId)) {
            titleField.text = "";
            errorLabel.text = "";
            titleField.forceActiveFocus();
        } else {
            errorLabel.text = "添加失败，请重试";
        }
    }

    Connections {
        target: root.routineManagerRef
        ignoreUnknownSignals: true
        function onRoutinesChanged() { root.refresh(); }
    }

    onOpened: {
        root.refresh();
        errorLabel.text = "";
        titleField.forceActiveFocus();
    }

    Overlay.modal: Rectangle {
        color: "#66000000"
        opacity: root.opened ? 1 : 0
        Behavior on opacity { OpacityAnimator { duration: 180; easing.type: Easing.InOutQuad } }
    }

    background: Rectangle {
        id: panel
        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.surface
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.12
            shadowBlur: 0.20
            shadowVerticalOffset: 4
        }
    }

    contentItem: ColumnLayout {
        id: contentColumn
        width: root.width
        spacing: Theme.space12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            color: Theme.surface
            radius: Theme.radiusLg

            ColumnLayout {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.space16
                anchors.rightMargin: Theme.space16
                spacing: 2

                Text {
                    text: "每日例行"
                    color: Theme.ink
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.Bold
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "把每天都要做的任务加进来，以后自动出现在今日清单。"
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            TextField {
                id: titleField
                objectName: "routineTitleField"
                Layout.fillWidth: true
                implicitHeight: 40
                placeholderText: "添加例行任务…"
                selectByMouse: true
                background: Rectangle {
                    color: Theme.surfaceRaised
                    border.color: titleField.activeFocus ? Theme.accent : Theme.border
                    border.width: titleField.activeFocus ? 2 : 1
                    radius: Theme.radiusMd
                }
                onTextEdited: errorLabel.text = ""
                Keys.onReturnPressed: root.submit()
                Keys.onEnterPressed: root.submit()
            }

            ComboBox {
                id: categoryCombo
                objectName: "routineCategoryCombo"
                Layout.preferredWidth: 110
                implicitHeight: 40
                model: root.categoryOptions
                textRole: "name"
                currentIndex: 0
            }

            Button {
                id: addButton
                objectName: "routineAddButton"
                text: "添加"
                implicitHeight: 40
                implicitWidth: 64
                background: Rectangle {
                    color: addButton.pressed || addButton.hovered ? Theme.accentStrong : Theme.accent
                    radius: Theme.radiusMd
                }
                contentItem: Text {
                    text: addButton.text
                    color: Theme.surface
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: root.submit()
            }
        }

        Label {
            id: errorLabel
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            visible: text.length > 0
            wrapMode: Text.WordWrap
        }

        ListView {
            id: routineList
            objectName: "routineListView"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            Layout.preferredHeight: Math.min(260, Math.max(48, count * 52))
            clip: true
            model: root.routines
            spacing: Theme.space8

            delegate: Rectangle {
                width: ListView.view.width
                height: 44
                radius: Theme.radiusMd
                color: Theme.surfaceRaised
                border.color: Theme.border
                border.width: 1
                opacity: modelData.active ? 1.0 : 0.55

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space12
                    anchors.rightMargin: Theme.space8
                    spacing: Theme.space8

                    Rectangle {
                        Layout.preferredWidth: 10
                        Layout.preferredHeight: 10
                        radius: Theme.radiusSm
                        visible: String(modelData.categoryColor || "").length > 0
                        color: visible ? modelData.categoryColor : "transparent"
                    }

                    Text {
                        Layout.fillWidth: true
                        text: modelData.title + (modelData.active ? "" : "（已停用）")
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                    }

                    Switch {
                        checked: modelData.active
                        onToggled: {
                            if (root.routineManagerRef)
                                root.routineManagerRef.setRoutineActive(modelData.id, checked);
                        }
                    }

                    Button {
                        text: "删除"
                        implicitHeight: 30
                        implicitWidth: 56
                        background: Rectangle {
                            color: Theme.surface
                            border.color: Theme.border
                            border.width: 1
                            radius: Theme.radiusMd
                        }
                        contentItem: Text {
                            text: parent.text
                            color: Theme.dangerSoft
                            font.pixelSize: Theme.fontSm
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        onClicked: {
                            if (root.routineManagerRef)
                                root.routineManagerRef.deleteRoutine(modelData.id);
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4：注册到 qrc**

在 `resources/qml.qrc` 的 `</qresource>` 之前加：
```xml
        <file alias="qml/components/RoutineDialog.qml">../qml/components/RoutineDialog.qml</file>
```

- [ ] **Step 5：侧栏加入口**

在 `qml/components/Sidebar.qml`：
信号区（`signal dataExportRequested` 旁）加：
```qml
    signal dailyRoutineRequested
```
在「科目管理」`SidebarItem` 之前（约第 119 行）加一项：
```qml
        SidebarItem {
            text: "每日例行"
            marker: "例"
            isActive: false
            onClicked: root.dailyRoutineRequested()
        }
```

- [ ] **Step 6：MainWindow 接信号、放置弹窗**

在 `qml/MainWindow.qml`：Sidebar 的信号处理区（`onCategoryManagementRequested`/`onDataExportRequested` 旁）加：
```qml
                onDailyRoutineRequested: routineDialog.open()
```
在 `CategoryDialog { ... }` 之后加：
```qml
    RoutineDialog {
        id: routineDialog

        parent: root
        routineManagerRef: typeof routineManager === "undefined" ? null : routineManager
        categoryManagerRef: categoryManager
    }
```

- [ ] **Step 7：qmllint + 运行 QML 测试**

Run:
```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/RoutineDialog.qml qml/components/Sidebar.qml qml/MainWindow.qml
cmake --build build && ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure
```
Expected: qmllint 无 error；QML 测试全部 PASS（含 `RoutineDialogUi::test_addRoutineShowsInList`，且 Sidebar/MainWindow 旧用例不回归）。

- [ ] **Step 8：提交**

```bash
git add qml/components/RoutineDialog.qml qml/components/Sidebar.qml qml/MainWindow.qml resources/qml.qrc tests/qml/tst_routine_dialog.qml
git commit -m "新增每日例行管理弹窗与侧栏入口"
```

---

## Task 5：接入运行时 —— 启动生成 + 今日页触发

**Files:**
- Modify: `src/main.cpp`（注册 `routineManager` + 启动时生成）
- Modify: `qml/views/TodayTaskView.qml`（refresh 时生成 + 监听 routinesChanged）

**Interfaces:**
- Consumes: Task 3 的 `RoutineManager::instance()->materializeToday()`、Task 2 的 `routineManager` context property。

- [ ] **Step 1：main.cpp 注册服务并在启动时生成**

在 `src/main.cpp` 顶部包含区加：
```cpp
#include "services/RoutineManager.h"
```
在 `DatabaseManager::instance()->initialize()` 成功之后（`if (!DatabaseManager...) return -1;` 之下）加：
```cpp
    // 启动即生成今天的例行任务，确保任何视图首次读取时已就绪。
    RoutineManager::instance()->materializeToday();
```
在其它 `setContextProperty(...)` 之中（`countdownService` 那一行旁）加：
```cpp
    engine.rootContext()->setContextProperty(QStringLiteral("routineManager"), RoutineManager::instance());
```

- [ ] **Step 2：TodayTaskView 刷新时生成、并监听例行变化**

在 `qml/views/TodayTaskView.qml` 的 `refresh()` 函数体最前面加（在 `loadTasks()` 之前）：
```qml
        // 跨午夜或新加例行项时，确保当天例行任务已生成。materializeToday 幂等且不发信号，无递归。
        if (typeof routineManager !== "undefined" && routineManager) {
            routineManager.materializeToday();
        }
```
在已有的 `Connections { target: focusTimer ... }` 之后，新增一段监听（新加/启用例行项时，今日页立即带出当天的它）：
```qml
    Connections {
        target: typeof routineManager !== "undefined" ? routineManager : null
        ignoreUnknownSignals: true
        function onRoutinesChanged() {
            root.refresh();
        }
    }
```

- [ ] **Step 3：构建 + 全量测试**

Run:
```bash
cmake --build build
ctest --test-dir build --output-on-failure
```
Expected: 三套件全部 PASS（C++ 含 routine 相关；QML 含 RoutineDialog 与既有用例——TodayTaskView 的 `routineManager` 用了 `typeof` 守护，注入缺失时安全跳过，旧用例不回归）。

- [ ] **Step 4：人工冒烟（真机）**

```bash
osascript -e 'quit app "番茄Todo"'; pkill -f "番茄Todo.app"; sleep 1
open "/Applications/番茄Todo.app"
```
检查：侧栏出现「每日例行」→ 打开弹窗加一条「背单词」→ 关闭后今日任务页立刻出现「背单词」；重启 App 后它仍每天自动出现；勾选完成/删除行为与普通任务一致。

- [ ] **Step 5：提交**

```bash
git add src/main.cpp qml/views/TodayTaskView.qml
git commit -m "接入例行任务：启动与今日页刷新时自动生成"
```

---

## 自检备注

- **Spec 覆盖**：routines 表/迁移=T1；RoutineManager CRUD=T2；materializeToday 幂等/删不复活/不补历史/停用跳过=T3；RoutineDialog + 侧栏入口 + qrc=T4；启动与今日页触发、context property 注册=T5。边界（停用/删除只停未来、过去任务不结转、空标题拒绝、DB 未开容错）分散在 T2/T3 的实现与测试中。
- **类型一致性**：`materializeToday()→int`、`getRoutines()` 返回的 map 键（`id/title/categoryId/categoryName/categoryColor/active/displayOrder`）在 T2 定义、T3/T4 引用一致；`routineManager` context property 名在 T4(QML 引用)/T5(注册) 一致；Sidebar 信号 `dailyRoutineRequested` 在 T4 定义并被 MainWindow 接。
- **不发 tasksChanged 的理由**：materializeToday 直接插库不发信号，今日页在 refresh 起始处主动调用它再读任务，避免「addTask→tasksChanged→refresh→materialize」递归。
- **向后兼容**：v3 迁移纯新增表、不动 tasks；旧库升级后 routines 为空＝无例行项，行为不变。
