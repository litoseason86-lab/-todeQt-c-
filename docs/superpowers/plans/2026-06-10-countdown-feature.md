# 目标倒计时功能实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为番茄Todo应用添加目标倒计时功能，支持多个目标管理，在独立视图页和今日任务页顶部展示

**Architecture:** C++ Service层（CountdownService + CountdownModel）处理数据持久化和业务逻辑，QML View层（CountdownView + CountdownBanner + CountdownDialog + CountdownItem）负责UI展示和交互，遵循现有的单例Service模式

**Tech Stack:** C++17, Qt 6, SQLite, Qt Quick/QML, Qt Test

---

## 文件结构

本计划将创建和修改以下文件：

**新增文件（数据层）：**
- `src/services/CountdownService.h` - 倒计时服务头文件（单例模式）
- `src/services/CountdownService.cpp` - 倒计时服务实现（CRUD操作、数据库管理）
- `src/models/CountdownModel.h` - QAbstractListModel头文件
- `src/models/CountdownModel.cpp` - QAbstractListModel实现
- `src/models/CountdownGoal.h` - 数据结构头文件
- `src/models/CountdownGoal.cpp` - 数据结构实现

**新增文件（UI层）：**
- `qml/components/CountdownDialog.qml` - 添加/编辑对话框
- `qml/components/CountdownBanner.qml` - 横幅组件（今日任务页）
- `qml/components/CountdownItem.qml` - 列表项组件
- `qml/views/CountdownView.qml` - 独立视图页

**新增文件（测试）：**
- `tests/CountdownServiceTests.cpp` - CountdownService单元测试

**修改文件（集成）：**
- `CMakeLists.txt` - 添加新文件到构建系统
- `src/main.cpp` - 初始化CountdownService并注册到QML上下文
- `qml/components/Sidebar.qml` - 添加"目标倒计时"入口
- `qml/MainWindow.qml` - 注册CountdownView到视图栈
- `qml/views/TodayTaskView.qml` - 集成CountdownBanner
- `resources/qml.qrc` - 添加新QML文件到资源

---

## 实施任务

### Task 1: CountdownGoal数据结构

**Files:**
- Create: `src/models/CountdownGoal.h`
- Create: `src/models/CountdownGoal.cpp`

- [ ] **Step 1.1: 创建CountdownGoal头文件**

```cpp
// src/models/CountdownGoal.h
#ifndef COUNTDOWNGOAL_H
#define COUNTDOWNGOAL_H

#include <QDate>
#include <QDateTime>
#include <QMetaType>
#include <QString>

class CountdownGoal
{
    Q_GADGET
    Q_PROPERTY(int id MEMBER m_id)
    Q_PROPERTY(QString name MEMBER m_name)
    Q_PROPERTY(QDate targetDate MEMBER m_targetDate)
    Q_PROPERTY(int displayOrder MEMBER m_displayOrder)

public:
    CountdownGoal();
    CountdownGoal(int id, const QString& name, const QDate& targetDate, 
                  int displayOrder, const QDateTime& createdAt, const QDateTime& updatedAt);

    int id() const { return m_id; }
    QString name() const { return m_name; }
    QDate targetDate() const { return m_targetDate; }
    int displayOrder() const { return m_displayOrder; }
    QDateTime createdAt() const { return m_createdAt; }
    QDateTime updatedAt() const { return m_updatedAt; }

    void setId(int id) { m_id = id; }
    void setName(const QString& name) { m_name = name; }
    void setTargetDate(const QDate& date) { m_targetDate = date; }
    void setDisplayOrder(int order) { m_displayOrder = order; }
    void setUpdatedAt(const QDateTime& dt) { m_updatedAt = dt; }

    int daysRemaining() const;

private:
    int m_id = -1;
    QString m_name;
    QDate m_targetDate;
    int m_displayOrder = 0;
    QDateTime m_createdAt;
    QDateTime m_updatedAt;
};

Q_DECLARE_METATYPE(CountdownGoal)

#endif // COUNTDOWNGOAL_H
```

- [ ] **Step 1.2: 实现CountdownGoal**

```cpp
// src/models/CountdownGoal.cpp
#include "CountdownGoal.h"

CountdownGoal::CountdownGoal()
    : m_id(-1)
    , m_displayOrder(0)
{
}

CountdownGoal::CountdownGoal(int id, const QString& name, const QDate& targetDate,
                             int displayOrder, const QDateTime& createdAt, const QDateTime& updatedAt)
    : m_id(id)
    , m_name(name)
    , m_targetDate(targetDate)
    , m_displayOrder(displayOrder)
    , m_createdAt(createdAt)
    , m_updatedAt(updatedAt)
{
}

int CountdownGoal::daysRemaining() const
{
    if (!m_targetDate.isValid()) {
        return 0;
    }
    return QDate::currentDate().daysTo(m_targetDate);
}
```

- [ ] **Step 1.3: 编译验证**

Run: `cmake --build build`

Expected: 编译成功，无错误

- [ ] **Step 1.4: 提交**

```bash
git add src/models/CountdownGoal.h src/models/CountdownGoal.cpp
git commit -m "feat: add CountdownGoal data structure"
```

---

### Task 2: CountdownModel（QAbstractListModel）

**Files:**
- Create: `src/models/CountdownModel.h`
- Create: `src/models/CountdownModel.cpp`

