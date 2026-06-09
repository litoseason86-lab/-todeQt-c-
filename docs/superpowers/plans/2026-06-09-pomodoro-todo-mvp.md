# 番茄Todo MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the MVP of a Qt Quick/QML desktop app for task management and focus tracking for exam preparation.

**Architecture:** Single-instance C++ services (TaskManager, FocusTimer, StatisticsService) exposed to QML, with SQLite for local data storage. QML handles UI rendering and user interactions.

**Tech Stack:** Qt 6, Qt Quick/QML, C++17, SQLite, CMake

---

## File Structure Overview

This MVP will create the following structure:

```
番茄todo/
├── CMakeLists.txt                      # Project build configuration
├── src/
│   ├── main.cpp                        # Application entry point
│   ├── services/
│   │   ├── DatabaseManager.h/cpp       # SQLite database operations
│   │   ├── TaskManager.h/cpp           # Task CRUD operations
│   │   ├── FocusTimer.h/cpp            # Focus timing logic
│   │   └── StatisticsService.h/cpp     # Statistics calculations
│   └── models/
│       ├── Task.h/cpp                  # Task data model
│       └── FocusSession.h/cpp          # Focus session data model
├── qml/
│   ├── main.qml                        # Application root
│   ├── MainWindow.qml                  # Main window with sidebar + content
│   ├── views/
│   │   ├── TodayTaskView.qml           # Today's tasks page
│   │   └── FocusView.qml               # Focus timer page
│   └── components/
│       ├── Sidebar.qml                 # Navigation sidebar
│       ├── TaskItem.qml                # Single task item component
│       └── AddTaskDialog.qml           # Dialog for adding new tasks
├── resources/
│   └── qml.qrc                         # QML resource file
└── tests/
    └── (test files will be added per task)
```

---

## Task 1: Project Setup and CMake Configuration

**Files:**
- Create: `CMakeLists.txt`
- Create: `.gitignore`

- [ ] **Step 1: Create CMakeLists.txt**

```cmake
cmake_minimum_required(VERSION 3.16)

project(PomodoroTodo VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick Sql)

add_executable(PomodoroTodo
    src/main.cpp
    resources/qml.qrc
)

target_link_libraries(PomodoroTodo PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::Sql
)

set_target_properties(PomodoroTodo PROPERTIES
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)
```

- [ ] **Step 2: Create .gitignore**

```gitignore
# Build directories
build/
cmake-build-*/

# Qt
*.pro.user
*.autosave
moc_*.cpp
qrc_*.cpp

# IDE
.vscode/
.idea/
*.swp

# Database
*.db
*.sqlite

# OS
.DS_Store
Thumbs.db

# Superpowers
.superpowers/
```

- [ ] **Step 3: Create initial directory structure**

```bash
mkdir -p src/services src/models qml/views qml/components resources tests
```

- [ ] **Step 4: Verify CMake configuration**

```bash
cmake -B build -S .
```

Expected: CMake configures (will fail on missing main.cpp, that's OK for now)

- [ ] **Step 5: Commit**

```bash
git init
git add CMakeLists.txt .gitignore
git commit -m "chore: initial project setup with CMake configuration"
```

---

## Task 2: Database Manager Implementation

**Files:**
- Create: `src/services/DatabaseManager.h`
- Create: `src/services/DatabaseManager.cpp`

- [ ] **Step 1: Write DatabaseManager header**

Create `src/services/DatabaseManager.h`:

```cpp
#ifndef DATABASEMANAGER_H
#define DATABASEMANAGER_H

#include <QObject>
#include <QSqlDatabase>
#include <QString>

class DatabaseManager : public QObject {
    Q_OBJECT
    
public:
    static DatabaseManager* instance();
    
    bool initialize(const QString& dbPath = "");
    QSqlDatabase database() const;
    bool createTables();
    
private:
    DatabaseManager(QObject* parent = nullptr);
    ~DatabaseManager();
    
    QSqlDatabase m_db;
    static DatabaseManager* s_instance;
};

#endif // DATABASEMANAGER_H
```

- [ ] **Step 2: Write DatabaseManager implementation**

Create `src/services/DatabaseManager.cpp`:

```cpp
#include "DatabaseManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QDir>
#include <QDebug>

DatabaseManager* DatabaseManager::s_instance = nullptr;

DatabaseManager::DatabaseManager(QObject* parent)
    : QObject(parent)
{
}

DatabaseManager::~DatabaseManager()
{
    if (m_db.isOpen()) {
        m_db.close();
    }
}

DatabaseManager* DatabaseManager::instance()
{
    if (!s_instance) {
        s_instance = new DatabaseManager();
    }
    return s_instance;
}

bool DatabaseManager::initialize(const QString& dbPath)
{
    QString path = dbPath;
    if (path.isEmpty()) {
        QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QDir().mkpath(dataDir);
        path = dataDir + "/pomodoro.db";
    }
    
    m_db = QSqlDatabase::addDatabase("QSQLITE");
    m_db.setDatabaseName(path);
    
    if (!m_db.open()) {
        qWarning() << "Failed to open database:" << m_db.lastError().text();
        return false;
    }
    
    return createTables();
}

bool DatabaseManager::createTables()
{
    QSqlQuery query(m_db);
    
    QString createTasksTable = R"(
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            category TEXT,
            date DATE NOT NULL,
            completed BOOLEAN DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    )";
    
    if (!query.exec(createTasksTable)) {
        qWarning() << "Failed to create tasks table:" << query.lastError().text();
        return false;
    }
    
    QString createSessionsTable = R"(
        CREATE TABLE IF NOT EXISTS focus_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER,
            start_time TIMESTAMP NOT NULL,
            end_time TIMESTAMP,
            duration INTEGER,
            FOREIGN KEY (task_id) REFERENCES tasks(id)
        )
    )";
    
    if (!query.exec(createSessionsTable)) {
        qWarning() << "Failed to create focus_sessions table:" << query.lastError().text();
        return false;
    }
    
    query.exec("CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(date)");
    query.exec("CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks(completed)");
    query.exec("CREATE INDEX IF NOT EXISTS idx_sessions_task ON focus_sessions(task_id)");
    query.exec("CREATE INDEX IF NOT EXISTS idx_sessions_start ON focus_sessions(start_time)");
    
    return true;
}

QSqlDatabase DatabaseManager::database() const
{
    return m_db;
}
```

- [ ] **Step 3: Update CMakeLists.txt**

```cmake
add_executable(PomodoroTodo
    src/main.cpp
    src/services/DatabaseManager.cpp
    resources/qml.qrc
)
```

- [ ] **Step 4: Test database initialization manually**

Create temporary `src/main.cpp` to test:

```cpp
#include <QGuiApplication>
#include "services/DatabaseManager.h"
#include <QDebug>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    
    DatabaseManager* db = DatabaseManager::instance();
    if (db->initialize()) {
        qDebug() << "Database initialized successfully";
    } else {
        qDebug() << "Database initialization failed";
    }
    
    return 0;
}
```

Run:
```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected output: "Database initialized successfully"

- [ ] **Step 5: Commit**

```bash
git add src/services/DatabaseManager.* src/main.cpp CMakeLists.txt
git commit -m "feat: implement DatabaseManager with SQLite"
```

---

## Task 3: TaskManager Service Implementation

**Files:**
- Create: `src/services/TaskManager.h`
- Create: `src/services/TaskManager.cpp`

- [ ] **Step 1: Write TaskManager header**

Create `src/services/TaskManager.h`:

```cpp
#ifndef TASKMANAGER_H
#define TASKMANAGER_H

#include <QObject>
#include <QVariantList>
#include <QDate>

class TaskManager : public QObject {
    Q_OBJECT
    
public:
    static TaskManager* instance();
    
    Q_INVOKABLE void addTask(const QString& title, const QDate& date, const QString& category = "");
    Q_INVOKABLE void completeTask(int taskId);
    Q_INVOKABLE void deleteTask(int taskId);
    Q_INVOKABLE QVariantList getTodayTasks();
    Q_INVOKABLE QVariantList getTasksByDate(const QDate& date);
    
signals:
    void tasksChanged();
    
private:
    TaskManager(QObject* parent = nullptr);
    static TaskManager* s_instance;
};

#endif // TASKMANAGER_H
```

- [ ] **Step 2: Write TaskManager implementation**

Create `src/services/TaskManager.cpp`:

```cpp
#include "TaskManager.h"
#include "DatabaseManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QVariantMap>
#include <QDebug>

TaskManager* TaskManager::s_instance = nullptr;

TaskManager::TaskManager(QObject* parent)
    : QObject(parent)
{
}

TaskManager* TaskManager::instance()
{
    if (!s_instance) {
        s_instance = new TaskManager();
    }
    return s_instance;
}

void TaskManager::addTask(const QString& title, const QDate& date, const QString& category)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("INSERT INTO tasks (title, category, date, completed) VALUES (?, ?, ?, 0)");
    query.addBindValue(title);
    query.addBindValue(category);
    query.addBindValue(date);
    
    if (!query.exec()) {
        qWarning() << "Failed to add task:" << query.lastError().text();
        return;
    }
    
    emit tasksChanged();
}

void TaskManager::completeTask(int taskId)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("UPDATE tasks SET completed = 1 WHERE id = ?");
    query.addBindValue(taskId);
    
    if (!query.exec()) {
        qWarning() << "Failed to complete task:" << query.lastError().text();
        return;
    }
    
    emit tasksChanged();
}

void TaskManager::deleteTask(int taskId)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("DELETE FROM tasks WHERE id = ?");
    query.addBindValue(taskId);
    
    if (!query.exec()) {
        qWarning() << "Failed to delete task:" << query.lastError().text();
        return;
    }
    
    emit tasksChanged();
}