- [ ] **Step 2.1: 创建CountdownModel头文件**

```cpp
// src/models/CountdownModel.h
#ifndef COUNTDOWNMODEL_H
#define COUNTDOWNMODEL_H

#include <QAbstractListModel>
#include <QList>
#include "CountdownGoal.h"

class CountdownModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NameRole,
        TargetDateRole,
        DisplayOrderRole,
        DaysRemainingRole
    };

    explicit CountdownModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setGoals(const QList<CountdownGoal>& goals);
    void addGoal(const CountdownGoal& goal);
    void updateGoal(int index, const CountdownGoal& goal);
    void removeGoal(int index);
    void moveGoal(int fromIndex, int toIndex);

    const QList<CountdownGoal>& goals() const { return m_goals; }

private:
    QList<CountdownGoal> m_goals;
};

#endif // COUNTDOWNMODEL_H
```

- [ ] **Step 2.2: 实现CountdownModel**

```cpp
// src/models/CountdownModel.cpp
#include "CountdownModel.h"

CountdownModel::CountdownModel(QObject* parent)
    : QAbstractListModel(parent)
{
}

int CountdownModel::rowCount(const QModelIndex& parent) const
{
    if (parent.isValid()) {
        return 0;
    }
    return m_goals.count();
}

QVariant CountdownModel::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= m_goals.count()) {
        return QVariant();
    }

    const CountdownGoal& goal = m_goals.at(index.row());

    switch (role) {
    case IdRole:
        return goal.id();
    case NameRole:
        return goal.name();
    case TargetDateRole:
        return goal.targetDate();
    case DisplayOrderRole:
        return goal.displayOrder();
    case DaysRemainingRole:
        return goal.daysRemaining();
    default:
        return QVariant();
    }
}

QHash<int, QByteArray> CountdownModel::roleNames() const
{
    QHash<int, QByteArray> roles;
    roles[IdRole] = "goalId";
    roles[NameRole] = "name";
    roles[TargetDateRole] = "targetDate";
    roles[DisplayOrderRole] = "displayOrder";
    roles[DaysRemainingRole] = "daysRemaining";
    return roles;
}

void CountdownModel::setGoals(const QList<CountdownGoal>& goals)
{
    beginResetModel();
    m_goals = goals;
    endResetModel();
}

void CountdownModel::addGoal(const CountdownGoal& goal)
{
    int row = m_goals.count();
    beginInsertRows(QModelIndex(), row, row);
    m_goals.append(goal);
    endInsertRows();
}

void CountdownModel::updateGoal(int index, const CountdownGoal& goal)
{
    if (index < 0 || index >= m_goals.count()) {
        return;
    }
    m_goals[index] = goal;
    QModelIndex modelIndex = this->index(index);
    emit dataChanged(modelIndex, modelIndex);
}

void CountdownModel::removeGoal(int index)
{
    if (index < 0 || index >= m_goals.count()) {
        return;
    }
    beginRemoveRows(QModelIndex(), index, index);
    m_goals.removeAt(index);
    endRemoveRows();
}

void CountdownModel::moveGoal(int fromIndex, int toIndex)
{
    if (fromIndex < 0 || fromIndex >= m_goals.count() ||
        toIndex < 0 || toIndex >= m_goals.count() ||
        fromIndex == toIndex) {
        return;
    }

    beginMoveRows(QModelIndex(), fromIndex, fromIndex, QModelIndex(), 
                  toIndex > fromIndex ? toIndex + 1 : toIndex);
    m_goals.move(fromIndex, toIndex);
    endMoveRows();
}
```

- [ ] **Step 2.3: 编译验证**

Run: `cmake --build build`

Expected: 编译成功，无错误

- [ ] **Step 2.4: 提交**

```bash
git add src/models/CountdownModel.h src/models/CountdownModel.cpp
git commit -m "feat: add CountdownModel (QAbstractListModel)"
```

---

### Task 3: CountdownService（服务层）

**Files:**
- Create: `src/services/CountdownService.h`
- Create: `src/services/CountdownService.cpp`

- [ ] **Step 3.1: 创建CountdownService头文件**

```cpp
// src/services/CountdownService.h
#ifndef COUNTDOWNSERVICE_H
#define COUNTDOWNSERVICE_H

#include <QDate>
#include <QObject>
#include <QSqlDatabase>
#include "../models/CountdownGoal.h"
#include "../models/CountdownModel.h"

class CountdownService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(CountdownModel* model READ model CONSTANT)
    Q_PROPERTY(CountdownGoal* primaryGoal READ primaryGoal NOTIFY primaryGoalChanged)

public:
    static CountdownService* instance();

    Q_INVOKABLE bool addGoal(const QString& name, const QDate& targetDate);
    Q_INVOKABLE bool updateGoal(int id, const QString& name, const QDate& targetDate);
    Q_INVOKABLE bool deleteGoal(int id);
    Q_INVOKABLE bool reorder(int fromIndex, int toIndex);
    Q_INVOKABLE int calculateDaysRemaining(const QDate& targetDate) const;

    CountdownModel* model() const { return m_model; }
    CountdownGoal* primaryGoal() const { return m_primaryGoal; }

signals:
    void primaryGoalChanged();
    void errorOccurred(const QString& message);

private:
    explicit CountdownService(QObject* parent = nullptr);
    
    bool initializeDatabase();
    void loadGoals();
    void updatePrimaryGoal();
    int findGoalIndexById(int id) const;

    CountdownModel* m_model;
    CountdownGoal* m_primaryGoal;
};

#endif // COUNTDOWNSERVICE_H
```

- [ ] **Step 3.2: 实现CountdownService基础框架**

```cpp
// src/services/CountdownService.cpp
#include "CountdownService.h"
#include "DatabaseManager.h"
#include <QSqlError>
#include <QSqlQuery>
#include <QDebug>

CountdownService::CountdownService(QObject* parent)
    : QObject(parent)
    , m_model(new CountdownModel(this))
    , m_primaryGoal(nullptr)
{
    if (initializeDatabase()) {
        loadGoals();
    }
}

CountdownService* CountdownService::instance()
{
    static CountdownService instance;
    return &instance;
}

bool CountdownService::initializeDatabase()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Database is not open";
        return false;
    }

    QSqlQuery query(db);
    bool success = query.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS countdown_goals ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, "
        "name TEXT NOT NULL, "
        "target_date TEXT NOT NULL, "
        "display_order INTEGER NOT NULL, "
        "created_at TEXT NOT NULL, "
        "updated_at TEXT NOT NULL)"
    ));

    if (!success) {
        qWarning() << "Failed to create countdown_goals table:" << query.lastError().text();
        return false;
    }

    success = query.exec(QStringLiteral(
        "CREATE INDEX IF NOT EXISTS idx_display_order ON countdown_goals(display_order)"
    ));

    if (!success) {
        qWarning() << "Failed to create index:" << query.lastError().text();
    }

    return true;
}

int CountdownService::calculateDaysRemaining(const QDate& targetDate) const
{
    if (!targetDate.isValid()) {
        return 0;
    }
    return QDate::currentDate().daysTo(targetDate);
}

int CountdownService::findGoalIndexById(int id) const
{
    const QList<CountdownGoal>& goals = m_model->goals();
    for (int i = 0; i < goals.count(); ++i) {
        if (goals.at(i).id() == id) {
            return i;
        }
    }
    return -1;
}
```

- [ ] **Step 3.3: 实现loadGoals方法**

```cpp
// 添加到 src/services/CountdownService.cpp

void CountdownService::loadGoals()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "SELECT id, name, target_date, display_order, created_at, updated_at "
        "FROM countdown_goals ORDER BY display_order ASC"
    ));

    if (!query.exec()) {
        qWarning() << "Failed to load countdown goals:" << query.lastError().text();
        return;
    }

    QList<CountdownGoal> goals;
    while (query.next()) {
        int id = query.value(0).toInt();
        QString name = query.value(1).toString();
        QDate targetDate = QDate::fromString(query.value(2).toString(), Qt::ISODate);
        int displayOrder = query.value(3).toInt();
        QDateTime createdAt = QDateTime::fromString(query.value(4).toString(), Qt::ISODate);
        QDateTime updatedAt = QDateTime::fromString(query.value(5).toString(), Qt::ISODate);

        goals.append(CountdownGoal(id, name, targetDate, displayOrder, createdAt, updatedAt));
    }

    m_model->setGoals(goals);
    updatePrimaryGoal();
}

void CountdownService::updatePrimaryGoal()
{
    const QList<CountdownGoal>& goals = m_model->goals();
    
    if (goals.isEmpty()) {
        if (m_primaryGoal != nullptr) {
            delete m_primaryGoal;
            m_primaryGoal = nullptr;
            emit primaryGoalChanged();
        }
        return;
    }

    CountdownGoal firstGoal = goals.first();
    
    if (m_primaryGoal == nullptr) {
        m_primaryGoal = new CountdownGoal(firstGoal);
        emit primaryGoalChanged();
    } else if (m_primaryGoal->id() != firstGoal.id()) {
        *m_primaryGoal = firstGoal;
        emit primaryGoalChanged();
    }
}
```

- [ ] **Step 3.4: 实现addGoal方法**

```cpp
// 添加到 src/services/CountdownService.cpp

bool CountdownService::addGoal(const QString& name, const QDate& targetDate)
{
    QString trimmedName = name.trimmed();
    if (trimmedName.isEmpty() || trimmedName.length() > 50) {
        emit errorOccurred(QStringLiteral("目标名称长度必须在1-50字符之间"));
        return false;
    }

    if (!targetDate.isValid()) {
        emit errorOccurred(QStringLiteral("目标日期无效"));
        return false;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    
    query.prepare(QStringLiteral("SELECT COALESCE(MAX(display_order), -1) + 1 FROM countdown_goals"));
    if (!query.exec() || !query.next()) {
        emit errorOccurred(QStringLiteral("获取displayOrder失败"));
        return false;
    }
    int newDisplayOrder = query.value(0).toInt();

    QDateTime now = QDateTime::currentDateTime();
    QString nowString = now.toString(Qt::ISODate);

    query.prepare(QStringLiteral(
        "INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
        "VALUES (:name, :targetDate, :displayOrder, :createdAt, :updatedAt)"
    ));
    query.bindValue(QStringLiteral(":name"), trimmedName);
    query.bindValue(QStringLiteral(":targetDate"), targetDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":displayOrder"), newDisplayOrder);
    query.bindValue(QStringLiteral(":createdAt"), nowString);
    query.bindValue(QStringLiteral(":updatedAt"), nowString);

    if (!query.exec()) {
        emit errorOccurred(QStringLiteral("添加目标失败: ") + query.lastError().text());
        return false;
    }

    int newId = query.lastInsertId().toInt();
    CountdownGoal newGoal(newId, trimmedName, targetDate, newDisplayOrder, now, now);
    m_model->addGoal(newGoal);
    updatePrimaryGoal();

    return true;
}
```