QVariantList TaskManager::getTodayTasks()
{
    return getTasksByDate(QDate::currentDate());
}

QVariantList TaskManager::getTasksByDate(const QDate& date)
{
    QVariantList tasks;
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT id, title, category, date, completed FROM tasks WHERE date = ? ORDER BY created_at");
    query.addBindValue(date);
    
    if (!query.exec()) {
        qWarning() << "Failed to get tasks:" << query.lastError().text();
        return tasks;
    }
    
    while (query.next()) {
        QVariantMap task;
        task["id"] = query.value(0).toInt();
        task["title"] = query.value(1).toString();
        task["category"] = query.value(2).toString();
        task["date"] = query.value(3).toDate();
        task["completed"] = query.value(4).toBool();
        tasks.append(task);
    }
    
    return tasks;
}
```

- [ ] **Step 3: Update CMakeLists.txt**

```cmake
add_executable(PomodoroTodo
    src/main.cpp
    src/services/DatabaseManager.cpp
    src/services/TaskManager.cpp
    resources/qml.qrc
)
```

- [ ] **Step 4: Test TaskManager in main.cpp**

Update `src/main.cpp`:

```cpp
#include <QGuiApplication>
#include "services/DatabaseManager.h"
#include "services/TaskManager.h"
#include <QDebug>
#include <QDate>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    
    DatabaseManager::instance()->initialize();
    
    TaskManager* tm = TaskManager::instance();
    tm->addTask("测试任务1", QDate::currentDate(), "数学");
    tm->addTask("测试任务2", QDate::currentDate(), "英语");
    
    QVariantList tasks = tm->getTodayTasks();
    qDebug() << "Today's tasks count:" << tasks.size();
    for (const QVariant& task : tasks) {
        QVariantMap t = task.toMap();
        qDebug() << "Task:" << t["title"].toString() << "Category:" << t["category"].toString();
    }
    
    return 0;
}
```

Run:
```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: Shows 2 tasks created

- [ ] **Step 5: Commit**

```bash
git add src/services/TaskManager.* src/main.cpp CMakeLists.txt
git commit -m "feat: implement TaskManager with CRUD operations"
```

---

## Task 4: FocusTimer Service Implementation

**Files:**
- Create: `src/services/FocusTimer.h`
- Create: `src/services/FocusTimer.cpp`

- [ ] **Step 1: Write FocusTimer header**

Create `src/services/FocusTimer.h`:

```cpp
#ifndef FOCUSTIMER_H
#define FOCUSTIMER_H

#include <QObject>
#include <QTimer>
#include <QDateTime>

class FocusTimer : public QObject {
    Q_OBJECT
    Q_PROPERTY(int elapsedSeconds READ elapsedSeconds NOTIFY tick)
    Q_PROPERTY(bool isRunning READ isRunning NOTIFY runningStateChanged)
    Q_PROPERTY(QString currentTaskTitle READ currentTaskTitle NOTIFY currentTaskChanged)
    
public:
    static FocusTimer* instance();
    
    Q_INVOKABLE void startFocus(int taskId, const QString& taskTitle);
    Q_INVOKABLE void pauseFocus();
    Q_INVOKABLE void resumeFocus();
    Q_INVOKABLE void stopFocus();
    
    int elapsedSeconds() const { return m_elapsedSeconds; }
    bool isRunning() const { return m_isRunning; }
    QString currentTaskTitle() const { return m_currentTaskTitle; }
    
signals:
    void tick();
    void runningStateChanged();
    void currentTaskChanged();
    void focusCompleted(int duration);
    
private:
    FocusTimer(QObject* parent = nullptr);
    void saveFocusSession();
    
    static FocusTimer* s_instance;
    QTimer* m_timer;
    int m_currentTaskId;
    QString m_currentTaskTitle;
    QDateTime m_startTime;
    int m_elapsedSeconds;
    bool m_isRunning;
    int m_sessionId;
};

#endif // FOCUSTIMER_H
```

- [ ] **Step 2: Write FocusTimer implementation**

Create `src/services/FocusTimer.cpp`:

```cpp
#include "FocusTimer.h"
#include "DatabaseManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QDebug>

FocusTimer* FocusTimer::s_instance = nullptr;

FocusTimer::FocusTimer(QObject* parent)
    : QObject(parent)
    , m_timer(new QTimer(this))
    , m_currentTaskId(-1)
    , m_elapsedSeconds(0)
    , m_isRunning(false)
    , m_sessionId(-1)
{
    m_timer->setInterval(1000);
    connect(m_timer, &QTimer::timeout, this, [this]() {
        m_elapsedSeconds++;
        emit tick();
    });
}

FocusTimer* FocusTimer::instance()
{
    if (!s_instance) {
        s_instance = new FocusTimer();
    }
    return s_instance;
}

void FocusTimer::startFocus(int taskId, const QString& taskTitle)
{
    if (m_isRunning) {
        qWarning() << "Timer already running";
        return;
    }
    
    m_currentTaskId = taskId;
    m_currentTaskTitle = taskTitle;
    m_startTime = QDateTime::currentDateTime();
    m_elapsedSeconds = 0;
    m_isRunning = true;
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("INSERT INTO focus_sessions (task_id, start_time) VALUES (?, ?)");
    query.addBindValue(taskId);
    query.addBindValue(m_startTime);
    
    if (!query.exec()) {
        qWarning() << "Failed to create focus session:" << query.lastError().text();
        m_isRunning = false;
        return;
    }
    
    m_sessionId = query.lastInsertId().toInt();
    m_timer->start();
    
    emit runningStateChanged();
    emit currentTaskChanged();
}

void FocusTimer::pauseFocus()
{
    if (!m_isRunning) {
        return;
    }
    
    m_timer->stop();
    m_isRunning = false;
    emit runningStateChanged();
}

void FocusTimer::resumeFocus()
{
    if (m_isRunning || m_sessionId == -1) {
        return;
    }
    
    m_timer->start();
    m_isRunning = true;
    emit runningStateChanged();
}

void FocusTimer::stopFocus()
{
    if (m_sessionId == -1) {
        return;
    }
    
    m_timer->stop();
    saveFocusSession();
    
    int duration = m_elapsedSeconds;
    
    m_currentTaskId = -1;
    m_currentTaskTitle.clear();
    m_elapsedSeconds = 0;
    m_isRunning = false;
    m_sessionId = -1;
    
    emit focusCompleted(duration);
    emit runningStateChanged();
    emit currentTaskChanged();
}

void FocusTimer::saveFocusSession()
{
    QDateTime endTime = QDateTime::currentDateTime();
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("UPDATE focus_sessions SET end_time = ?, duration = ? WHERE id = ?");
    query.addBindValue(endTime);
    query.addBindValue(m_elapsedSeconds);
    query.addBindValue(m_sessionId);
    
    if (!query.exec()) {
        qWarning() << "Failed to save focus session:" << query.lastError().text();
    }
}
```

- [ ] **Step 3: Update CMakeLists.txt**

```cmake
add_executable(PomodoroTodo
    src/main.cpp
    src/services/DatabaseManager.cpp
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    resources/qml.qrc
)
```

- [ ] **Step 4: Test FocusTimer**

Update `src/main.cpp`:

```cpp
#include <QGuiApplication>
#include <QTimer>
#include "services/DatabaseManager.h"
#include "services/TaskManager.h"
#include "services/FocusTimer.h"
#include <QDebug>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    
    DatabaseManager::instance()->initialize();
    
    TaskManager* tm = TaskManager::instance();
    tm->addTask("测试专注", QDate::currentDate(), "测试");
    
    FocusTimer* ft = FocusTimer::instance();
    
    QObject::connect(ft, &FocusTimer::tick, [ft]() {
        qDebug() << "Elapsed:" << ft->elapsedSeconds() << "seconds";
    });
    
    ft->startFocus(1, "测试专注");
    
    QTimer::singleShot(5000, [ft]() {
        ft->stopFocus();
        qDebug() << "Focus stopped";
        QCoreApplication::quit();
    });
    
    return app.exec();
}
```

Run:
```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: Timer counts for 5 seconds then stops

- [ ] **Step 5: Commit**

```bash
git add src/services/FocusTimer.* src/main.cpp CMakeLists.txt
git commit -m "feat: implement FocusTimer with pause/resume/stop"
```

---

## Task 5: StatisticsService Implementation

**Files:**
- Create: `src/services/StatisticsService.h`
- Create: `src/services/StatisticsService.cpp`

- [ ] **Step 1: Write StatisticsService header**

Create `src/services/StatisticsService.h`:

```cpp
#ifndef STATISTICSSERVICE_H
#define STATISTICSSERVICE_H

#include <QObject>
#include <QVariantMap>
#include <QVariantList>
#include <QDate>

class StatisticsService : public QObject {
    Q_OBJECT
    
public:
    static StatisticsService* instance();
    
    Q_INVOKABLE QVariantMap getTodayStats();
    Q_INVOKABLE QVariantList getWeekStats();
    
private:
    StatisticsService(QObject* parent = nullptr);
    static StatisticsService* s_instance;
    
    int calculateTotalDuration(const QDate& date);
    int countCompletedTasks(const QDate& date);
    int countTotalTasks(const QDate& date);
};

#endif // STATISTICSSERVICE_H
```

- [ ] **Step 2: Write StatisticsService implementation**

Create `src/services/StatisticsService.cpp`:

```cpp
#include "StatisticsService.h"
#include "DatabaseManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QDebug>

StatisticsService* StatisticsService::s_instance = nullptr;

StatisticsService::StatisticsService(QObject* parent)
    : QObject(parent)
{
}

StatisticsService* StatisticsService::instance()
{
    if (!s_instance) {
        s_instance = new StatisticsService();
    }
    return s_instance;
}