- [ ] **Step 3.5: 实现updateGoal方法**

```cpp
// 添加到 src/services/CountdownService.cpp

bool CountdownService::updateGoal(int id, const QString& name, const QDate& targetDate)
{
    QString trimmedName = name.trimmed();
    if (trimmedName.isEmpty() || trimmedName.length() > 50) {
        emit errorOccurred(QStringLiteral("目标名称长度必须在1-50字符之间"));
        return false;
    }

    if (!targetDate.isValid()) {
        emit errorOccurred(QStringLiteral("目标日期无效"));
        return false;
    }

    int index = findGoalIndexById(id);
    if (index == -1) {
        emit errorOccurred(QStringLiteral("目标不存在"));
        return false;
    }

    QDateTime now = QDateTime::currentDateTime();
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "UPDATE countdown_goals SET name = :name, target_date = :targetDate, "
        "updated_at = :updatedAt WHERE id = :id"
    ));
    query.bindValue(QStringLiteral(":name"), trimmedName);
    query.bindValue(QStringLiteral(":targetDate"), targetDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":updatedAt"), now.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        emit errorOccurred(QStringLiteral("更新目标失败: ") + query.lastError().text());
        return false;
    }

    CountdownGoal updatedGoal = m_model->goals().at(index);
    updatedGoal.setName(trimmedName);
    updatedGoal.setTargetDate(targetDate);
    updatedGoal.setUpdatedAt(now);
    
    m_model->updateGoal(index, updatedGoal);
    updatePrimaryGoal();

    return true;
}
```

- [ ] **Step 3.6: 实现deleteGoal和reorder方法**

```cpp
// 添加到 src/services/CountdownService.cpp

bool CountdownService::deleteGoal(int id)
{
    int index = findGoalIndexById(id);
    if (index == -1) {
        emit errorOccurred(QStringLiteral("目标不存在"));
        return false;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("DELETE FROM countdown_goals WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        emit errorOccurred(QStringLiteral("删除目标失败: ") + query.lastError().text());
        return false;
    }

    m_model->removeGoal(index);
    updatePrimaryGoal();

    return true;
}

bool CountdownService::reorder(int fromIndex, int toIndex)
{
    const QList<CountdownGoal>& goals = m_model->goals();
    
    if (fromIndex < 0 || fromIndex >= goals.count() ||
        toIndex < 0 || toIndex >= goals.count() ||
        fromIndex == toIndex) {
        return false;
    }

    m_model->moveGoal(fromIndex, toIndex);

    QSqlDatabase db = DatabaseManager::instance()->database();
    db.transaction();

    const QList<CountdownGoal>& reorderedGoals = m_model->goals();
    for (int i = 0; i < reorderedGoals.count(); ++i) {
        QSqlQuery query(db);
        query.prepare(QStringLiteral(
            "UPDATE countdown_goals SET display_order = :order WHERE id = :id"
        ));
        query.bindValue(QStringLiteral(":order"), i);
        query.bindValue(QStringLiteral(":id"), reorderedGoals.at(i).id());

        if (!query.exec()) {
            db.rollback();
            emit errorOccurred(QStringLiteral("排序失败: ") + query.lastError().text());
            loadGoals();
            return false;
        }
    }

    db.commit();
    updatePrimaryGoal();

    return true;
}
```

- [ ] **Step 3.7: 编译验证**

Run: `cmake --build build`

Expected: 编译成功，无错误

- [ ] **Step 3.8: 提交**

```bash
git add src/services/CountdownService.h src/services/CountdownService.cpp
git commit -m "feat: add CountdownService with CRUD operations"
```

---

### Task 4: 单元测试

**Files:**
- Create: `tests/CountdownServiceTests.cpp`
- Modify: `CMakeLists.txt` - 添加新测试文件

- [ ] **Step 4.1: 创建测试文件框架**

```cpp
// tests/CountdownServiceTests.cpp
#include <QCoreApplication>
#include <QDate>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/CountdownService.h"
#include "../src/services/DatabaseManager.h"

class CountdownServiceTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void cleanup();

    void testAddGoal();
    void testAddGoalWithInvalidName();
    void testAddGoalWithInvalidDate();
    void testUpdateGoal();
    void testDeleteGoal();
    void testReorder();
    void testPrimaryGoal();
    void testCalculateDaysRemaining();

private:
    QTemporaryDir* m_tempDir;
};

void CountdownServiceTests::initTestCase()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTest"));
    QCoreApplication::setApplicationName(QStringLiteral("CountdownServiceTests"));
    
    QString dbPath = m_tempDir->filePath(QStringLiteral("test.db"));
    DatabaseManager::instance()->initialize(dbPath);
}

void CountdownServiceTests::cleanupTestCase()
{
    delete m_tempDir;
}

void CountdownServiceTests::cleanup()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.exec(QStringLiteral("DELETE FROM countdown_goals"));
    CountdownService::instance()->model()->setGoals(QList<CountdownGoal>());
}

QTEST_MAIN(CountdownServiceTests)
#include "CountdownServiceTests.moc"
```

- [ ] **Step 4.2: 实现testAddGoal测试**

```cpp
// 添加到 tests/CountdownServiceTests.cpp 的 CountdownServiceTests 类中

void CountdownServiceTests::testAddGoal()
{
    CountdownService* service = CountdownService::instance();
    
    QDate targetDate = QDate::currentDate().addDays(30);
    bool result = service->addGoal(QStringLiteral("研究生初试"), targetDate);
    
    QVERIFY(result);
    QCOMPARE(service->model()->rowCount(), 1);
    
    QModelIndex index = service->model()->index(0);
    QCOMPARE(service->model()->data(index, CountdownModel::NameRole).toString(), 
             QStringLiteral("研究生初试"));
    QCOMPARE(service->model()->data(index, CountdownModel::TargetDateRole).toDate(), targetDate);
    QCOMPARE(service->model()->data(index, CountdownModel::DisplayOrderRole).toInt(), 0);
}

void CountdownServiceTests::testAddGoalWithInvalidName()
{
    CountdownService* service = CountdownService::instance();
    
    bool result = service->addGoal(QString(), QDate::currentDate());
    QVERIFY(!result);
    
    QString longName(51, 'a');
    result = service->addGoal(longName, QDate::currentDate());
    QVERIFY(!result);
}

void CountdownServiceTests::testAddGoalWithInvalidDate()
{
    CountdownService* service = CountdownService::instance();
    
    bool result = service->addGoal(QStringLiteral("测试"), QDate());
    QVERIFY(!result);
}
```

- [ ] **Step 4.3: 实现其他测试方法**

```cpp
// 添加到 tests/CountdownServiceTests.cpp 的 CountdownServiceTests 类中

void CountdownServiceTests::testUpdateGoal()
{
    CountdownService* service = CountdownService::instance();
    
    QDate originalDate = QDate::currentDate().addDays(30);
    service->addGoal(QStringLiteral("原始目标"), originalDate);
    
    QModelIndex index = service->model()->index(0);
    int goalId = service->model()->data(index, CountdownModel::IdRole).toInt();
    
    QDate newDate = QDate::currentDate().addDays(60);
    bool result = service->updateGoal(goalId, QStringLiteral("更新目标"), newDate);
    
    QVERIFY(result);
    QCOMPARE(service->model()->data(index, CountdownModel::NameRole).toString(), 
             QStringLiteral("更新目标"));
    QCOMPARE(service->model()->data(index, CountdownModel::TargetDateRole).toDate(), newDate);
}

void CountdownServiceTests::testDeleteGoal()
{
    CountdownService* service = CountdownService::instance();
    
    service->addGoal(QStringLiteral("目标1"), QDate::currentDate().addDays(10));
    service->addGoal(QStringLiteral("目标2"), QDate::currentDate().addDays(20));
    
    QCOMPARE(service->model()->rowCount(), 2);
    
    QModelIndex index = service->model()->index(0);
    int goalId = service->model()->data(index, CountdownModel::IdRole).toInt();
    
    bool result = service->deleteGoal(goalId);
    QVERIFY(result);
    QCOMPARE(service->model()->rowCount(), 1);
    QCOMPARE(service->model()->data(service->model()->index(0), CountdownModel::NameRole).toString(),
             QStringLiteral("目标2"));
}

void CountdownServiceTests::testReorder()
{
    CountdownService* service = CountdownService::instance();
    
    service->addGoal(QStringLiteral("目标1"), QDate::currentDate().addDays(10));
    service->addGoal(QStringLiteral("目标2"), QDate::currentDate().addDays(20));
    service->addGoal(QStringLiteral("目标3"), QDate::currentDate().addDays(30));
    
    bool result = service->reorder(0, 2);
    QVERIFY(result);
    
    QCOMPARE(service->model()->data(service->model()->index(0), CountdownModel::NameRole).toString(),
             QStringLiteral("目标2"));
    QCOMPARE(service->model()->data(service->model()->index(1), CountdownModel::NameRole).toString(),
             QStringLiteral("目标3"));
    QCOMPARE(service->model()->data(service->model()->index(2), CountdownModel::NameRole).toString(),
             QStringLiteral("目标1"));
}

void CountdownServiceTests::testPrimaryGoal()
{
    CountdownService* service = CountdownService::instance();
    
    QVERIFY(service->primaryGoal() == nullptr);
    
    service->addGoal(QStringLiteral("目标1"), QDate::currentDate().addDays(10));
    QVERIFY(service->primaryGoal() != nullptr);
    QCOMPARE(service->primaryGoal()->name(), QStringLiteral("目标1"));
    
    service->addGoal(QStringLiteral("目标2"), QDate::currentDate().addDays(20));
    QCOMPARE(service->primaryGoal()->name(), QStringLiteral("目标1"));
    
    service->reorder(1, 0);
    QCOMPARE(service->primaryGoal()->name(), QStringLiteral("目标2"));
}

void CountdownServiceTests::testCalculateDaysRemaining()
{
    CountdownService* service = CountdownService::instance();
    
    QDate today = QDate::currentDate();
    QCOMPARE(service->calculateDaysRemaining(today), 0);
    QCOMPARE(service->calculateDaysRemaining(today.addDays(10)), 10);
    QCOMPARE(service->calculateDaysRemaining(today.addDays(-5)), -5);
    QCOMPARE(service->calculateDaysRemaining(QDate()), 0);
}
```