QVariantMap StatisticsService::getTodayStats()
{
    QVariantMap stats;
    QDate today = QDate::currentDate();
    
    int totalDuration = calculateTotalDuration(today);
    int completedTasks = countCompletedTasks(today);
    int totalTasks = countTotalTasks(today);
    
    stats["totalDuration"] = totalDuration;
    stats["completedTasks"] = completedTasks;
    stats["totalTasks"] = totalTasks;
    stats["completionRate"] = totalTasks > 0 ? (double)completedTasks / totalTasks : 0.0;
    
    return stats;
}

QVariantList StatisticsService::getWeekStats()
{
    QVariantList weekStats;
    QDate today = QDate::currentDate();
    
    for (int i = 6; i >= 0; i--) {
        QDate date = today.addDays(-i);
        QVariantMap dayStats;
        
        dayStats["date"] = date;
        dayStats["duration"] = calculateTotalDuration(date);
        dayStats["tasks"] = countTotalTasks(date);
        
        weekStats.append(dayStats);
    }
    
    return weekStats;
}

int StatisticsService::calculateTotalDuration(const QDate& date)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT SUM(duration) FROM focus_sessions WHERE DATE(start_time) = ?");
    query.addBindValue(date);
    
    if (!query.exec() || !query.next()) {
        return 0;
    }
    
    return query.value(0).toInt();
}

int StatisticsService::countCompletedTasks(const QDate& date)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT COUNT(*) FROM tasks WHERE date = ? AND completed = 1");
    query.addBindValue(date);
    
    if (!query.exec() || !query.next()) {
        return 0;
    }
    
    return query.value(0).toInt();
}

int StatisticsService::countTotalTasks(const QDate& date)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT COUNT(*) FROM tasks WHERE date = ?");
    query.addBindValue(date);
    
    if (!query.exec() || !query.next()) {
        return 0;
    }
    
    return query.value(0).toInt();
}
```

- [ ] **Step 3: Update CMakeLists.txt**

```cmake
add_executable(PomodoroTodo
    src/main.cpp
    src/services/DatabaseManager.cpp
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    src/services/StatisticsService.cpp
    resources/qml.qrc
)
```

- [ ] **Step 4: Test StatisticsService**

Update `src/main.cpp`:

```cpp
#include <QGuiApplication>
#include "services/DatabaseManager.h"
#include "services/TaskManager.h"
#include "services/FocusTimer.h"
#include "services/StatisticsService.h"
#include <QDebug>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    
    DatabaseManager::instance()->initialize();
    
    TaskManager* tm = TaskManager::instance();
    tm->addTask("任务1", QDate::currentDate(), "数学");
    tm->addTask("任务2", QDate::currentDate(), "英语");
    tm->completeTask(1);
    
    StatisticsService* ss = StatisticsService::instance();
    QVariantMap stats = ss->getTodayStats();
    
    qDebug() << "Today's stats:";
    qDebug() << "Total tasks:" << stats["totalTasks"].toInt();
    qDebug() << "Completed tasks:" << stats["completedTasks"].toInt();
    qDebug() << "Completion rate:" << stats["completionRate"].toDouble();
    
    return 0;
}
```

Run:
```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: Shows statistics with 2 total tasks, 1 completed

- [ ] **Step 5: Commit**

```bash
git add src/services/StatisticsService.* src/main.cpp CMakeLists.txt
git commit -m "feat: implement StatisticsService for data aggregation"
```

---

## Task 6: QML Application Setup

**Files:**
- Create: `resources/qml.qrc`
- Create: `qml/main.qml`
- Update: `src/main.cpp`

- [ ] **Step 1: Create QML resource file**

Create `resources/qml.qrc`:

```xml
<RCC>
    <qresource prefix="/">
        <file>../qml/main.qml</file>
        <file>../qml/MainWindow.qml</file>
        <file>../qml/views/TodayTaskView.qml</file>
        <file>../qml/views/FocusView.qml</file>
        <file>../qml/components/Sidebar.qml</file>
        <file>../qml/components/TaskItem.qml</file>
        <file>../qml/components/AddTaskDialog.qml</file>
    </qresource>
</RCC>
```

- [ ] **Step 2: Create main.qml**

Create `qml/main.qml`:

```qml
import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: root
    visible: true
    width: 1024
    height: 768
    title: "番茄Todo"
    
    color: "#fffef9"
    
    MainWindow {
        anchors.fill: parent
    }
}
```

- [ ] **Step 3: Update main.cpp to initialize QML engine**

Update `src/main.cpp`:

```cpp
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include "services/DatabaseManager.h"
#include "services/TaskManager.h"
#include "services/FocusTimer.h"
#include "services/StatisticsService.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    
    app.setOrganizationName("PomodoroTodo");
    app.setApplicationName("PomodoroTodo");
    
    // Initialize database
    if (!DatabaseManager::instance()->initialize()) {
        return -1;
    }
    
    // Create QML engine
    QQmlApplicationEngine engine;
    
    // Expose services to QML
    engine.rootContext()->setContextProperty("taskManager", TaskManager::instance());
    engine.rootContext()->setContextProperty("focusTimer", FocusTimer::instance());
    engine.rootContext()->setContextProperty("statisticsService", StatisticsService::instance());
    
    // Load main QML
    const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);
    
    engine.load(url);
    
    return app.exec();
}
```