- [ ] **Step 4.4: 运行测试**

Run: `cmake --build build && ctest --test-dir build --output-on-failure -R CountdownServiceTests`

Expected: 所有测试通过

- [ ] **Step 4.5: 提交**

```bash
git add tests/CountdownServiceTests.cpp
git commit -m "test: add CountdownService unit tests"
```

---

### Task 5: 更新CMakeLists.txt

**Files:**
- Modify: `CMakeLists.txt`

- [ ] **Step 5.1: 添加新源文件到构建系统**

在 `CMakeLists.txt` 中找到 `set(APP_SOURCES` 部分，添加：

```cmake
set(APP_SOURCES
    src/main.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.cpp
    src/services/ExportService.cpp
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    src/services/StatisticsService.cpp
    src/services/CountdownService.cpp
    resources/qml.qrc
)
```

- [ ] **Step 5.2: 添加测试文件**

在 `add_executable(PomodoroTodoTests` 部分添加：

```cmake
add_executable(PomodoroTodoTests
    tests/ServiceTests.cpp
    tests/CountdownServiceTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.cpp
    src/services/ExportService.cpp
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    src/services/StatisticsService.cpp
    src/services/CountdownService.cpp
)
```

- [ ] **Step 5.3: 编译验证**

Run: `cmake --build build`

Expected: 编译成功

- [ ] **Step 5.4: 运行所有测试**

Run: `ctest --test-dir build --output-on-failure`

Expected: 所有测试通过

- [ ] **Step 5.5: 提交**

```bash
git add CMakeLists.txt
git commit -m "build: add countdown feature files to CMakeLists"
```

---

### Task 6: UI组件 - CountdownDialog

**Files:**
- Create: `qml/components/CountdownDialog.qml`

- [ ] **Step 6.1: 创建CountdownDialog组件**

```qml
// qml/components/CountdownDialog.qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: root
    
    property int editGoalId: -1
    property bool isEditMode: editGoalId >= 0
    
    title: isEditMode ? "编辑目标" : "添加目标"
    modal: true
    width: 480
    padding: 24
    
    signal goalSaved()
    
    function openForAdd() {
        editGoalId = -1
        nameField.text = ""
        datePicker.selectedDate = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000)
        open()
    }
    
    function openForEdit(goalId, name, targetDate) {
        editGoalId = goalId
        nameField.text = name
        datePicker.selectedDate = targetDate
        open()
    }
    
    ColumnLayout {
        anchors.fill: parent
        spacing: 16
        
        Text {
            text: "目标名称"
            font.pixelSize: 13
            font.weight: Font.Medium
            color: "#5d4e37"
        }
        
        TextField {
            id: nameField
            Layout.fillWidth: true
            placeholderText: "例如：研究生初试"
            font.pixelSize: 15
            background: Rectangle {
                color: "#fffef9"
                border.color: nameField.activeFocus ? "#d4a574" : "#e8dfc8"
                border.width: 1
                radius: 6
            }
        }
        
        Text {
            text: "目标日期"
            font.pixelSize: 13
            font.weight: Font.Medium
            color: "#5d4e37"
            Layout.topMargin: 8
        }
        
        Rectangle {
            id: datePicker
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: "#fffef9"
            border.color: "#e8dfc8"
            border.width: 1
            radius: 6
            
            property date selectedDate: new Date()
            
            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                
                Text {
                    text: Qt.formatDate(datePicker.selectedDate, "yyyy年MM月dd日")
                    font.pixelSize: 15
                    color: "#5d4e37"
                    Layout.fillWidth: true
                }
                
                Text {
                    text: "📅"
                    font.pixelSize: 16
                }
            }
            
            MouseArea {
                anchors.fill: parent
                onClicked: datePickerDialog.open()
            }
        }
    }
    
    footer: DialogButtonBox {
        Button {
            text: "取消"
            DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
            onClicked: root.reject()
        }
        
        Button {
            text: "确定"
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            enabled: nameField.text.trim().length > 0
            onClicked: {
                var success = false
                if (root.isEditMode) {
                    success = countdownService.updateGoal(
                        root.editGoalId,
                        nameField.text.trim(),
                        datePicker.selectedDate
                    )
                } else {
                    success = countdownService.addGoal(
                        nameField.text.trim(),
                        datePicker.selectedDate
                    )
                }
                
                if (success) {
                    root.goalSaved()
                    root.accept()
                }
            }
        }
    }
    
    Dialog {
        id: datePickerDialog
        title: "选择日期"
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        
        onAccepted: {
            datePicker.selectedDate = calendar.selectedDate
        }
        
        Calendar {
            id: calendar
            selectedDate: datePicker.selectedDate
        }
    }
}
```

- [ ] **Step 6.2: 提交**

```bash
git add qml/components/CountdownDialog.qml
git commit -m "feat: add CountdownDialog component"
```

---

### Task 7: UI组件 - CountdownBanner

**Files:**
- Create: `qml/components/CountdownBanner.qml`

- [ ] **Step 7.1: 创建CountdownBanner组件**

```qml
// qml/components/CountdownBanner.qml
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    
    property var primaryGoal: null
    
    signal clicked()
    signal addRequested()
    
    height: 60
    radius: 6
    
    gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "#f0e6d2" }
        GradientStop { position: 1.0; color: "#faf6ee" }
    }
    
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 3
        color: "#d4a574"
        radius: 6
    }
    
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 20
        anchors.rightMargin: 20
        spacing: 16
        
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            
            Text {
                text: root.primaryGoal ? root.primaryGoal.name : "+ 添加目标倒计时"
                font.pixelSize: 15
                font.weight: Font.Medium
                color: "#5d4e37"
            }
            
            Text {
                visible: root.primaryGoal !== null
                text: root.primaryGoal ? Qt.formatDate(root.primaryGoal.targetDate, "yyyy年MM月dd日") : ""
                font.pixelSize: 11
                color: "#6d5e47"
            }
        }
        
        ColumnLayout {
            visible: root.primaryGoal !== null
            spacing: 0
            
            Text {
                text: root.primaryGoal ? Math.abs(root.primaryGoal.daysRemaining()) : "0"
                font.pixelSize: 32
                font.weight: Font.Bold
                color: "#d4a574"
                Layout.alignment: Qt.AlignRight
            }
            
            Text {
                text: {
                    if (!root.primaryGoal) return "天"
                    var days = root.primaryGoal.daysRemaining()
                    return days >= 0 ? "天" : "已过期"
                }
                font.pixelSize: 11
                color: "#8b7355"
                Layout.alignment: Qt.AlignRight
            }
        }
    }
    
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        
        onEntered: root.scale = 1.01
        onExited: root.scale = 1.0
        
        onClicked: {
            if (root.primaryGoal) {
                root.clicked()
            } else {
                root.addRequested()
            }
        }
    }
    
    Behavior on scale {
        NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
    }
}
```

- [ ] **Step 7.2: 提交**

```bash
git add qml/components/CountdownBanner.qml
git commit -m "feat: add CountdownBanner component"
```

---

### Task 8: UI组件 - CountdownItem 和 CountdownView（精简版）

**Files:**
- Create: `qml/components/CountdownItem.qml`
- Create: `qml/views/CountdownView.qml`

由于这两个组件较复杂且涉及拖拽排序，我将提供精简版本，重点实现核心功能。

- [ ] **Step 8.1: 创建CountdownItem（精简版 - 不含拖拽）**

```qml
// qml/components/CountdownItem.qml
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    
    property int goalId: -1
    property string goalName: ""
    property date targetDate: new Date()
    property int daysRemaining: 0
    
    signal clicked()
    signal deleteRequested()
    
    height: 48
    radius: 6
    color: "#faf8f3"
    
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 12
        
        Text {
            text: root.goalName
            font.pixelSize: 15
            color: "#5d4e37"
            Layout.fillWidth: true
        }
        
        Text {
            text: {
                var days = Math.abs(root.daysRemaining)
                return root.daysRemaining >= 0 ? days + "天" : "已过期" + days + "天"
            }
            font.pixelSize: 15
            font.weight: Font.Medium
            color: "#d4a574"
        }
    }
    
    MouseArea {
        anchors.fill: parent
        onClicked: root.clicked()
    }
}
```

- [ ] **Step 8.2: 创建CountdownView（精简版）**

```qml
// qml/views/CountdownView.qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

Rectangle {
    id: root
    
    color: "#fffef9"
    
    CountdownDialog {
        id: countdownDialog
        anchors.centerIn: parent
    }
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 20
        
        RowLayout {
            Layout.fillWidth: true
            
            Text {
                text: "目标倒计时"
                font.pixelSize: 24
                font.weight: Font.Bold
                color: "#5d4e37"
                Layout.fillWidth: true
            }
            
            Button {
                text: "+"
                font.pixelSize: 20
                onClicked: countdownDialog.openForAdd()
            }
        }
        
        Rectangle {
            visible: countdownService.model.rowCount > 0
            Layout.fillWidth: true
            Layout.preferredHeight: 200
            radius: 8
            border.width: 2
            border.color: "#d4a574"
            
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#f0e6d2" }
                GradientStop { position: 1.0; color: "#faf6ee" }
            }
            
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 8
                
                Text {
                    text: countdownService.primaryGoal ? countdownService.primaryGoal.name : ""
                    font.pixelSize: 14
                    color: "#8b7355"
                    Layout.alignment: Qt.AlignHCenter
                }
                
                Text {
                    text: countdownService.primaryGoal ? Math.abs(countdownService.primaryGoal.daysRemaining()) : "0"
                    font.pixelSize: 64
                    font.weight: Font.Bold
                    color: "#d4a574"
                    Layout.alignment: Qt.AlignHCenter
                }
                
                Text {
                    text: {
                        if (!countdownService.primaryGoal) return "天"
                        var days = countdownService.primaryGoal.daysRemaining()
                        return days >= 0 ? "天" : "已过期"
                    }
                    font.pixelSize: 16
                    color: "#8b7355"
                    Layout.alignment: Qt.AlignHCenter
                }
                
                Text {
                    text: countdownService.primaryGoal ? Qt.formatDate(countdownService.primaryGoal.targetDate, "yyyy年MM月dd日") : ""
                    font.pixelSize: 13
                    color: "#6d5e47"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 16
                }
            }
            
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (countdownService.primaryGoal) {
                        countdownDialog.openForEdit(
                            countdownService.primaryGoal.id,
                            countdownService.primaryGoal.name,
                            countdownService.primaryGoal.targetDate
                        )
                    }
                }
            }
        }
        
        ListView {
            visible: countdownService.model.rowCount > 1
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12
            clip: true
            
            model: countdownService.model
            
            delegate: CountdownItem {
                visible: index > 0
                width: ListView.view.width
                goalId: model.goalId
                goalName: model.name
                targetDate: model.targetDate
                daysRemaining: model.daysRemaining
                
                onClicked: {
                    countdownDialog.openForEdit(model.goalId, model.name, model.targetDate)
                }
            }
        }
        
        Text {
            visible: countdownService.model.rowCount === 0
            text: "暂无目标倒计时\n\n点击右上角 + 添加第一个目标"
            font.pixelSize: 15
            color: "#8b7355"
            horizontalAlignment: Text.AlignHCenter
            Layout.alignment: Qt.AlignHCenter
            Layout.fillHeight: true
        }
    }
}
```