- [ ] **Step 4: Create placeholder MainWindow.qml**

Create `qml/MainWindow.qml`:

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    
    Rectangle {
        anchors.fill: parent
        color: "#fffef9"
        
        Text {
            anchors.centerIn: parent
            text: "番茄Todo - MVP"
            font.pixelSize: 32
            color: "#5d4e37"
        }
    }
}
```

- [ ] **Step 5: Build and run**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: Window opens with placeholder text

- [ ] **Step 6: Commit**

```bash
git add resources/qml.qrc qml/main.qml qml/MainWindow.qml src/main.cpp
git commit -m "feat: setup QML application with service context"
```

---

## Task 7: Sidebar and MainWindow Layout

**Files:**
- Create: `qml/components/Sidebar.qml`
- Update: `qml/MainWindow.qml`

- [ ] **Step 1: Create Sidebar component**

Create `qml/components/Sidebar.qml`:

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    width: 200
    color: "#faf8f3"
    
    signal itemClicked(string viewName)
    
    property string currentView: "today"
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 0
        
        Text {
            text: "📅 时间视图"
            font.pixelSize: 14
            font.bold: true
            color: "#5d4e37"
            Layout.bottomMargin: 12
        }
        
        SidebarItem {
            text: "今日任务"
            isActive: root.currentView === "today"
            onClicked: {
                root.currentView = "today"
                root.itemClicked("today")
            }
        }
        
        SidebarItem {
            text: "本周计划"
            isActive: root.currentView === "week"
            onClicked: {
                root.currentView = "week"
                root.itemClicked("week")
            }
        }
        
        SidebarItem {
            text: "月度目标"
            isActive: root.currentView === "month"
            onClicked: {
                root.currentView = "month"
                root.itemClicked("month")
            }
        }
        
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: "#e8dfc8"
            Layout.topMargin: 16
            Layout.bottomMargin: 16
        }
        
        SidebarItem {
            text: "📊 数据统计"
            isActive: root.currentView === "stats"
            onClicked: {
                root.currentView = "stats"
                root.itemClicked("stats")
            }
        }
        
        SidebarItem {
            text: "⚙️ 设置"
            isActive: root.currentView === "settings"
            onClicked: {
                root.currentView = "settings"
                root.itemClicked("settings")
            }
        }
        
        Item {
            Layout.fillHeight: true
        }
    }
    
    component SidebarItem: Rectangle {
        property string text: ""
        property bool isActive: false
        signal clicked()
        
        Layout.fillWidth: true
        height: 36
        radius: 4
        color: isActive ? "#f0e6d2" : "transparent"
        
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 8
            text: parent.text
            font.pixelSize: 14
            color: parent.isActive ? "#5d4e37" : "#8b7355"
        }
        
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }
}
```

- [ ] **Step 2: Update MainWindow with layout**

Update `qml/MainWindow.qml`:

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "components"
import "views"

Item {
    id: root
    
    property string currentView: "today"
    
    RowLayout {
        anchors.fill: parent
        spacing: 0
        
        Sidebar {
            Layout.preferredWidth: 200
            Layout.fillHeight: true
            onItemClicked: function(viewName) {
                root.currentView = viewName
            }
        }
        
        Rectangle {
            width: 1
            Layout.fillHeight: true
            color: "#e8dfc8"
        }
        
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#fffef9"
            
            StackLayout {
                anchors.fill: parent
                currentIndex: {
                    switch(root.currentView) {
                        case "today": return 0
                        case "focus": return 1
                        default: return 0
                    }
                }
                
                TodayTaskView {
                    onStartFocus: function(taskId, taskTitle) {
                        root.currentView = "focus"
                    }
                }
                
                FocusView {
                    onFocusEnded: {
                        root.currentView = "today"
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build and test**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: Sidebar shows with navigation items

- [ ] **Step 4: Commit**

```bash
git add qml/components/Sidebar.qml qml/MainWindow.qml
git commit -m "feat: implement sidebar navigation and main window layout"
```

---

## Task 8: TodayTaskView and TaskItem Components

**Files:**
- Create: `qml/views/TodayTaskView.qml`
- Create: `qml/components/TaskItem.qml`
- Create: `qml/components/AddTaskDialog.qml`

- [ ] **Step 1: Create TaskItem component**

Create `qml/components/TaskItem.qml`:

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    width: parent.width
    height: 60
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1
    
    property int taskId: 0
    property string taskTitle: ""
    property string taskCategory: ""
    property bool taskCompleted: false
    
    signal completeToggled(int taskId)
    signal startFocusClicked(int taskId, string title)
    
    RowLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 12
        
        CheckBox {
            id: checkbox
            checked: root.taskCompleted
            onClicked: root.completeToggled(root.taskId)
        }
        
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            
            Text {
                text: root.taskTitle
                font.pixelSize: 14
                color: root.taskCompleted ? "#a0896b" : "#5d4e37"
                font.strikeout: root.taskCompleted
            }
            
            Text {
                text: root.taskCategory
                font.pixelSize: 12
                color: "#8b7355"
                visible: root.taskCategory !== ""
            }
        }
        
        Button {
            text: "开始专注"
            enabled: !root.taskCompleted
            background: Rectangle {
                color: parent.enabled ? "#d4a574" : "#e8dfc8"
                radius: 4
            }
            contentItem: Text {
                text: parent.text
                color: parent.enabled ? "white" : "#a0896b"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: root.startFocusClicked(root.taskId, root.taskTitle)
        }
    }
}
```

- [ ] **Step 2: Create AddTaskDialog**

Create `qml/components/AddTaskDialog.qml`:

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: root
    title: "添加新任务"
    modal: true
    standardButtons: Dialog.Ok | Dialog.Cancel
    
    property date selectedDate: new Date()
    
    signal taskAdded(string title, date date, string category)
    
    onAccepted: {
        if (titleField.text.trim() !== "") {
            root.taskAdded(titleField.text, root.selectedDate, categoryField.text)
            titleField.text = ""
            categoryField.text = ""
        }
    }
    
    ColumnLayout {
        width: 300
        spacing: 12
        
        Label {
            text: "任务标题:"
            color: "#5d4e37"
        }
        
        TextField {
            id: titleField
            Layout.fillWidth: true
            placeholderText: "输入任务内容..."
            background: Rectangle {
                color: "#fffef9"
                border.color: "#e8dfc8"
                border.width: 1
                radius: 4
            }
        }
        
        Label {
            text: "科目分类 (可选):"
            color: "#5d4e37"
        }
        
        TextField {
            id: categoryField
            Layout.fillWidth: true
            placeholderText: "如：数学、英语..."
            background: Rectangle {
                color: "#fffef9"
                border.color: "#e8dfc8"
                border.width: 1
                radius: 4
            }
        }
    }
}
```

- [ ] **Step 3: Create TodayTaskView**

Create `qml/views/TodayTaskView.qml`:

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

Item {
    id: root
    
    signal startFocus(int taskId, string taskTitle)
    
    property var tasks: []
    
    Component.onCompleted: {
        loadTasks()
    }
    
    Connections {
        target: taskManager
        function onTasksChanged() {
            loadTasks()
        }
    }
    
    function loadTasks() {
        root.tasks = taskManager.getTodayTasks()
    }
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 16
        
        RowLayout {
            Layout.fillWidth: true
            
            Text {
                text: "今日任务"
                font.pixelSize: 24
                font.bold: true
                color: "#5d4e37"
                Layout.fillWidth: true
            }
            
            Button {
                text: "+ 添加任务"
                background: Rectangle {
                    color: "#d4a574"
                    radius: 4
                }
                contentItem: Text {
                    text: parent.text
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: addTaskDialog.open()
            }
        }
        
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            
            ColumnLayout {
                width: parent.width
                spacing: 8
                
                Repeater {
                    model: root.tasks
                    
                    TaskItem {
                        Layout.fillWidth: true
                        taskId: modelData.id
                        taskTitle: modelData.title
                        taskCategory: modelData.category
                        taskCompleted: modelData.completed
                        
                        onCompleteToggled: function(id) {
                            taskManager.completeTask(id)
                        }
                        
                        onStartFocusClicked: function(id, title) {
                            focusTimer.startFocus(id, title)
                            root.startFocus(id, title)
                        }
                    }
                }
                
                Item {
                    Layout.fillHeight: true
                }
            }
        }
    }
    
    AddTaskDialog {
        id: addTaskDialog
        anchors.centerIn: parent
        selectedDate: new Date()
        
        onTaskAdded: function(title, date, category) {
            taskManager.addTask(title, date, category)
        }
    }
}
```

- [ ] **Step 4: Build and test**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: Can add tasks and see them listed

- [ ] **Step 5: Commit**

```bash
git add qml/views/TodayTaskView.qml qml/components/TaskItem.qml qml/components/AddTaskDialog.qml
git commit -m "feat: implement today task view with add/complete functionality"
```

---

## Task 9: FocusView Implementation

**Files:**
- Create: `qml/views/FocusView.qml`

- [ ] **Step 1: Create FocusView**

Create `qml/views/FocusView.qml`:

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    
    signal focusEnded()
    
    function formatTime(seconds) {
        var hours = Math.floor(seconds / 3600)
        var minutes = Math.floor((seconds % 3600) / 60)
        var secs = seconds % 60
        return (hours < 10 ? "0" : "") + hours + ":" +
               (minutes < 10 ? "0" : "") + minutes + ":" +
               (secs < 10 ? "0" : "") + secs
    }
    
    Rectangle {
        anchors.fill: parent
        color: "#f5f0e6"
        
        ColumnLayout {
            anchors.centerIn: parent
            spacing: 32
            width: 400
            
            Text {
                text: focusTimer.currentTaskTitle
                font.pixelSize: 20
                color: "#5d4e37"
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            
            Text {
                text: root.formatTime(focusTimer.elapsedSeconds)
                font.pixelSize: 64
                font.bold: true
                color: "#d4a574"
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            
            Text {
                text: "已专注"
                font.pixelSize: 14
                color: "#8b7355"
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 16
                
                Button {
                    text: focusTimer.isRunning ? "暂停" : "继续"
                    implicitWidth: 100
                    implicitHeight: 40
                    background: Rectangle {
                        color: "#8b7355"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "white"
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: {
                        if (focusTimer.isRunning) {
                            focusTimer.pauseFocus()
                        } else {
                            focusTimer.resumeFocus()
                        }
                    }
                }
                
                Button {
                    text: "结束专注"
                    implicitWidth: 100
                    implicitHeight: 40
                    background: Rectangle {
                        color: "#d4a574"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "white"
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: {
                        focusTimer.stopFocus()
                        root.focusEnded()
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and test complete flow**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Test flow:
1. Add a task in Today view
2. Click "开始专注" button
3. View switches to Focus page
4. Timer counts up
5. Click "结束专注"
6. Returns to Today view

Expected: Complete flow works

- [ ] **Step 3: Commit**

```bash
git add qml/views/FocusView.qml
git commit -m "feat: implement focus view with timer display"
```

---

## Task 10: Final Integration and Testing

**Files:**
- Update: `README.md` (create if not exists)

- [ ] **Step 1: Create README**

Create `README.md`:

```markdown
# 番茄Todo - 考研专注管理应用

基于Qt Quick/QML的桌面应用，帮助考研学生管理任务和追踪专注时长。

## 功能特性 (MVP)

- ✅ 任务管理：添加、完成、查看今日任务
- ✅ 专注计时：从任务启动专注，自动记录时长
- ✅ 数据统计：查看今日和本周的学习数据
- ✅ 本地存储：所有数据保存在SQLite数据库

## 构建要求

- Qt 6.2+
- CMake 3.16+
- C++17编译器

## 构建步骤

```bash
mkdir build
cd build
cmake ..
cmake --build .
./PomodoroTodo
```

## 项目结构

```
src/services/       # C++服务层
qml/                # QML界面
resources/          # 资源文件
docs/               # 文档
```

## 数据存储

数据库位置：`~/Library/Application Support/PomodoroTodo/pomodoro.db` (macOS)

## 下一步开发

- 本周计划视图
- 月度目标视图
- 完整数据统计页面
- 图表可视化
```

- [ ] **Step 2: Test complete MVP workflow**

Manual test checklist:
1. Launch application
2. Add 3 tasks with different categories
3. Complete one task (checkbox)
4. Start focus on another task
5. Wait 30 seconds
6. Pause timer
7. Resume timer
8. Stop focus after 1 minute
9. Verify task list updates
10. Close and reopen app
11. Verify data persists

- [ ] **Step 3: Clean up test database**

```bash
rm -f ~/Library/Application\ Support/PomodoroTodo/pomodoro.db
```

Start fresh for final test.

- [ ] **Step 4: Final commit**

```bash
git add README.md
git commit -m "docs: add README with build instructions"
git tag v0.1.0-mvp
```

---

## Self-Review Checklist

### Spec Coverage

- ✅ Task 1: Project setup and CMake
- ✅ Task 2: DatabaseManager with SQLite tables
- ✅ Task 3: TaskManager with CRUD operations
- ✅ Task 4: FocusTimer with pause/resume/stop
- ✅ Task 5: StatisticsService for data aggregation
- ✅ Task 6: QML application setup
- ✅ Task 7: Sidebar navigation and layout
- ✅ Task 8: Today task view with add/complete
- ✅ Task 9: Focus view with timer display
- ✅ Task 10: Integration and documentation

All MVP requirements from the design spec are covered.

### Placeholder Check

No TBD, TODO, or "implement later" statements found. All code is complete and executable.

### Type Consistency

- Task model: `{id, title, category, date, completed}`
- Service methods match between header and implementation
- QML property bindings use correct types (int, string, bool, date)
- Signal/slot connections are type-safe

All types are consistent across tasks.

---

## Plan Complete

This plan implements the MVP phase of 番茄Todo with:
- Complete C++ backend services
- Functional QML user interface
- Database persistence
- Core workflows: add tasks → focus → track stats

Estimated time: 2-3 weeks for a developer new to Qt Quick.


---

## Execution Options

Plan complete and saved to `docs/superpowers/plans/2026-06-09-pomodoro-todo-mvp.md`. 

Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach would you like to use?