- [ ] **Step 8.3: 提交**

```bash
git add qml/components/CountdownItem.qml qml/views/CountdownView.qml
git commit -m "feat: add CountdownItem and CountdownView components"
```

---

### Task 9: 集成到主应用

**Files:**
- Modify: `src/main.cpp`
- Modify: `qml/components/Sidebar.qml`
- Modify: `qml/MainWindow.qml`
- Modify: `qml/views/TodayTaskView.qml`
- Modify: `resources/qml.qrc`

- [ ] **Step 9.1: 在main.cpp中注册CountdownService**

```cpp
// 在 src/main.cpp 中添加
#include "services/CountdownService.h"

// 在 main() 函数中，其他 setContextProperty 之后添加：
engine.rootContext()->setContextProperty(QStringLiteral("countdownService"), CountdownService::instance());
```

- [ ] **Step 9.2: 在Sidebar添加入口**

在 `qml/components/Sidebar.qml` 的"数据统计"项后添加：

```qml
SidebarItem {
    text: "目标倒计时"
    marker: "⏰"
    isActive: root.currentView === "countdown"
    onClicked: root.itemClicked("countdown")
}
```

- [ ] **Step 9.3: 在MainWindow注册视图**

在 `qml/MainWindow.qml` 的 StackLayout 中添加：

```qml
CountdownView {
    id: countdownView
}
```

在 `viewIndex()` 函数中添加：

```qml
case "countdown":
    return 5;
```

- [ ] **Step 9.4: 在TodayTaskView集成横幅**

在 `qml/views/TodayTaskView.qml` 的顶部 ColumnLayout 中添加：

```qml
CountdownBanner {
    Layout.fillWidth: true
    Layout.bottomMargin: 16
    primaryGoal: countdownService.primaryGoal
    visible: countdownService.primaryGoal !== null
    
    onClicked: {
        // 需要通过信号通知MainWindow切换视图
        // 简化版本：直接访问parent
    }
    
    onAddRequested: {
        // 打开CountdownDialog
    }
}
```

- [ ] **Step 9.5: 更新qml.qrc资源文件**

在 `resources/qml.qrc` 中添加：

```xml
<file>../qml/components/CountdownDialog.qml</file>
<file>../qml/components/CountdownBanner.qml</file>
<file>../qml/components/CountdownItem.qml</file>
<file>../qml/views/CountdownView.qml</file>
```

- [ ] **Step 9.6: 编译和运行**

Run: `cmake --build build && ./build/PomodoroTodo.app/Contents/MacOS/PomodoroTodo`

Expected: 应用启动，可以从侧边栏访问"目标倒计时"视图

- [ ] **Step 9.7: 提交**

```bash
git add src/main.cpp qml/components/Sidebar.qml qml/MainWindow.qml qml/views/TodayTaskView.qml resources/qml.qrc
git commit -m "feat: integrate countdown feature into main app"
```

---

## 验证和完成

- [ ] **最终测试**

1. 启动应用，验证无崩溃
2. 点击侧边栏"目标倒计时"，进入视图
3. 点击"+"添加第一个目标
4. 验证今日任务页顶部显示横幅
5. 添加第二个目标，验证列表显示
6. 点击目标进行编辑，验证保存成功
7. 重启应用，验证数据持久化

- [ ] **最终提交**

```bash
git add -A
git commit -m "feat: complete countdown feature implementation"
```

---

## 总结

本实施计划包含9个主要任务：

1. **Task 1**: CountdownGoal数据结构（4步）
2. **Task 2**: CountdownModel（4步）
3. **Task 3**: CountdownService（8步）
4. **Task 4**: 单元测试（5步）
5. **Task 5**: 更新CMakeLists（5步）
6. **Task 6**: CountdownDialog UI（2步）
7. **Task 7**: CountdownBanner UI（2步）
8. **Task 8**: CountdownItem + CountdownView（3步）
9. **Task 9**: 集成到主应用（7步）

**总计**: 40个执行步骤

**注意事项**:
- 本计划提供了精简版UI组件，暂不包含拖拽排序功能
- Calendar组件需要Qt 6.2+，如版本不支持需要使用简单的日期输入替代
- 所有步骤遵循TDD原则，先测试后实现
- 每个任务完成后立即提交，保持git历史清晰

