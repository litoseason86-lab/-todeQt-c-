#include <QCoreApplication>
#include <QDate>
#include <QDir>
#include <QFile>
#include <QJSEngine>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QElapsedTimer>
#include <QSettings>
#include <QSet>
#include <QTemporaryDir>
#include <QTimeZone>
#include <QMetaProperty>
#include <QTimer>
#include <QtTest>

#include <memory>
#include <utility>
#include <vector>

#include "../src/services/AppSettings.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/LogicalDayService.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/ExportService.h"
#include "../src/services/FocusHistoryService.h"
#include "../src/services/FocusSessionRules.h"
// FocusTimer 声明了 friend class ServiceTests，测试可直接访问内部时钟状态。
#include "../src/services/FocusTimer.h"
#include "../src/services/MonotonicClock.h"
#include "../src/services/RoutineManager.h"
#include "../src/services/RoutineRules.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/SyncSchema.h"
#include "../src/services/TaskManager.h"

namespace {
constexpr int kTestMinimumValidDurationSeconds = 3 * 60;

// 迁移用例拿当前代码建好的库「退回」旧版本（删列、换表）。真实的旧库里没有同步触发器，
// 而触发器引用着这些列和表，SQLite 会因此拒绝删列、改表名。先拆掉，库才像真的旧库。
bool dropSyncTriggers(const QSqlDatabase& db)
{
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("SELECT name FROM sqlite_master WHERE type = 'trigger'"))) {
        return false;
    }
    QStringList names;
    while (query.next()) {
        if (SyncSchema::isSyncTriggerName(query.value(0).toString())) {
            names.append(query.value(0).toString());
        }
    }
    query.finish();
    for (const QString& name : names) {
        if (!query.exec(QStringLiteral("DROP TRIGGER \"%1\"").arg(name))) {
            return false;
        }
    }
    return true;
}

QString dateTimeText(const QDate& date, const QString& time = QStringLiteral("12:00:00"))
{
    return QStringLiteral("%1T%2").arg(date.toString(Qt::ISODate), time);
}

int insertTaskRow(const QString& title,
                  const QDate& date,
                  const QString& category = QString(),
                  bool completed = false,
                  const QString& createdAt = QString())
{
    // 测试直接插入数据库，绕开服务层校验，方便构造边界数据。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, date, completed, created_at) "
        "VALUES (:title, :category, :date, :completed, :createdAt)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":category"), category);
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":createdAt"),
                    createdAt.isEmpty() ? dateTimeText(date) : createdAt);

    if (!query.exec()) {
        qWarning() << "Failed to insert test task:" << query.lastError().text();
        return -1;
    }

    return query.lastInsertId().toInt();
}

bool insertFocusSessionRow(int taskId, const QDate& date, int duration)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, pomodoro_completed) "
        "VALUES (:taskId, :startTime, :endTime, :duration, :pomodoroCompleted)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, QStringLiteral("12:30:00")));
    query.bindValue(QStringLiteral(":duration"), duration);
    query.bindValue(QStringLiteral(":pomodoroCompleted"),
                    duration >= kTestMinimumValidDurationSeconds ? 1 : 0);

    if (!query.exec()) {
        qWarning() << "Failed to insert test focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

bool insertFocusSessionRowWithMode(int taskId, const QDate& date, int duration, int mode)
{
    // 显式写入模式：mode=1 为番茄工作段，mode=0 为自由计时段，用来验证聚合只把番茄段计入番茄数。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, mode, pomodoro_completed) "
        "VALUES (:taskId, :startTime, :endTime, :duration, :mode, :pomodoroCompleted)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, QStringLiteral("12:30:00")));
    query.bindValue(QStringLiteral(":duration"), duration);
    query.bindValue(QStringLiteral(":mode"), mode);
    query.bindValue(QStringLiteral(":pomodoroCompleted"),
                    mode == 1 && duration >= kTestMinimumValidDurationSeconds ? 1 : 0);

    if (!query.exec()) {
        qWarning() << "Failed to insert moded focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

// AppSettings 单例落在系统偏好里，跨测试运行持久；复盘用例写进去的每日目标
// （旧的一对键与按日期的历史键）不清掉，就会串到后面的用例和下一次运行。
// 同进程里同一份设置的 QSettings 共享缓存，这里删掉后单例立刻读不到。
void clearDailyGoalSettingsForTest()
{
    QSettings settings;
    settings.remove(QStringLiteral("focus/dailyGoalHistory"));
    settings.remove(QStringLiteral("focus/dailyGoalDate"));
    settings.remove(QStringLiteral("focus/dailyGoalMinutes"));
    settings.remove(QStringLiteral("focus/dailyGoalHours"));
    settings.sync();
}

int categoryIdByName(const QString& name)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT id FROM categories WHERE name = :name"));
    query.bindValue(QStringLiteral(":name"), name);
    if (!query.exec() || !query.next()) {
        return -1;
    }
    return query.value(0).toInt();
}

int insertPlannedTask(const QString& title, const QDate& date, int categoryId, int estimated)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category_id, date, completed, estimated_minutes) "
        "VALUES (:title, :categoryId, :date, 0, :estimated)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":estimated"), estimated);
    if (!query.exec()) {
        qWarning() << "Failed to insert planned task:" << query.lastError().text();
        return -1;
    }
    return query.lastInsertId().toInt();
}

QVariantMap subjectByName(const QVariantList& subjects, const QString& name)
{
    for (const QVariant& value : subjects) {
        const QVariantMap subject = value.toMap();
        if (subject.value(QStringLiteral("name")).toString() == name) {
            return subject;
        }
    }
    return QVariantMap();
}

QVariantMap rowBySubject(const QVariantList& rows, const QString& subject)
{
    for (const QVariant& value : rows) {
        const QVariantMap row = value.toMap();
        if (row.value(QStringLiteral("subject")).toString() == subject) {
            return row;
        }
    }
    return QVariantMap();
}

QVariantMap factOfType(const QVariantList& facts, const QString& type)
{
    for (const QVariant& value : facts) {
        const QVariantMap fact = value.toMap();
        if (fact.value(QStringLiteral("type")).toString() == type) {
            return fact;
        }
    }
    return QVariantMap();
}

// 同一条用例里切换多组场景时清空记录。专注记录外键指向任务（ON DELETE SET NULL），先删记录再删任务。
bool clearFocusSessionsForTest()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    return query.exec(QStringLiteral("DELETE FROM focus_sessions"));
}

bool clearTasksForTest()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    return clearFocusSessionsForTest() && query.exec(QStringLiteral("DELETE FROM tasks"));
}

QVariantMap taskMapById(const QVariantList& tasks, int taskId)
{
    for (const QVariant& taskValue : tasks) {
        const QVariantMap map = taskValue.toMap();
        if (map.value(QStringLiteral("id")).toInt() == taskId) {
            return map;
        }
    }
    return QVariantMap();
}

bool insertFocusSessionRowAt(int taskId,
                             const QDate& date,
                             const QString& startTime,
                             const QString& endTime,
                             int duration)
{
    // 起止时刻可控，用于构造日界点前后的固定 session，避免测试依赖真实时钟。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, pomodoro_completed) "
        "VALUES (:taskId, :startTime, :endTime, :duration, :pomodoroCompleted)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date, startTime));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, endTime));
    query.bindValue(QStringLiteral(":duration"), duration);
    query.bindValue(QStringLiteral(":pomodoroCompleted"),
                    duration >= kTestMinimumValidDurationSeconds ? 1 : 0);

    if (!query.exec()) {
        qWarning() << "Failed to insert boundary focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

bool insertFocusSessionWithSnapshot(int taskId,
                                    const QDate& date,
                                    const QString& startTime,
                                    int duration,
                                    const QString& categoryName,
                                    const QString& categoryColor)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, pomodoro_completed, "
        "category_name_snapshot, category_color_snapshot) "
        "VALUES (:taskId, :startTime, :endTime, :duration, 1, :categoryName, :categoryColor)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date, startTime));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, startTime));
    query.bindValue(QStringLiteral(":duration"), duration);
    query.bindValue(QStringLiteral(":categoryName"), categoryName);
    query.bindValue(QStringLiteral(":categoryColor"), categoryColor);
    if (!query.exec()) {
        qWarning() << "Failed to insert snapshotted focus session:" << query.lastError().text();
        return false;
    }
    return true;
}

bool insertFocusSessionWithNullDuration(int taskId, const QDate& date)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, NULL)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, QStringLiteral("12:30:00")));

    if (!query.exec()) {
        qWarning() << "Failed to insert test focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

bool insertUnfinishedFocusSessionRow(int taskId, const QDate& date, int duration)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, NULL, :duration)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date));
    query.bindValue(QStringLiteral(":duration"), duration);

    if (!query.exec()) {
        qWarning() << "Failed to insert unfinished focus session:" << query.lastError().text();
        return false;
    }

    return true;
}

int countFocusSessions()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    if (!query.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")) || !query.next()) {
        qWarning() << "Failed to count focus sessions:" << query.lastError().text();
        return -1;
    }

    return query.value(0).toInt();
}

bool taskCompletedById(int taskId)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT completed FROM tasks WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to read test task completion:" << query.lastError().text()
                   << "taskId=" << taskId;
        return false;
    }

    return query.value(0).toBool();
}

int insertTaskRowWithCategoryId(const QString& title,
                                const QDate& date,
                                int categoryId,
                                const QString& legacyCategory,
                                bool completed,
                                const QString& createdAt)
{
    // 同时写 category_id 和旧版 category 文本，用来覆盖新旧数据混合场景。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, category_id, date, completed, created_at) "
        "VALUES (:title, :category, :categoryId, :date, :completed, :createdAt)"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":category"), legacyCategory);
    query.bindValue(QStringLiteral(":categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":createdAt"), createdAt);

    if (!query.exec()) {
        qWarning() << "Failed to insert category-aware test task:" << query.lastError().text();
        return -1;
    }

    return query.lastInsertId().toInt();
}

int insertFocusSessionRowWithTimes(int taskId,
                                   const QString& startTime,
                                   const QString& endTime,
                                   int duration)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, pomodoro_completed) "
        "VALUES (:taskId, :startTime, :endTime, :duration, :pomodoroCompleted)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), startTime);
    query.bindValue(QStringLiteral(":endTime"), endTime);
    query.bindValue(QStringLiteral(":duration"), duration);
    query.bindValue(QStringLiteral(":pomodoroCompleted"),
                    duration >= kTestMinimumValidDurationSeconds ? 1 : 0);

    if (!query.exec()) {
        qWarning() << "Failed to insert timed focus session:" << query.lastError().text();
        return -1;
    }

    return query.lastInsertId().toInt();
}

QString readUtf8File(const QString& filePath)
{
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QString();
    }
    return QString::fromUtf8(file.readAll());
}

bool createLegacyVersion1Database(const QString& path,
                                  const QList<QPair<QString, QString>>& extraRows = {})
{
    // 构造旧版本数据库，验证真实用户升级时的迁移路径。
    const QString connectionName = QStringLiteral("LegacyMigrationSetupConnection");
    {
        QSqlDatabase legacyDb = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        legacyDb.setDatabaseName(path);
        if (!legacyDb.open()) {
            qWarning() << "Failed to open legacy database:" << legacyDb.lastError().text();
            return false;
        }

        QSqlQuery query(legacyDb);
        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        )SQL"))) {
            qWarning() << "Failed to create legacy tasks table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE focus_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER,
                start_time TEXT NOT NULL,
                end_time TEXT,
                duration INTEGER,
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
            )
        )SQL"))) {
            qWarning() << "Failed to create legacy focus_sessions table:" << query.lastError().text();
            return false;
        }

        query.prepare(QStringLiteral(
            "INSERT INTO tasks (title, category, date, completed, created_at) "
            "VALUES (:title, :category, :date, 0, :createdAt)"));

        QList<QPair<QString, QString>> rows = {
            {QStringLiteral("旧数学任务"), QStringLiteral("数学")},
            {QStringLiteral("旧自定义任务"), QStringLiteral("数据结构")},
            {QStringLiteral("旧空科目任务"), QString()}
        };
        // 额外行由调用方按需追加。默认不加，因为有用例硬编码了这三条的数量——
        // 共享 fixture 一旦改动就会波及所有依赖它的用例。
        rows.append(extraRows);

        for (const auto& row : rows) {
            query.bindValue(QStringLiteral(":title"), row.first);
            query.bindValue(QStringLiteral(":category"), row.second);
            query.bindValue(QStringLiteral(":date"), QStringLiteral("2026-06-10"));
            query.bindValue(QStringLiteral(":createdAt"), QStringLiteral("2026-06-10T08:00:00"));
            if (!query.exec()) {
                qWarning() << "Failed to insert legacy task:" << query.lastError().text();
                return false;
            }
        }

        if (!query.exec(QStringLiteral("PRAGMA user_version = 1"))) {
            qWarning() << "Failed to set legacy database version:" << query.lastError().text();
            return false;
        }

        legacyDb.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
    return true;
}

// 构造 schema v7 形态的数据库：focus_sessions 尚无完成事实与科目快照列。
// 数据逐行覆盖 v8 的阈值、NULL 三值逻辑和模式分支，同时为 v9 保留任务已删边界。
bool createLegacyVersion7Database(const QString& path, bool includeDayBoundaryRows = false)
{
    const QString connectionName = QStringLiteral("Version7MigrationSetupConnection");
    bool setupSucceeded = false;
    {
        QSqlDatabase legacyDb = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        legacyDb.setDatabaseName(path);
        if (!legacyDb.open()) {
            qWarning() << "Failed to open version 7 database:" << legacyDb.lastError().text();
        } else {
            QSqlQuery query(legacyDb);
            setupSucceeded = [&]() {
                if (!query.exec(QStringLiteral(R"SQL(
                    CREATE TABLE categories (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT NOT NULL UNIQUE CHECK(length(trim(name)) > 0),
                        color TEXT NOT NULL,
                        is_preset INTEGER NOT NULL DEFAULT 0,
                        display_order INTEGER NOT NULL DEFAULT 0,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    )
                )SQL"))) {
                    qWarning() << "Failed to create version 7 categories:" << query.lastError().text();
                    return false;
                }
                if (!query.exec(QStringLiteral(R"SQL(
                    CREATE TABLE routines (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                        category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
                        active INTEGER NOT NULL DEFAULT 1,
                        display_order INTEGER NOT NULL DEFAULT 0,
                        last_generated_date TEXT,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    )
                )SQL"))) {
                    qWarning() << "Failed to create version 7 routines:" << query.lastError().text();
                    return false;
                }
                if (!query.exec(QStringLiteral(R"SQL(
                    CREATE TABLE tasks (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                        category TEXT,
                        category_id INTEGER REFERENCES categories(id),
                        routine_id INTEGER REFERENCES routines(id) ON DELETE SET NULL,
                        routine_generated INTEGER NOT NULL DEFAULT 0 CHECK(routine_generated IN (0, 1)),
                        estimated_minutes INTEGER NOT NULL DEFAULT 0,
                        date TEXT NOT NULL,
                        completed INTEGER NOT NULL DEFAULT 0,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    )
                )SQL"))) {
                    qWarning() << "Failed to create version 7 tasks:" << query.lastError().text();
                    return false;
                }
                if (!query.exec(QStringLiteral(R"SQL(
                    CREATE TABLE focus_sessions (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        task_id INTEGER,
                        start_time TEXT NOT NULL,
                        end_time TEXT,
                        duration INTEGER,
                        mode INTEGER NOT NULL DEFAULT 1,
                        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
                    )
                )SQL"))) {
                    qWarning() << "Failed to create version 7 focus sessions:" << query.lastError().text();
                    return false;
                }
                if (!query.exec(QStringLiteral(
                        "INSERT INTO categories (id, name, color, is_preset, display_order) "
                        "VALUES (1, '学习', '#d4a574', 0, 1)"))
                    || !query.exec(QStringLiteral(
                        "INSERT INTO tasks (id, title, category, category_id, date, completed, created_at) "
                        "VALUES (1, '保留科目的任务', '学习', 1, '2026-07-20', 0, "
                        "'2026-07-20T08:00:00')"))
                    || !query.exec(QStringLiteral(
                        "INSERT INTO tasks (id, title, category, category_id, date, completed, created_at) "
                        "VALUES (2, '迁移前已删任务', '学习', 1, '2026-07-20', 0, "
                        "'2026-07-20T08:00:00')"))) {
                    qWarning() << "Failed to seed version 7 category/tasks:" << query.lastError().text();
                    return false;
                }

                struct LegacySessionRow {
                    int taskId;
                    QString startTime;
                    QVariant endTime;
                    QVariant duration;
                    int mode;
                };
                const QList<LegacySessionRow> rows{
                    {1, QStringLiteral("2026-07-20T08:00:00"), QStringLiteral("2026-07-20T08:25:00"), 1500, 1},
                    {2, QStringLiteral("2026-07-20T09:00:00"), QStringLiteral("2026-07-20T09:04:00"), 240, 1},
                    {1, QStringLiteral("2026-07-20T10:00:00"), QStringLiteral("2026-07-20T10:02:59"), 179, 1},
                    {1, QStringLiteral("2026-07-20T11:00:00"), QStringLiteral("2026-07-20T11:03:00"), 180, 1},
                    {1, QStringLiteral("2026-07-20T12:00:00"), QStringLiteral("2026-07-20T12:30:00"), 1800, 0},
                    {1, QStringLiteral("2026-07-20T13:00:00"), QVariant(), 1500, 1},
                    {1, QStringLiteral("2026-07-20T14:00:00"), QStringLiteral("2026-07-20T14:25:00"), QVariant(), 1},
                };
                query.prepare(QStringLiteral(
                    "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                    "VALUES (:taskId, :startTime, :endTime, :duration, :mode)"));
                for (const LegacySessionRow &row : rows) {
                    query.bindValue(QStringLiteral(":taskId"), row.taskId);
                    query.bindValue(QStringLiteral(":startTime"), row.startTime);
                    query.bindValue(QStringLiteral(":endTime"), row.endTime);
                    query.bindValue(QStringLiteral(":duration"), row.duration);
                    query.bindValue(QStringLiteral(":mode"), row.mode);
                    if (!query.exec()) {
                        qWarning() << "Failed to seed version 7 focus session:" << query.lastError().text();
                        return false;
                    }
                }

                if (includeDayBoundaryRows) {
                    // 这两行只用来证明回填不读取逻辑日设置，时刻分别卡在 04:00 边界两侧。
                    if (!query.exec(QStringLiteral(
                            "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) VALUES "
                            "(1, '2026-07-21T03:59:00', '2026-07-21T04:24:00', 1500, 1), "
                            "(1, '2026-07-21T04:01:00', '2026-07-21T04:26:00', 1500, 1)"))) {
                        qWarning() << "Failed to seed version 7 day-boundary sessions:"
                                   << query.lastError().text();
                        return false;
                    }
                }

                // 外键在该独立夹具连接中默认关闭，因此删任务后 session.task_id 仍保留 2，
                // 模拟旧库里已无法回溯任务的历史行，以锁住 v9 的空快照边界。
                if (!query.exec(QStringLiteral("DELETE FROM tasks WHERE id = 2"))
                    || !query.exec(QStringLiteral("PRAGMA user_version = 7"))) {
                    qWarning() << "Failed to finalize version 7 fixture:" << query.lastError().text();
                    return false;
                }
                return true;
            }();
            legacyDb.close();
        }
    }
    // QSqlDatabase 必须先离开作用域再移除命名连接，否则 Qt 会警告连接仍在使用。
    QSqlDatabase::removeDatabase(connectionName);
    return setupSucceeded;
}

bool createVersion2Database(const QString& path)
{
    // 构造已完成 v2 迁移的数据库，专门验证 v3 只新增 routines，不破坏已有科目结构。
    const QString connectionName = QStringLiteral("Version2MigrationSetupConnection");
    {
        QSqlDatabase version2Db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        version2Db.setDatabaseName(path);
        if (!version2Db.open()) {
            qWarning() << "Failed to open version 2 database:" << version2Db.lastError().text();
            return false;
        }

        QSqlQuery pragma(version2Db);
        if (!pragma.exec(QStringLiteral("PRAGMA foreign_keys = ON"))) {
            qWarning() << "Failed to enable version 2 foreign keys:" << pragma.lastError().text();
            return false;
        }

        QSqlQuery query(version2Db);
        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE CHECK(length(trim(name)) > 0),
                color TEXT NOT NULL,
                is_preset INTEGER NOT NULL DEFAULT 0,
                display_order INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        )SQL"))) {
            qWarning() << "Failed to create version 2 categories table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                category_id INTEGER REFERENCES categories(id),
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        )SQL"))) {
            qWarning() << "Failed to create version 2 tasks table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(R"SQL(
            CREATE TABLE focus_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER,
                start_time TEXT NOT NULL,
                end_time TEXT,
                duration INTEGER,
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
            )
        )SQL"))) {
            qWarning() << "Failed to create version 2 focus_sessions table:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(
                "INSERT INTO categories (name, color, is_preset, display_order) "
                "VALUES ('数学', '#d4a574', 1, 1)"))) {
            qWarning() << "Failed to insert version 2 category:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral(
                "INSERT INTO tasks (title, category, category_id, date, completed, created_at) "
                "VALUES ('v2 任务', '数学', 1, '2026-06-16', 0, '2026-06-16T08:00:00')"))) {
            qWarning() << "Failed to insert version 2 task:" << query.lastError().text();
            return false;
        }

        if (!query.exec(QStringLiteral("PRAGMA user_version = 2"))) {
            qWarning() << "Failed to set version 2 database version:" << query.lastError().text();
            return false;
        }

        version2Db.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
    return true;
}

QStringList taskTitles(const QVariantList& tasks)
{
    QStringList titles;
    for (const QVariant& taskValue : tasks) {
        titles.append(taskValue.toMap().value(QStringLiteral("title")).toString());
    }
    return titles;
}

int taskIdByTitle(const QVariantList& tasks, const QString& title)
{
    for (const QVariant& taskValue : tasks) {
        const QVariantMap task = taskValue.toMap();
        if (task.value(QStringLiteral("title")).toString() == title) {
            return task.value(QStringLiteral("id")).toInt();
        }
    }
    return -1;
}

QDate logicalToday()
{
    // 测试里所有“服务的今天”都必须与生产设置使用同一口径。
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}
}

class ServiceTests : public QObject {
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void appSettingsDefaultsAndRoundTrip();
    void appSettingsSameValueDoesNotEmit();
    void appSettingsReduceMotionRoundTrip();
    void appSettingsSlimClockFontRoundTrip();
    void appSettingsRolloverIgnoredDateRoundTrip();
    void appSettingsNicknameTrimsAndRoundTrips();
    void appSettingsDailyFocusGoalMinutesByDate();
    void appSettingsDailyGoalHistoryKeepsLastSavedValuePerDate();
    void appSettingsDailyGoalRejectsCorruptStoredValues();
    void appSettingsDailyGoalLegacyPairSyncsIntoHistory();
    void appSettingsDailyGoalConsistentSyncDoesNotWrite();
    void appSettingsDailyGoalSameValueSaveRepairsMissingHistory();
    void appSettingsDailyGoalSaveFailureRestoresCacheAndRetries();
    void appSettingsDailyGoalSyncFailureIsReportedAndRetried();
    void appSettingsDailyGoalOldVersionRoundTrip();
    void appSettingsSidebarVisibleRoundTrip();
    void appSettingsSidebarOrderRoundTripsAndResets();
    void appSettingsSidebarOrderKeepsNewPagesVisible();
    void appSettingsSidebarOrderDropsUnknownAndDuplicateIds();
    void appSettingsReloadNotifiesEveryProperty();
    void appSettingsDashboardTimerVisibleRoundTrip();
    void appSettingsRemovesRetiredGoalSettings();
    void appSettingsBackgroundThemeDefaultAndRoundTrip();
    void appSettingsDayStartHourNormalizeAndPersist();
    void appSettingsDayStartHourRejectsCorruptIniValue();
    void appSettingsFocusDurationsNormalizeCorruptValues();
    void appSettingsFreeTimerWarningHoursDefaultsAndNormalizes();
    void appSettingsWriteFailureDoesNotEmitSuccess();
    void appSettingsScheduleBatchReportsFailureWithoutChangingValues();
    void appSettingsScheduleBatchPersistsBeforeEmittingChanges();
    void appSettingsScheduleBatchRetriesExistingReadOnlyFile();
    void appSettingsCanRetryAfterWriteFailure();
    void appSettingsReduceTransparencyRoundTrip();
    void appSettingsRaiseOnPhaseCompleteDefaultsOnAndRoundTrips();
    void appSettingsCloseToTrayDefaultsOffAndRoundTrips();
    void appSettingsNaturalCompletionNoticeRoundTripsAndReloads();
    void appSettingsAutoStartDefaultsOffAndRoundTrips();
    void appSettingsQuickStartDefaultsOffAndRoundTrips();
    void appSettingsLongBreakDefaultsAndNormalizes();
    void logicalDayDateOfBoundaries();
    void logicalDayMsUntilNextBoundary();
    void logicalDayHandlesDstFallBackByWallClock();
    void logicalDayServiceSchedulesTimerOnConstruction();
    void logicalDayServiceEmitsChangedOnDayStartHourChange();
    void logicalDayChangeMaterializesRoutineIdempotently();
    void addTaskRejectsBlankTitle();
    void addTaskPersistsTrimmedTitleAndEmitsChange();
    void addTaskAcceptsIsoDateStringFromQml();
    void createTaskReturnsTheIdOfTheRowItJustInserted();
    void createTaskDistinguishesSameTitleTasksOnTheSameDay();
    void createTaskReportsFailureWithNegativeId();
    void deleteTaskPreservesFocusSessionHistory();
    void statisticsReturnsTodayCompletionAndDuration();
    void statisticsBucketsSessionsByLogicalDay();
    void statisticsTodayUsesLogicalToday();
    void getDayStatsUsesSpecifiedHistoricalDate();
    void getDayComparisonReturnsTrendTextAndRejectsInvalidDate();
    void focusHistoryBucketsSessionsByLogicalDay();
    void focusHistoryReturnsMonthSessionsWithinBoundaries();
    void focusHistoryReturnsDayTotalsAndFormattedDurations();
    void focusHistoryFallsBackWhenTaskWasDeleted();
    void manualSessionCountsTowardMinutesButNotPomodoros();
    void manualSessionRejectsOverlapWithExistingRecord();
    void manualSessionRejectsFutureAndTooShort();
    void updateSessionMovesItAndKeepsItsMode();
    void partialSessionEditPreservesPrecisionAndPause();
    void timelineRecordCorrectionKeepsIdentityAndRollsBack();
    void restOccupiesOnlyItsMeasuredDuration();
    void attributionOnlyEditSkipsOverlapCheck();
    void taskOptionsPreferSelectedDateAndAreCapped();
    void deleteSessionRemovesItAndRollsStatsBack();
    void manualWriteRefusesToTouchRunningSession();
    void manualSessionRejectsOverlapWithRunningSession();
    void everySettingTheAppWritesPassesTheOwnershipFilter();
    void ownershipFilterRejectsForeignKeysAndKeepsShortcutOverrides();
    void asyncExportRunsOffTheCallingThreadAndReportsCompletion();
    void notesRoundTripAndRenameDoesNotEraseThem();
    void overlongNotesAreRejectedInsteadOfTruncated();
    void completeTaskWithNoteStoresNoteAndCompletesInOneWrite();
    void completionNoteSurvivesUndoAndCanBeRewritten();
    void overlongCompletionNoteIsRejectedWithoutSideEffects();
    void editingKeepsCompletionNoteUnlessExplicitlyGiven();
    void scriptCallPathKeepsOrWritesCompletionNote();
    void duplicateTaskDoesNotInheritCompletionNote();
    void mixedLegacyOrdersKeepNewTasksAtEnd();
    void allTaskDateWritesAppendAfterLegacyRows();
    void reorderTasksPutsManualOrderFirstAndKeepsUnsortedByCreation();
    void reorderTasksRejectsInvalidSetsAtomically();
    void moveTaskToDateLandsAtTheEndOfTheTargetDay();
    void focusHistoryDistinguishesEmptyResultFromQueryError();
    void focusHistorySkipsUnfinishedSessions();
    void focusHistorySkipsInvalidShortSessions();
    void focusHistoryCleansInvalidShortSessions();
    void getWeekStatsUsesCurrentNaturalWeek();
    void getWeekStatsUsesSpecifiedMondayAndRejectsInvalidStart();
    void getWeekComparisonSumsNaturalWeeksAndRejectsInvalidStart();
    void weekComparisonRangeQueryEqualsPerDaySum();
    void weekStatsGroupedDurationsEqualPerDayQueries();
    void getWeekTasksReturnsInclusiveRangeAndRequiredOrder();
    void getMonthTasksReturnsInclusiveMonthRange();
    void getMonthTasksRejectsInvalidMonth();
    void getEffectiveDaysFiltersInvalidSessions();
    void getFocusSessionCountCountsOnlyValidFinishedSessions();
    void validPomodoroCountExcludesFreeTimerAndManualStops();
    void validPomodoroCountUsesSameLogicalDayAsSessionCount();
    void getStreakDaysCountsBackFromLogicalToday();
    void getStreakDaysStartsFromYesterdayWhenTodayHasNoFocus();
    void getTotalFocusDurationSumsOnlyValidSessions();
    void getMonthStatsUsesCurrentMonthAndTaskDate();
    void getMonthStatsUsesSpecifiedMonthAndRejectsInvalidYearMonth();
    void getMonthComparisonHandlesPreviousMonthAndInvalidYearMonth();
    void getMonthWeeklySummaryStaysInsideCurrentMonth();
    void getMonthWeeklySummaryUsesSpecifiedMonthAndRejectsInvalidYearMonth();
    void getCategoryStatsAggregatesDurationsAndPercentages();
    void statisticsIgnoresInvalidShortSessions();
    void getDayTaskStatsAggregatesPerTask();
    void getDayTaskStatsUsesLatestValidCategorySnapshot();
    void getDayTaskStatsGroupsUnassignedFocus();
    void getDayTaskStatsPomodoroCountUsesValidRule();
    void getDayTaskStatsRespectsLogicalDayAndEmptyDate();
    void routinesTableExistsAfterInitialize();
    void databaseReinitializeEmitsRoutineChangeOnce();
    void version2MigrationAddsRoutinesSchemaAndIndex();
    void routinesCategoryForeignKeyClearsWhenCategoryDeleted();
    void routineCrudAddsGetsUpdatesDeletes();
    void deletingRoutineReclaimsUntouchedTodayTask();
    void deletingRoutineKeepsTouchedTodayTask();
    void updatingRoutineSyncsTodayTask();
    void deactivatingRoutineReclaimsTodayTaskAndRestoresOnReactivate();
    void removingTodayFromWeekdaysReclaimsTodayTask();
    void reclaimingTodayTaskDoesNotResurrectManuallyDeletedTask();
    void databaseCloseRemovesNamedConnection();
    void databaseOpenedExistingFlagTracksSuccessfulStartupOnly();
    void materializeTodayIsIdempotentAndDoesNotBackfill();
    void materializeTodayPreservesCategoryAndDoesNotEmitSignals();
    void materializeTodayStampsRoutineId();
    void materializeTodayRollsBackClaimWhenTaskInsertFails();
    void materializeTodayDoesNotResurrectDeletedTask();
    void materializeTodaySkipsInactiveRoutines();
    void routineWeekdayMaskMatchesIsoWeekdayNumbers();
    void routineWeekdaysDefaultToEveryDayAndRejectInvalidMask();
    void materializeTodayOnlyGeneratesOnSelectedWeekdays();
    void migrationV15AddsRoutineWeekdaysAndKeepsExistingRoutines();
    void migrationV16AddsCompletionNoteAndKeepsExistingTasks();
    void migrationV17DropsLongGoalsAfterSnapshot();
    void migrationV5RebuildKeepsCompletionNote();
    void freshDatabaseHasRoutineIdColumn();
    void migrationV4DoesNotGuessRoutineLineage();
    void migrationV6ClearsUntrustedRoutineLineage();
    void migrationV10ConvertsPomodoroEstimateToMinutes();
    void migrationV10IsIdempotentAndDoesNotLoop();
    void migrationV12NormalizesVisibleOrderAndIsIdempotent();
    void migrationV5RebuildKeepsColumnsAddedAfterV5();
    void migrationV5RefusesToRebuildWhenTasksHasAnUnknownColumn();
    void freshDatabaseCreatesVersion4PresetCategories();
    void migrationMapsLegacyCategoryTextToCategoryIds();
    void migrationCategoryMappingHandlesWhitespaceAndCaseBoundaries();
    void migrationCreatesDatabaseBackup();
    void migrationV8BackfillsPomodoroCompletedPerRow();
    void migrationV8DoesNotInventPomodorosForFreeTimerSessions();
    void migrationV9SnapshotsCategoryForSessionsWithTasks();
    void migrationV9LeavesSnapshotEmptyWhenTaskIsGone();
    void migrationV9PreservesSnapshotAfterCategoryDeletion();
    void migrationV8BackfillIsIndependentOfDayStartHour();
    void migrationV8DoesNotRewriteExistingCompletionFacts();
    void migrationV14CreatesKnowledgeGapsAndKeepsExistingData();
    void migrationV14RejectsStructurallyBrokenKnowledgeGapTable();
    void migrationV14RejectsKnowledgeGapForeignKeyThatCascades();
    void migrationV14RejectsCompositeKnowledgeGapForeignKey();
    void multiStepMigrationKeepsOnlyThePreMigrationSnapshot();
    void customCategoryCrudValidatesAndEmitsChanges();
    void presetCategoriesCanBeEditedButNotDeleted();
    void deletingAssociatedCategoryDetachesTasks();
    void deletingLegacyTextCategoryClearsTaskCategoryText();
    void taskManagerReturnsFullCategoryInfo();
    void taskCreatedAtTreatsSqliteTimestampAsUtc();
    void taskManagerTodayUsesLogicalToday();
    void legacyAddTaskWithTextCategoryRemainsCompatible();
    void updateTaskChangesTitleCategoryAndDate();
    void updateTaskRejectsBlankTitleAndInvalidId();
    void overdueQueryExcludesTodayCompletedAndTrustedRoutine();
    void overdueQueryOnlyLooksBackTheRolloverWindow();
    void moveTasksToTodayIsTransactional();
    void batchRescheduleSearchAndCopy();
    void exportFocusSessionsUsesLogicalDayRange();
    void exportTasksWritesUtf8CsvWithEscapingAndCategoryFallbacks();
    void exportNeutralizesFormulaPrefixesAndWritesBom();
    void weeklySubjectMinutesAddUpToTotal();
    void exportFocusSessionsAndExportAllWriteExpectedCsvFiles();
    void exportAllUsesOneDatabaseSnapshot();
    void exportFocusSessionsIgnoresInvalidShortSessions();
    void exportRejectsInvalidDateRangeAndUnwritablePath();
    void exportFailurePreservesExistingFile();
    void exportAllRejectsInvalidDestinationBeforeReplacingFiles();
    void freeFocusCountsTowardDurationEstimate();
    void discardFreeFocusRemovesLongSessionWithoutRecording();
    void correctedFreeFocusDurationUsesUserConfirmedValue();
    void correctedFreeFocusDurationShrinksRecordedSpanAndFreesWindow();
    void correctedFreeFocusDurationRejectsValueAboveElapsed();
    void stopFocusUnderFiveMinutesKeepsTaskPending();
    void stopFocusUnderThreeMinutesDiscardsInvalidSession();
    void shortSessionEmitsSessionDiscarded();
    void validSessionDoesNotEmitSessionDiscarded();
    void focusTimerExposesMinimumValidDuration();
    void pomodoroWorkCompletesOnlyWhenPlannedDurationReached();
    void pomodoroWorkRequiresPositiveExactPlan();
    void pomodoroTargetCompletionFailureKeepsSession();
    void manuallyStoppedPomodoroDoesNotCountAsCompleted();
    void pomodoroBreakWritesNoSessionAndCompletes();
    void pomodoroBreakRestoresTaskContextAndCount();
    void manualRestDoesNotCreateFocusSessionOrFinishAutomatically();
    void manualRestRestoresPausedWithoutCountingAsFocus();
    void restHistorySaveIsAtomicAndUsesLogicalDay();
    void deletingActiveTaskDetachesTimerAndSuppressesAutoCompleteFailure();
    void pomodoroWorkStoppedUnderMinimumIsDiscarded();
    void freeFocusStillCountsUpUnchanged();
    void focusTimerUsesMonotonicElapsedTimeAfterBlockedEventLoop();
    void interruptedFocusRestoresPausedAndKeepsProgress();
    void restoreWithoutActiveStateResetsPomodoroCount();
    void restoreKeepsSessionWhenTaskWasDeleted();
    void completionSaveFailureNotifiesOnceAndKeepsRetrying();
    void discardedShortPomodoroDoesNotAdvanceLongBreakCount();
    void startupCleanupRemovesLegacyOrphanedSession();
    void queryServicesReportDatabaseFailureInsteadOfSilentEmptyData();
    void estimatedMinutesDefaultsToZeroAfterMigration();
    void addTaskPersistsEstimatedPomodoros();
    void updateTaskChangesEstimateAndRenamePreservesIt();
    void taskAggregatesActualPomodorosFromValidWorkSessions();
    void freeFocusCountsMinutesButNotPomodoros();
    void pomodoroAggregationDoesNotCrossTasksOrLeakUnbound();
    void recoveredPomodoroStillCountsForOriginalTask();
    void deletingTaskDetachesButKeepsPomodoroHistory();
    void deletingTaskKeepsCategorySnapshotForStatistics();
    void isRoutineGeneratedTaskDistinguishesInstances();
    void completeUndoRestoresPriorStateWithoutTouchingFields();
    void weeklyReviewPeriodStateUsesLogicalTodayAsGiven();
    void weeklyReviewAssignsSessionsByDayStartHour();
    void weeklyReviewGoalSummaryExcludesToday();
    void weeklyReviewReconciliationUsesSameTaskSet();
    void weeklyReviewGoalShortfallFact();
    void weeklyReviewSubjectShareChangeFactGuards();
    void weeklyReviewEstimateFacts();
    void weeklyReviewFactsPriorityAndCurrentWeekSuppression();
    void weeklyReviewErrorsAreReturnedWithoutSignals();
    void weeklyReviewContentFlags();

private:
    // 需要访问 FocusTimer 私有时钟状态，必须挂在 friend 类下而不是自由函数里。
    static void setFocusElapsedSeconds(FocusTimer* timer, int seconds);

    QTemporaryDir* m_tempDir = nullptr;
};

void ServiceTests::setFocusElapsedSeconds(FocusTimer* timer, int seconds)
{
    // 直接把已累计时长设为目标值，并把当前运行段起点重置到“现在”，使运行段增量归零，
    // 从而 elapsedSeconds ≈ 指定值，避免真实等待数分钟。
    timer->m_accumulatedMilliseconds = static_cast<qint64>(seconds) * 1000;
    timer->m_elapsedSeconds = seconds;
    if (timer->m_isRunning) {
        timer->m_runSegmentStartNsecs = timer->m_clock->nowNsecs();
    }
}

void ServiceTests::init()
{
    // AppSettings 是进程单例，落在系统偏好目录里的一份 plist——它跨测试运行持久存在。
    // 不清干净的话，用例的结果会取决于上一次运行留下的值：比如
    // logicalDayServiceEmitsChangedOnDayStartHourChange 依赖"把 4 改成 5 会发信号"，
    // 而写盘一旦失败（受限环境里很常见），值会停在上次的 5，改成 5 就不发信号了。
    // 有人报过这条稳定失败而本机一直是绿的，差别就在这里。
    AppSettings::instance()->clearAllShortcutOverrides();
    AppSettings::instance()->setDayStartHour(4);
    clearDailyGoalSettingsForTest();

    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("test.sqlite")));
}

void ServiceTests::cleanup()
{
    // FocusTimer 是进程级单例；失败用例可能没走到 stopFocus，必须在关闭测试数据库前清掉活动阶段。
    FocusTimer::instance()->resetSession();
    FocusTimer::instance()->resetPomodoroCount();
    ExportService::instance()->m_betweenExportFilesHookForTest = {};
    AppSettings::instance()->setDayStartHour(4);
    clearDailyGoalSettingsForTest();
    DatabaseManager::instance()->close();
    delete m_tempDir;
    m_tempDir = nullptr;
}

void ServiceTests::appSettingsDefaultsAndRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.lastMode(), 0);
        QCOMPARE(settings.workMinutes(), 25);
        QCOMPARE(settings.breakMinutes(), 5);
        QCOMPARE(settings.soundEnabled(), true);

        QSignalSpy modeSpy(&settings, &AppSettings::lastModeChanged);
        QSignalSpy workSpy(&settings, &AppSettings::workMinutesChanged);
        settings.setLastMode(1);
        settings.setWorkMinutes(45);
        settings.setBreakMinutes(10);
        settings.setSoundEnabled(false);
        QCOMPARE(modeSpy.count(), 1);
        QCOMPARE(workSpy.count(), 1);
    }

    // 重新打开同一文件，验证写入的是持久化配置，不是对象内存缓存。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.lastMode(), 1);
    QCOMPARE(reloaded.workMinutes(), 45);
    QCOMPARE(reloaded.breakMinutes(), 10);
    QCOMPARE(reloaded.soundEnabled(), false);
}

void ServiceTests::appSettingsSameValueDoesNotEmit()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    AppSettings settings(dir.filePath(QStringLiteral("settings.ini")));

    QSignalSpy modeSpy(&settings, &AppSettings::lastModeChanged);
    settings.setLastMode(0);
    QCOMPARE(modeSpy.count(), 0);
}

void ServiceTests::appSettingsReduceMotionRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.reduceMotion(), false);

        QSignalSpy spy(&settings, &AppSettings::reduceMotionChanged);
        settings.setReduceMotion(true);
        QCOMPARE(settings.reduceMotion(), true);
        QCOMPARE(spy.count(), 1);

        settings.setReduceMotion(true);
        QCOMPARE(spy.count(), 1);
    }

    // 重新构造对象验证 QSettings 已落盘，不只是当前对象缓存。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.reduceMotion(), true);
}

void ServiceTests::appSettingsSlimClockFontRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.slimClockFont(), true);

        QSignalSpy spy(&settings, &AppSettings::slimClockFontChanged);
        settings.setSlimClockFont(false);
        QCOMPARE(settings.slimClockFont(), false);
        QCOMPARE(spy.count(), 1);

        settings.setSlimClockFont(false);
        QCOMPARE(spy.count(), 1);
    }

    // 重新构造对象验证 QSettings 已落盘，不只是当前对象缓存。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.slimClockFont(), false);
}

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
        settings.setRolloverIgnoredDate(QStringLiteral("2026-07-06"));
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.rolloverIgnoredDate(), QStringLiteral("2026-07-06"));
}

void ServiceTests::appSettingsNicknameTrimsAndRoundTrips()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.nickname(), QString());

        QSignalSpy spy(&settings, &AppSettings::nicknameChanged);
        settings.setNickname(QStringLiteral("  zjk  "));
        // 存储的是去空白后的昵称，问候语拼接不会出现悬空标点。
        QCOMPARE(settings.nickname(), QStringLiteral("zjk"));
        QCOMPARE(spy.count(), 1);

        // 语义同值（只差空白）不再发信号。
        settings.setNickname(QStringLiteral("zjk "));
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.nickname(), QStringLiteral("zjk"));
}

void ServiceTests::appSettingsSidebarOrderRoundTripsAndResets()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    const QStringList defaults = AppSettings::defaultSidebarOrder();
    QVERIFY(!defaults.isEmpty());

    {
        AppSettings settings(path);
        QCOMPARE(settings.sidebarOrder(), defaults);

        QSignalSpy spy(&settings, &AppSettings::sidebarOrderChanged);

        QStringList reordered = defaults;
        reordered.move(0, reordered.size() - 1);
        settings.setSidebarOrder(reordered);
        QCOMPARE(settings.sidebarOrder(), reordered);
        QCOMPARE(spy.count(), 1);

        // 同值重写不发信号，避免界面因为一次无意义的写入整体重建侧栏。
        settings.setSidebarOrder(reordered);
        QCOMPARE(spy.count(), 1);

        settings.resetSidebarOrder();
        QCOMPARE(settings.sidebarOrder(), defaults);
        QCOMPARE(spy.count(), 2);

        settings.setSidebarOrder(reordered);
        QCOMPARE(spy.count(), 3);
    }

    // 跨进程持久化：重开一个实例仍是用户排好的顺序。
    AppSettings reloaded(path);
    QStringList expected = defaults;
    expected.move(0, expected.size() - 1);
    QCOMPARE(reloaded.sidebarOrder(), expected);
}

void ServiceTests::appSettingsReloadNotifiesEveryProperty()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    AppSettings settings(path);
    QStringList restoredOrder = AppSettings::defaultSidebarOrder();
    restoredOrder.move(0, restoredOrder.size() - 1);
    {
        // 模拟恢复备份：另一个实例把设置文件整份改写，界面持有的这个对象毫不知情。
        AppSettings restored(path);
        restored.setSidebarOrder(restoredOrder);
    }

    // 逐个属性核对，而不是手抄一份信号清单：新增带 NOTIFY 的属性却忘了在 reload()
    // 里补发时，这里会直接点名是哪一个。漏发的后果是恢复后 getter 已经是新值，
    // 界面却一直显示旧值，直到重启。
    const QMetaObject* meta = settings.metaObject();
    std::vector<std::pair<QByteArray, std::unique_ptr<QSignalSpy>>> spies;
    for (int i = meta->propertyOffset(); i < meta->propertyCount(); ++i) {
        const QMetaProperty property = meta->property(i);
        if (property.hasNotifySignal()) {
            spies.emplace_back(QByteArray(property.name()),
                               std::make_unique<QSignalSpy>(&settings, property.notifySignal()));
        }
    }
    QVERIFY(!spies.empty());

    settings.reload();

    QCOMPARE(settings.sidebarOrder(), restoredOrder);
    for (const auto& [name, spy] : spies) {
        QVERIFY2(spy->count() > 0,
                 qPrintable(QStringLiteral("reload() 没有通知属性 %1").arg(QString::fromLatin1(name))));
    }
}

void ServiceTests::appSettingsSidebarOrderKeepsNewPagesVisible()
{
    // 这条守的是升级路径：用户在旧版本排好了顺序，新版本加了页面，
    // 那一页在存下来的顺序里当然不存在。如果就此不显示，用户会以为
    // 新版本没有这个功能，而且完全无从排查——所以必须补在末尾。
    QStringList defaults = AppSettings::defaultSidebarOrder();
    QVERIFY(defaults.size() >= 3);

    QStringList staleOrder = defaults;
    const QString droppedFirst = staleOrder.takeLast();
    const QString droppedSecond = staleOrder.takeFirst();

    const QStringList normalized = AppSettings::normalizeSidebarOrder(staleOrder);
    QCOMPARE(normalized.size(), defaults.size());
    // 用户排好的那部分保持原相对顺序。
    for (int i = 0; i < staleOrder.size(); ++i) {
        QCOMPARE(normalized.at(i), staleOrder.at(i));
    }
    // 缺的两页补在末尾，一个都不能少。
    QVERIFY(normalized.contains(droppedFirst));
    QVERIFY(normalized.contains(droppedSecond));
    QVERIFY(normalized.indexOf(droppedFirst) >= staleOrder.size());
    QVERIFY(normalized.indexOf(droppedSecond) >= staleOrder.size());

    // 空记录（首次启动、配置被清空）直接回落到出厂顺序。
    QCOMPARE(AppSettings::normalizeSidebarOrder(QStringList()), defaults);
}

void ServiceTests::appSettingsSidebarOrderDropsUnknownAndDuplicateIds()
{
    const QStringList defaults = AppSettings::defaultSidebarOrder();

    QStringList corrupt;
    corrupt << QStringLiteral("nonexistentPage")   // 降级运行或手改配置留下的
            << defaults.at(1)
            << defaults.at(1)                      // 重复：会让同一入口出现两次
            << QStringLiteral("")
            << defaults.at(0);

    const QStringList normalized = AppSettings::normalizeSidebarOrder(corrupt);
    QCOMPARE(normalized.size(), defaults.size());
    QCOMPARE(normalized.at(0), defaults.at(1));
    QCOMPARE(normalized.at(1), defaults.at(0));
    QVERIFY(!normalized.contains(QStringLiteral("nonexistentPage")));
    QVERIFY(!normalized.contains(QString()));
    // 每个已知页面恰好出现一次。
    for (const QString& id : defaults) {
        QCOMPARE(normalized.count(id), 1);
    }

    // 写入损坏值也要被纠正，而不是原样存回去。
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    AppSettings settings(dir.filePath(QStringLiteral("settings.ini")));
    settings.setSidebarOrder(corrupt);
    QCOMPARE(settings.sidebarOrder(), normalized);
}

void ServiceTests::appSettingsSidebarVisibleRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认展开，与首次打开的可发现性一致。
        QCOMPARE(settings.sidebarVisible(), true);

        QSignalSpy spy(&settings, &AppSettings::sidebarVisibleChanged);
        settings.setSidebarVisible(false);
        QCOMPARE(settings.sidebarVisible(), false);
        QCOMPARE(spy.count(), 1);

        settings.setSidebarVisible(false);
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.sidebarVisible(), false);
}

void ServiceTests::appSettingsDashboardTimerVisibleRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认展开，与首次打开的可发现性一致。
        QCOMPARE(settings.dashboardTimerVisible(), true);

        QSignalSpy spy(&settings, &AppSettings::dashboardTimerVisibleChanged);
        settings.setDashboardTimerVisible(false);
        QCOMPARE(settings.dashboardTimerVisible(), false);
        QCOMPARE(spy.count(), 1);

        settings.setDashboardTimerVisible(false);
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.dashboardTimerVisible(), false);
}

// 删掉「目标」页后，它留下的两个设置键再也没有读取方：构造时清掉，恢复备份后的 reload() 也清。
// 同在 shortcuts/ 分组里的其它快捷键覆盖不能被连带删掉。
void ServiceTests::appSettingsRemovesRetiredGoalSettings()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    {
        // 升级前的配置文件：目标页的版式偏好、改过的「切到长期目标」键位，以及一条无关的覆盖。
        QSettings legacy(path, QSettings::IniFormat);
        legacy.setValue(QStringLiteral("goals/viewMode"), QStringLiteral("grid"));
        legacy.setValue(QStringLiteral("shortcuts/view.goals"), QStringLiteral("Ctrl+Shift+8"));
        legacy.setValue(QStringLiteral("shortcuts/view.stats"), QStringLiteral("Ctrl+Shift+6"));
        legacy.setValue(QStringLiteral("appearance/sidebarOrder"),
                        QStringLiteral("goals,today,dashboard"));
        legacy.sync();
    }

    AppSettings settings(path);
    {
        QSettings onDisk(path, QSettings::IniFormat);
        QVERIFY(!onDisk.contains(QStringLiteral("goals/viewMode")));
        QVERIFY(!onDisk.contains(QStringLiteral("shortcuts/view.goals")));
        QCOMPARE(onDisk.value(QStringLiteral("shortcuts/view.stats")).toString(),
                 QStringLiteral("Ctrl+Shift+6"));
    }
    // 旧的侧栏顺序里的 goals 被丢掉：用户排过的在前，没排过的按出厂顺序补在后面。
    const QStringList order = settings.sidebarOrder();
    QVERIFY(!order.contains(QStringLiteral("goals")));
    QCOMPARE(order.mid(0, 2), QStringList({QStringLiteral("today"), QStringLiteral("dashboard")}));
    QCOMPARE(order.size(), AppSettings::defaultSidebarOrder().size());
    QVERIFY(!AppSettings::defaultSidebarOrder().contains(QStringLiteral("goals")));
    // goals/ 分组不再属于本应用：新备份不带它，恢复旧备份时直接跳过。
    QVERIFY(!AppSettings::isOwnedSettingKey(QStringLiteral("goals/viewMode")));

    // 恢复旧备份时 shortcuts/ 分组照常写回（它仍属于本应用），view.goals 会跟着回来。
    {
        QSettings restored(path, QSettings::IniFormat);
        restored.setValue(QStringLiteral("shortcuts/view.goals"), QStringLiteral("Ctrl+Shift+8"));
        restored.sync();
    }
    settings.reload();
    {
        QSettings onDisk(path, QSettings::IniFormat);
        QVERIFY(!onDisk.contains(QStringLiteral("shortcuts/view.goals")));
        QCOMPARE(onDisk.value(QStringLiteral("shortcuts/view.stats")).toString(),
                 QStringLiteral("Ctrl+Shift+6"));
    }
}

void ServiceTests::appSettingsDailyFocusGoalMinutesByDate()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-12")), 0);

        QSignalSpy spy(&settings, &AppSettings::dailyFocusGoalChanged);
        QVERIFY(!settings.setDailyFocusGoal(QString(), 140));
        QVERIFY(!settings.setDailyFocusGoal(QStringLiteral("2026-7-12"), 140));
        QVERIFY(!settings.setDailyFocusGoal(QStringLiteral("2026-07-12"), 0));
        QVERIFY(!settings.setDailyFocusGoal(QStringLiteral("2026-07-12"), 1441));
        QCOMPARE(spy.count(), 0);

        QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-12"), 140));
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-12")), 140);
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-13")), 0);
        QCOMPARE(spy.count(), 1);

        // 同值保存幂等，非法保存也不能覆盖已有合法目标。
        QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-12"), 140));
        QVERIFY(!settings.setDailyFocusGoal(QStringLiteral("2026-07-12"), -1));
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-12")), 140);
        QCOMPARE(spy.count(), 1);

        // 新逻辑日的目标另存一条历史，前一天的目标仍按日期读得到；24 小时整是合法上界。
        QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-13"), 1440));
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-12")), 140);
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-13")), 1440);
        QCOMPARE(spy.count(), 2);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-12")), 140);
    QCOMPARE(reloaded.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-13")), 1440);
}

namespace {
QByteArray settingsFileBytes(const QString& path)
{
    // 直接读磁盘字节，不能用共享同一缓存的 QSettings 来证明持久化结果。
    QFile disk(path);
    return disk.open(QIODevice::ReadOnly) ? disk.readAll() : QByteArray();
}

// 文件与父目录同时只读，阻断原地写入及 QSaveFile 的原子替换（与课表批量保存用例同一做法）。
bool lockSettingsForTest(const QString& path, const QString& dirPath,
                         QFileDevice::Permissions& filePermissions,
                         QFileDevice::Permissions& dirPermissions)
{
    filePermissions = QFile::permissions(path);
    dirPermissions = QFile::permissions(dirPath);
    if (!QFile::setPermissions(path, QFileDevice::ReadOwner)) {
        return false;
    }
    if (!QFile::setPermissions(dirPath, QFileDevice::ReadOwner | QFileDevice::ExeOwner)) {
        QFile::setPermissions(path, filePermissions);
        return false;
    }
    return true;
}

bool unlockSettingsForTest(const QString& path, const QString& dirPath,
                           QFileDevice::Permissions filePermissions,
                           QFileDevice::Permissions dirPermissions)
{
    const bool directoryRestored = QFile::setPermissions(dirPath, dirPermissions);
    const bool fileRestored = QFile::setPermissions(path, filePermissions);
    return directoryRestored && fileRestored;
}

// 某些账户（如 root）能绕过文件权限，锁了也写得进去；这时写入失败类用例按现有做法跳过。
bool settingsStillWritable(const QString& path)
{
    QFile probe(path);
    const bool writable = probe.open(QIODevice::WriteOnly | QIODevice::Append);
    probe.close();
    return writable;
}
}

void ServiceTests::appSettingsDailyGoalHistoryKeepsLastSavedValuePerDate()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-20"), 300));
        // 同一天改目标只留下最后成功保存的值，不记录修改轨迹。
        QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-20"), 360));
        QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-21"), 240));
        // 「沿用昨天」读的是前一天：今天已经设过目标也照样读得到。
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 360);
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-21")), 240);

        const QMap<QDate, int> goals =
            settings.dailyFocusGoalsBetween(QDate(2026, 7, 19), QDate(2026, 7, 22));
        QCOMPARE(goals.size(), 2);
        QCOMPARE(goals.value(QDate(2026, 7, 20)), 360);
        QCOMPARE(goals.value(QDate(2026, 7, 21)), 240);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 360);
    QCOMPARE(reloaded.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-21")), 240);
}

void ServiceTests::appSettingsDailyGoalRejectsCorruptStoredValues()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-01"), QStringLiteral("abc"));
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-02"), QStringLiteral("480.5"));
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-03"), 0);
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-04"), 1441);
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-05"), 480.5);
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-06"), QStringLiteral("+480"));
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-07"), 1);
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-08"), QStringLiteral("1440"));
        raw.sync();
    }

    AppSettings settings(path);
    // 小数不截断、越界不夹取、带符号或非数字一律不认：损坏值不能冒充真实目标。
    for (int day = 1; day <= 6; ++day) {
        const QString iso = QDate(2026, 7, day).toString(Qt::ISODate);
        QVERIFY2(settings.dailyFocusGoalMinutesForDate(iso) == 0, qPrintable(iso));
    }
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-07")), 1);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-08")), 1440);
    // 非严格 ISO 日期不认。
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-7-8")), 0);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-08T00:00:00")), 0);

    const QMap<QDate, int> goals =
        settings.dailyFocusGoalsBetween(QDate(2026, 7, 1), QDate(2026, 7, 8));
    QCOMPARE(goals.keys(), QList<QDate>({QDate(2026, 7, 7), QDate(2026, 7, 8)}));
}

void ServiceTests::appSettingsDailyGoalLegacyPairSyncsIntoHistory()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        // 模拟升级前：旧版本只写那一对键，历史里只有别的日期。
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/dailyGoalDate"), QStringLiteral("2026-07-20"));
        raw.setValue(QStringLiteral("focus/dailyGoalMinutes"), 300);
        raw.setValue(QStringLiteral("focus/dailyGoalHistory/2026-07-19"), 100);
        raw.sync();
    }

    AppSettings settings(path);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 300);
    // 启动时已把旧键对应的日期同步进历史并落盘。
    QVERIFY(settingsFileBytes(path).contains("2026-07-20=300"));

    {
        // 旧版本又把同一天改成 480：旧键与历史冲突时以旧值为准。
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/dailyGoalMinutes"), 480);
        raw.sync();
    }
    QSignalSpy changed(&settings, &AppSettings::dailyFocusGoalChanged);
    settings.reload();
    QCOMPARE(changed.count(), 1);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 480);
    QVERIFY(settingsFileBytes(path).contains("2026-07-20=480"));
    // 只处理旧键明确对应的日期，其余历史保留。
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-19")), 100);

    {
        // 无效旧键：日期指向 07-19、分钟数损坏。它不能覆盖 07-19 的有效历史。
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/dailyGoalDate"), QStringLiteral("2026-07-19"));
        raw.setValue(QStringLiteral("focus/dailyGoalMinutes"), QStringLiteral("abc"));
        raw.sync();
    }
    settings.reload();
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-19")), 100);
    QVERIFY(settingsFileBytes(path).contains("2026-07-19=100"));
}

void ServiceTests::appSettingsDailyGoalConsistentSyncDoesNotWrite()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    {
        AppSettings seed(path);
        QVERIFY(seed.setDailyFocusGoal(QStringLiteral("2026-07-20"), 300));
    }

    AppSettings settings(path);
    QSignalSpy failures(&settings, &AppSettings::settingsWriteFailed);
    QFileDevice::Permissions filePermissions;
    QFileDevice::Permissions dirPermissions;
    QVERIFY(lockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    const bool bypassed = settingsStillWritable(path);
    // 旧键与历史已经一致：重载时不写盘，只读的设置文件也就不会报写入失败。
    settings.reload();
    QVERIFY(unlockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    if (bypassed) {
        QSKIP("当前账户可绕过文件权限，无法证明重载没有写盘");
    }
    QCOMPARE(failures.count(), 0);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 300);
}

void ServiceTests::appSettingsDailyGoalSameValueSaveRepairsMissingHistory()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    AppSettings settings(path);
    QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-20"), 480));
    {
        // 模拟升级前就是这个值：旧键已是 480，历史键却不存在。
        // 同一进程里同一份 ini 的 QSettings 共享缓存，删掉后 settings 立刻看不到这个键。
        QSettings raw(path, QSettings::IniFormat);
        raw.remove(QStringLiteral("focus/dailyGoalHistory/2026-07-20"));
        raw.sync();
    }
    QVERIFY(!settingsFileBytes(path).contains("2026-07-20=480"));

    // 同值保存不能只比旧键就提前返回，缺失的历史必须补写。
    QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-20"), 480));
    QVERIFY(settingsFileBytes(path).contains("2026-07-20=480"));
}

void ServiceTests::appSettingsDailyGoalSaveFailureRestoresCacheAndRetries()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    AppSettings settings(path);
    QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-20"), 300));
    const QByteArray originalBytes = settingsFileBytes(path);
    QVERIFY(!originalBytes.isEmpty());
    QSignalSpy failures(&settings, &AppSettings::settingsWriteFailed);
    QSignalSpy successes(&settings, &AppSettings::settingsWriteSucceeded);
    QSignalSpy changes(&settings, &AppSettings::dailyFocusGoalChanged);

    QFileDevice::Permissions filePermissions;
    QFileDevice::Permissions dirPermissions;
    QVERIFY(lockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    const bool saved = settings.setDailyFocusGoal(QStringLiteral("2026-07-21"), 480);
    const int failedToday = settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-21"));
    const int failedYesterday = settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20"));
    const bool leakedHistoryKey = QSettings(path, QSettings::IniFormat)
                                      .contains(QStringLiteral("focus/dailyGoalHistory/2026-07-21"));
    // 先恢复权限再断言，确保用例失败时临时目录也能正常清理。
    QVERIFY(unlockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    if (saved) {
        QSKIP("当前账户可绕过文件权限，无法模拟写入失败");
    }

    // 失败后缓存回到原值：没落盘的目标不能成为「最后成功保存」的值。
    QCOMPARE(failedToday, 0);
    QCOMPARE(failedYesterday, 300);
    QVERIFY(!leakedHistoryKey);
    QCOMPARE(settingsFileBytes(path), originalBytes);
    QCOMPARE(failures.count(), 1);
    QCOMPARE(successes.count(), 0);
    QCOMPARE(changes.count(), 0);

    // 恢复写入条件后，同一个对象直接重试成功。
    QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-21"), 480));
    QCOMPARE(changes.count(), 1);
    const QByteArray newBytes = settingsFileBytes(path);
    QVERIFY(newBytes.contains("2026-07-21=480"));
    QVERIFY(newBytes.contains("2026-07-20=300"));
}

void ServiceTests::appSettingsDailyGoalSyncFailureIsReportedAndRetried()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    AppSettings settings(path);
    QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-20"), 300));
    {
        // 旧版本把同一天改成 480，只写旧键。
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/dailyGoalMinutes"), 480);
        raw.sync();
    }

    QSignalSpy failures(&settings, &AppSettings::settingsWriteFailed);
    QFileDevice::Permissions filePermissions;
    QFileDevice::Permissions dirPermissions;
    QVERIFY(lockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    settings.reload();
    const int duringFailure = settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20"));
    QVERIFY(unlockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    if (failures.count() == 0) {
        QSKIP("当前账户可绕过文件权限，无法模拟同步失败");
    }

    // 同步失败必须可见；没写成期间，读取对该日期仍以旧值为准。
    QCOMPARE(failures.count(), 1);
    QCOMPARE(duringFailure, 480);
    QVERIFY(settingsFileBytes(path).contains("2026-07-20=300"));

    // 重试一：恢复权限后再次重载完成同步。
    settings.reload();
    QCOMPARE(failures.count(), 1);
    QVERIFY(settingsFileBytes(path).contains("2026-07-20=480"));

    // 重试二：同步又失败时，保存另一天的目标会把旧键记着的那一天一并补上，
    // 否则旧键一被今天覆盖，那一天的目标就永久丢失。
    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/dailyGoalMinutes"), 500);
        raw.sync();
    }
    QVERIFY(lockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    settings.reload();
    QVERIFY(unlockSettingsForTest(path, dir.path(), filePermissions, dirPermissions));
    QCOMPARE(failures.count(), 2);
    QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-21"), 240));
    const QByteArray bytes = settingsFileBytes(path);
    QVERIFY(bytes.contains("2026-07-20=500"));
    QVERIFY(bytes.contains("2026-07-21=240"));
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 500);
}

void ServiceTests::appSettingsDailyGoalOldVersionRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    AppSettings settings(path);
    QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-20"), 300));
    {
        // 旧版本连续用了两天：只写旧的一对键，第二天把第一天覆盖掉。
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/dailyGoalDate"), QStringLiteral("2026-07-21"));
        raw.setValue(QStringLiteral("focus/dailyGoalMinutes"), 200);
        raw.sync();
        raw.setValue(QStringLiteral("focus/dailyGoalDate"), QStringLiteral("2026-07-22"));
        raw.setValue(QStringLiteral("focus/dailyGoalMinutes"), 250);
        raw.sync();
    }

    settings.reload();
    // 新版本留下的历史保留；旧版本最后留下的日期同步进来；中间被覆盖的那一天无法恢复，不补造。
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-20")), 300);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-21")), 0);
    QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-22")), 250);
    const QByteArray bytes = settingsFileBytes(path);
    QVERIFY(bytes.contains("2026-07-22=250"));
    QVERIFY(!bytes.contains("2026-07-21="));
}

void ServiceTests::appSettingsBackgroundThemeDefaultAndRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认主题 ID 必须和 Theme.backgroundThemes 的真实首项一致，避免首次启动触发迁移写回。
        QCOMPARE(settings.backgroundTheme(), QStringLiteral("warm"));

        QSignalSpy spy(&settings, &AppSettings::backgroundThemeChanged);
        settings.setBackgroundTheme(QStringLiteral("celadon"));
        QCOMPARE(settings.backgroundTheme(), QStringLiteral("celadon"));
        QCOMPARE(spy.count(), 1);

        // 同值写入不重复发信号（与其它偏好一致）。
        settings.setBackgroundTheme(QStringLiteral("celadon"));
        QCOMPARE(spy.count(), 1);
    }

    // 重建实例验证持久化。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.backgroundTheme(), QStringLiteral("celadon"));
}

void ServiceTests::appSettingsDayStartHourNormalizeAndPersist()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.dayStartHour(), 4);

        QSignalSpy spy(&settings, &AppSettings::dayStartHourChanged);
        settings.setDayStartHour(5);
        QCOMPARE(settings.dayStartHour(), 5);
        QCOMPARE(spy.count(), 1);

        // 归一化不是 clamp：越界配置视为损坏，一律回默认值 4。
        settings.setDayStartHour(99);
        QCOMPARE(settings.dayStartHour(), 4);
        settings.setDayStartHour(-1);
        QCOMPARE(settings.dayStartHour(), 4);

        const int countBefore = spy.count();
        settings.setDayStartHour(4);
        QCOMPARE(spy.count(), countBefore);

        settings.setDayStartHour(6);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.dayStartHour(), 6);
}

void ServiceTests::appSettingsDayStartHourRejectsCorruptIniValue()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    // 坏值可能来自旧版本或手工编辑，读取入口必须统一归一化。
    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("logic/dayStartHour"), 99);
        raw.sync();
    }

    AppSettings settings(path);
    QCOMPARE(settings.dayStartHour(), 4);
}

void ServiceTests::appSettingsFocusDurationsNormalizeCorruptValues()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    // 旧版本或手工编辑可能留下越界值；读取入口不能把它们传给计时器。
    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/workMinutes"), 181);
        raw.setValue(QStringLiteral("focus/breakMinutes"), 0);
        raw.sync();
    }

    AppSettings settings(path);
    QCOMPARE(settings.workMinutes(), 25);
    QCOMPARE(settings.breakMinutes(), 5);

    QSignalSpy workSpy(&settings, &AppSettings::workMinutesChanged);
    QSignalSpy breakSpy(&settings, &AppSettings::breakMinutesChanged);
    settings.setWorkMinutes(4);
    settings.setBreakMinutes(61);
    QCOMPARE(settings.workMinutes(), 25);
    QCOMPARE(settings.breakMinutes(), 5);
    QCOMPARE(workSpy.count(), 0);
    QCOMPARE(breakSpy.count(), 0);
}

void ServiceTests::appSettingsFreeTimerWarningHoursDefaultsAndNormalizes()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.freeTimerWarningHours(), 8);

        QSignalSpy spy(&settings, &AppSettings::freeTimerWarningHoursChanged);
        settings.setFreeTimerWarningHours(12);
        QCOMPARE(settings.freeTimerWarningHours(), 12);
        QCOMPARE(spy.count(), 1);

        // 越界值视为配置损坏并回到默认 8 小时，不夹到 1 或 24。
        settings.setFreeTimerWarningHours(0);
        QCOMPARE(settings.freeTimerWarningHours(), 8);
        QCOMPARE(spy.count(), 2);
        settings.setFreeTimerWarningHours(25);
        QCOMPARE(spy.count(), 2);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.freeTimerWarningHours(), 8);
}

void ServiceTests::appSettingsWriteFailureDoesNotEmitSuccess()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 把现有目录当作 ini 文件路径会稳定触发 QSettings::AccessError，覆盖真实的磁盘写入失败路径。
    AppSettings settings(dir.path());
    QSignalSpy changedSpy(&settings, &AppSettings::soundEnabledChanged);
    QSignalSpy successSpy(&settings, &AppSettings::settingsWriteSucceeded);
    QSignalSpy failureSpy(&settings, &AppSettings::settingsWriteFailed);

    settings.setSoundEnabled(false);

    QCOMPARE(changedSpy.count(), 0);
    QCOMPARE(successSpy.count(), 0);
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(failureSpy.first().at(0).toString(), QStringLiteral("focus/soundEnabled"));
    QCOMPARE(settings.soundEnabled(), true);
}

void ServiceTests::appSettingsScheduleBatchReportsFailureWithoutChangingValues()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 目录不能当 INI 文件写入，用它稳定触发 AccessError。
    AppSettings settings(dir.path());
    QSignalSpy failureSpy(&settings, &AppSettings::settingsWriteFailed);
    QSignalSpy startSpy(&settings, &AppSettings::semesterStartDateChanged);
    QSignalSpy weeksSpy(&settings, &AppSettings::semesterWeeksChanged);
    QSignalSpy weekendSpy(&settings, &AppSettings::scheduleShowWeekendChanged);

    QVERIFY(!settings.saveScheduleSettings(QStringLiteral("2026-08-31"), 16, false));
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(startSpy.count(), 0);
    QCOMPARE(weeksSpy.count(), 0);
    QCOMPARE(weekendSpy.count(), 0);
    QVERIFY(settings.semesterStartDate().isEmpty());
    QCOMPARE(settings.semesterWeeks(), 20);
    QCOMPARE(settings.scheduleShowWeekend(), true);
}

void ServiceTests::appSettingsScheduleBatchRetriesExistingReadOnlyFile()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    AppSettings settings(path);
    QVERIFY(settings.saveScheduleSettings(QStringLiteral("2026-08-31"), 20, true));
    QFile disk(path);
    QVERIFY(disk.open(QIODevice::ReadOnly));
    const QByteArray originalBytes = disk.readAll();
    disk.close();
    QSignalSpy changes(&settings, &AppSettings::semesterWeeksChanged);

    // 文件和父目录同时只读，阻断原地写入及 QSaveFile 的原子替换。
    // 先恢复权限再断言，确保用例失败时临时目录也能正常清理。
    const auto filePermissions = QFile::permissions(path);
    const auto dirPermissions = QFile::permissions(dir.path());
    QVERIFY(QFile::setPermissions(path, QFileDevice::ReadOwner));
    const bool directoryLocked = QFile::setPermissions(dir.path(), QFileDevice::ReadOwner | QFileDevice::ExeOwner);
    if (!directoryLocked) {
        QFile::setPermissions(path, filePermissions);
        QFAIL("无法设置测试目录权限");
    }
    const bool saved = settings.saveScheduleSettings(QStringLiteral("2026-09-07"), 16, false);
    const QString failedStart = settings.semesterStartDate();
    const int failedWeeks = settings.semesterWeeks();
    const bool failedWeekend = settings.scheduleShowWeekend();
    const bool directoryRestored = QFile::setPermissions(dir.path(), dirPermissions);
    const bool fileRestored = QFile::setPermissions(path, filePermissions);
    QVERIFY(directoryRestored && fileRestored);
    if (saved) {
        QSKIP("当前账户可绕过文件权限，无法模拟写入失败");
    }
    QCOMPARE(changes.count(), 0);
    QCOMPARE(failedStart, QStringLiteral("2026-08-31"));
    QCOMPARE(failedWeeks, 20);
    QCOMPARE(failedWeekend, true);
    QVERIFY(disk.open(QIODevice::ReadOnly));
    QCOMPARE(disk.readAll(), originalBytes);
    disk.close();

    QVERIFY(settings.saveScheduleSettings(QStringLiteral("2026-09-07"), 16, false));
    QCOMPARE(changes.count(), 1);
    // 直接读磁盘字节，不能再用共享同一缓存的 QSettings 来证明持久化成功。
    QVERIFY(disk.open(QIODevice::ReadOnly));
    const QByteArray newBytes = disk.readAll();
    QVERIFY(newBytes.contains("semesterStartDate=2026-09-07"));
    QVERIFY(newBytes.contains("semesterWeeks=16"));
    QVERIFY(newBytes.contains("showWeekend=false"));
}

void ServiceTests::appSettingsScheduleBatchPersistsBeforeEmittingChanges()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    AppSettings settings(path);

    QSignalSpy successSpy(&settings, &AppSettings::settingsWriteSucceeded);
    QSignalSpy startSpy(&settings, &AppSettings::semesterStartDateChanged);
    QSignalSpy weeksSpy(&settings, &AppSettings::semesterWeeksChanged);
    QSignalSpy weekendSpy(&settings, &AppSettings::scheduleShowWeekendChanged);

    QVERIFY(settings.saveScheduleSettings(QStringLiteral("2026-09-02"), 16, false));
    QCOMPARE(successSpy.count(), 1);
    QCOMPARE(startSpy.count(), 1);
    QCOMPARE(weeksSpy.count(), 1);
    QCOMPARE(weekendSpy.count(), 1);

    // 起始日在同一次批量写入中规范化到周一，新建对象能直接读到全套值。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.semesterStartDate(), QStringLiteral("2026-08-31"));
    QCOMPARE(reloaded.semesterWeeks(), 16);
    QCOMPARE(reloaded.scheduleShowWeekend(), false);
}

void ServiceTests::appSettingsCanRetryAfterWriteFailure()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    QVERIFY(QDir().mkpath(path));

    AppSettings settings(path);
    QSignalSpy failureSpy(&settings, &AppSettings::settingsWriteFailed);
    QSignalSpy successSpy(&settings, &AppSettings::settingsWriteSucceeded);

    settings.setSoundEnabled(false);
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(settings.soundEnabled(), true);

    // 模拟用户修复目录/权限。后端对象若保留粘滞 AccessError，这次写入仍会失败直到重启。
    QVERIFY(QDir(path).removeRecursively());
    settings.setSoundEnabled(false);
    QCOMPARE(successSpy.count(), 1);
    QCOMPARE(settings.soundEnabled(), false);

    AppSettings reloaded(path);
    QCOMPARE(reloaded.soundEnabled(), false);
}

void ServiceTests::appSettingsReduceTransparencyRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.reduceTransparency(), false);

        QSignalSpy spy(&settings, &AppSettings::reduceTransparencyChanged);
        settings.setReduceTransparency(true);
        QCOMPARE(settings.reduceTransparency(), true);
        QCOMPARE(spy.count(), 1);

        settings.setReduceTransparency(true);
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.reduceTransparency(), true);
}

void ServiceTests::appSettingsRaiseOnPhaseCompleteDefaultsOnAndRoundTrips()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认开启：保留既有“阶段结束置前”提醒。
        QCOMPARE(settings.raiseOnPhaseComplete(), true);

        QSignalSpy spy(&settings, &AppSettings::raiseOnPhaseCompleteChanged);
        settings.setRaiseOnPhaseComplete(false);
        QCOMPARE(settings.raiseOnPhaseComplete(), false);
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.raiseOnPhaseComplete(), false);
}

void ServiceTests::appSettingsCloseToTrayDefaultsOffAndRoundTrips()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 标准关闭默认结束应用；菜单栏驻留必须由用户明确开启。
        QCOMPARE(settings.closeToTray(), false);

        QSignalSpy spy(&settings, &AppSettings::closeToTrayChanged);
        settings.setCloseToTray(true);
        QCOMPARE(settings.closeToTray(), true);
        QCOMPARE(spy.count(), 1);

        settings.setCloseToTray(true);
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.closeToTray(), true);
}

void ServiceTests::appSettingsNaturalCompletionNoticeRoundTripsAndReloads()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.naturalCompletionNoticeShown(), false);

        QSignalSpy changedSpy(&settings, &AppSettings::naturalCompletionNoticeShownChanged);
        settings.setNaturalCompletionNoticeShown(true);
        QCOMPARE(settings.naturalCompletionNoticeShown(), true);
        QCOMPARE(changedSpy.count(), 1);

        // 重复确认不能写盘或再次广播；否则 Loader 可能被无意义地重建。
        settings.setNaturalCompletionNoticeShown(true);
        QCOMPARE(changedSpy.count(), 1);

        // 数据恢复会重建 QSettings 后端，所有绑定都必须收到一次刷新通知。
        settings.reload();
        QCOMPARE(changedSpy.count(), 2);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.naturalCompletionNoticeShown(), true);
}

void ServiceTests::appSettingsAutoStartDefaultsOffAndRoundTrips()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 自动衔接默认关闭，避免打断用户手动确认节奏。
        QCOMPARE(settings.autoStartBreak(), false);
        QCOMPARE(settings.autoStartNextPomodoro(), false);

        QSignalSpy breakSpy(&settings, &AppSettings::autoStartBreakChanged);
        QSignalSpy nextSpy(&settings, &AppSettings::autoStartNextPomodoroChanged);
        settings.setAutoStartBreak(true);
        settings.setAutoStartNextPomodoro(true);
        QCOMPARE(breakSpy.count(), 1);
        QCOMPARE(nextSpy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.autoStartBreak(), true);
    QCOMPARE(reloaded.autoStartNextPomodoro(), true);
}

void ServiceTests::appSettingsQuickStartDefaultsOffAndRoundTrips()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认关闭：从任务点「开始专注」先进入待机，由用户确认模式和时长。
        QCOMPARE(settings.quickStartEnabled(), false);

        QSignalSpy spy(&settings, &AppSettings::quickStartEnabledChanged);
        settings.setQuickStartEnabled(true);
        QCOMPARE(spy.count(), 1);
        // 值没变不重复通知，避免设置页开关来回抖动。
        settings.setQuickStartEnabled(true);
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.quickStartEnabled(), true);
    // 放在 focus 分组下，才会跟着备份与恢复一起走。
    QVERIFY(AppSettings::isOwnedSettingKey(QStringLiteral("focus/quickStartEnabled")));
}

void ServiceTests::appSettingsLongBreakDefaultsAndNormalizes()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认：长休息开启，15 分钟，每 4 个番茄一次。
        QCOMPARE(settings.longBreakEnabled(), true);
        QCOMPARE(settings.longBreakMinutes(), 15);
        QCOMPARE(settings.longBreakInterval(), 4);

        settings.setLongBreakEnabled(false);
        settings.setLongBreakMinutes(20);
        settings.setLongBreakInterval(3);
        QCOMPARE(settings.longBreakEnabled(), false);
        QCOMPARE(settings.longBreakMinutes(), 20);
        QCOMPARE(settings.longBreakInterval(), 3);
    }

    // 落盘验证：重新构造读取到的仍是设定值，不是当前对象缓存。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.longBreakEnabled(), false);
    QCOMPARE(reloaded.longBreakMinutes(), 20);
    QCOMPARE(reloaded.longBreakInterval(), 3);

    // 坏值可能来自旧版本或手工编辑，读取入口必须归一化回默认；
    // 再写入同样越界的值会被归一化成默认（等于当前值），因此不触发 changed。
    QTemporaryDir corruptDir;
    QVERIFY(corruptDir.isValid());
    const QString corruptPath = corruptDir.filePath(QStringLiteral("settings.ini"));
    {
        QSettings raw(corruptPath, QSettings::IniFormat);
        raw.setValue(QStringLiteral("focus/longBreakMinutes"), 999);
        raw.setValue(QStringLiteral("focus/longBreakInterval"), 1);
        raw.sync();
    }

    AppSettings corrupt(corruptPath);
    QCOMPARE(corrupt.longBreakMinutes(), 15);
    QCOMPARE(corrupt.longBreakInterval(), 4);

    QSignalSpy minutesSpy(&corrupt, &AppSettings::longBreakMinutesChanged);
    QSignalSpy intervalSpy(&corrupt, &AppSettings::longBreakIntervalChanged);
    corrupt.setLongBreakMinutes(4);   // 越界 → 归一化 15，等于当前默认，静默无操作
    corrupt.setLongBreakInterval(9);  // 越界 → 归一化 4，等于当前默认，静默无操作
    QCOMPARE(corrupt.longBreakMinutes(), 15);
    QCOMPARE(corrupt.longBreakInterval(), 4);
    QCOMPARE(minutesSpy.count(), 0);
    QCOMPARE(intervalSpy.count(), 0);
}

void ServiceTests::logicalDayDateOfBoundaries()
{
    const QDate day(2026, 7, 8);

    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(3, 59)), 4), day.addDays(-1));
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(4, 0)), 4), day);
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(0, 0)), 0), day);
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(5, 59)), 6), day.addDays(-1));
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(6, 0)), 6), day);

    QCOMPARE(LogicalDay::dateOf(QDateTime(QDate(2026, 8, 1), QTime(1, 0)), 4),
             QDate(2026, 7, 31));
    QCOMPARE(LogicalDay::dateOf(QDateTime(QDate(2027, 1, 1), QTime(2, 30)), 4),
             QDate(2026, 12, 31));

    // 用调用前后时刻包围薄包装结果，避免恰好跨过日界点时出现竞态假失败。
    const QDateTime before = QDateTime::currentDateTime();
    const QDate actualToday = LogicalDay::today(4);
    const QDateTime after = QDateTime::currentDateTime();
    const QDate expectedBefore = LogicalDay::dateOf(before, 4);
    const QDate expectedAfter = LogicalDay::dateOf(after, 4);
    QVERIFY(actualToday == expectedBefore || actualToday == expectedAfter);

    QCOMPARE(LogicalDay::sqlShift(4), QStringLiteral("-4 hours"));
    QCOMPARE(LogicalDay::sqlShift(0), QStringLiteral("-0 hours"));
}

void ServiceTests::logicalDayMsUntilNextBoundary()
{
    const QDate day(2026, 7, 8);

    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(2, 0)), 4),
             qint64(2) * 3600 * 1000);
    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(5, 0)), 4),
             qint64(23) * 3600 * 1000);
    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(4, 0)), 4),
             qint64(24) * 3600 * 1000);
}

void ServiceTests::logicalDayHandlesDstFallBackByWallClock()
{
    const QTimeZone newYork("America/New_York");
    QVERIFY(newYork.isValid());
    const QDateTime afterFallback(QDate(2026, 11, 1), QTime(3, 30), newYork,
                                  QDateTime::TransitionResolution::PreferStandard);

    // 回拨日 03:30 的墙钟仍早于 04:00，必须归前一天；减固定四小时会错误落在当天。
    QCOMPARE(LogicalDay::dateOf(afterFallback, 4), QDate(2026, 10, 31));
    QCOMPARE(LogicalDay::msUntilNextBoundary(afterFallback, 4), qint64(30) * 60 * 1000);
}

void ServiceTests::logicalDayServiceSchedulesTimerOnConstruction()
{
    LogicalDayService service;
    auto* timer = service.findChild<QTimer*>(QStringLiteral("logicalDayBoundaryTimer"));
    QVERIFY(timer);
    QVERIFY(timer->isActive());
}

void ServiceTests::logicalDayServiceEmitsChangedOnDayStartHourChange()
{
    AppSettings::instance()->setDayStartHour(4);
    // 先确认起点真的写进去了。写盘失败时值会停在别处，后面"改成 5"就可能是空操作，
    // 用例会以"没收到信号"的形式失败，把一个环境问题伪装成产品缺陷。
    QCOMPARE(AppSettings::instance()->dayStartHour(), 4);

    LogicalDayService service;
    QSignalSpy spy(&service, &LogicalDayService::changed);

    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(spy.count(), 1);

    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(spy.count(), 1);
}

void ServiceTests::logicalDayChangeMaterializesRoutineIdempotently()
{
    // 选择距下一界点最远的合法小时，避免测试执行中恰好跨日。
    const QDateTime now = QDateTime::currentDateTime();
    int safeHour = 0;
    qint64 longestDelay = -1;
    for (int hour = 0; hour <= 6; ++hour) {
        const qint64 delay = LogicalDay::msUntilNextBoundary(now, hour);
        if (delay > longestDelay) {
            longestDelay = delay;
            safeHour = hour;
        }
    }
    AppSettings::instance()->setDayStartHour(safeHour);
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("失效补例行"), -1));

    LogicalDayService service;
    connect(&service, &LogicalDayService::changed,
            RoutineManager::instance(), &RoutineManager::materializeToday);

    auto countRoutineTasks = []() {
        QSqlQuery query(DatabaseManager::instance()->database());
        if (!query.exec(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '失效补例行'"))
            || !query.next()) {
            return -1;
        }
        return query.value(0).toInt();
    };

    QCOMPARE(countRoutineTasks(), 0);

    service.changed();
    QCOMPARE(countRoutineTasks(), 1);

    QSqlQuery taskDate(DatabaseManager::instance()->database());
    QVERIFY(taskDate.exec(QStringLiteral(
        "SELECT date FROM tasks WHERE title = '失效补例行'")));
    QVERIFY(taskDate.next());
    QCOMPARE(taskDate.value(0).toString(), logicalToday().toString(Qt::ISODate));

    QSqlQuery generatedDate(DatabaseManager::instance()->database());
    QVERIFY(generatedDate.exec(QStringLiteral(
        "SELECT last_generated_date FROM routines WHERE title = '失效补例行'")));
    QVERIFY(generatedDate.next());
    QCOMPARE(generatedDate.value(0).toString(), logicalToday().toString(Qt::ISODate));

    service.changed();
    QCOMPARE(countRoutineTasks(), 1);
}

void ServiceTests::addTaskRejectsBlankTitle()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    QVERIFY(!TaskManager::instance()->addTask("   ", QVariant(logicalToday()), "数学"));

    QCOMPARE(spy.count(), 0);
    QCOMPARE(TaskManager::instance()->getTodayTasks().size(), 0);
}

void ServiceTests::addTaskPersistsTrimmedTitleAndEmitsChange()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    QVERIFY(TaskManager::instance()->addTask("  数据结构第三章  ", QVariant(logicalToday()), "数据结构"));

    QCOMPARE(spy.count(), 1);
    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value("title").toString(), QString("数据结构第三章"));
    QCOMPARE(task.value("categoryText").toString(), QString("数据结构"));
    QCOMPARE(task.value("category").toMap().value("name").toString(), QString("数据结构"));
    QCOMPARE(task.value("completed").toBool(), false);
}

void ServiceTests::addTaskAcceptsIsoDateStringFromQml()
{
    const QString today = logicalToday().toString(Qt::ISODate);

    QVERIFY(TaskManager::instance()->addTask("政治选择题", today, "政治"));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value("title").toString(), QString("政治选择题"));
}

void ServiceTests::createTaskReturnsTheIdOfTheRowItJustInserted()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    const int newId = TaskManager::instance()->createTask(
        QStringLiteral("  线代第四章  "), QVariant(logicalToday()), -1, 45, QStringLiteral("例题 3"));

    QVERIFY(newId > 0);
    QCOMPARE(spy.count(), 1);

    // 返回的编号必须指向刚插入的那一行本身，不是"某条标题相同的任务"。
    const QVariantMap task = TaskManager::instance()->getTask(newId);
    QCOMPARE(task.value("id").toInt(), newId);
    QCOMPARE(task.value("title").toString(), QStringLiteral("线代第四章"));
    QCOMPARE(task.value("estimatedMinutes").toInt(), 45);
    QCOMPARE(task.value("notes").toString(), QStringLiteral("例题 3"));
}

void ServiceTests::createTaskDistinguishesSameTitleTasksOnTheSameDay()
{
    // 标题不是身份。同一天允许两条同名任务，调用方必须能分清自己刚建的是哪一条——
    // 这正是"按标题反查"给不出的保证：它只能在一堆同名任务里挑一个，挑错也没人知道。
    const QDate today = logicalToday();
    const int firstId = TaskManager::instance()->createTask(
        QStringLiteral("英语真题"), QVariant(today), -1, 0, QString());
    const int secondId = TaskManager::instance()->createTask(
        QStringLiteral("英语真题"), QVariant(today), -1, 0, QString());

    QVERIFY(firstId > 0);
    QVERIFY(secondId > 0);
    QVERIFY(firstId != secondId);

    // 两条都真实存在，后建的那条排在后面。
    QCOMPARE(TaskManager::instance()->getTodayTasks().size(), 2);
    QSqlQuery order(DatabaseManager::instance()->database());
    order.prepare(QStringLiteral("SELECT display_order FROM tasks WHERE id = :id"));
    order.bindValue(QStringLiteral(":id"), firstId);
    QVERIFY(order.exec());
    QVERIFY(order.next());
    const int firstOrder = order.value(0).toInt();
    order.bindValue(QStringLiteral(":id"), secondId);
    QVERIFY(order.exec());
    QVERIFY(order.next());
    QVERIFY(order.value(0).toInt() > firstOrder);
}

void ServiceTests::createTaskReportsFailureWithNegativeId()
{
    QSignalSpy spy(TaskManager::instance(), &TaskManager::tasksChanged);

    // 失败一律返回 -1，不返回 0：调用方统一按 id > 0 判成功。
    QCOMPARE(TaskManager::instance()->createTask(
                 QStringLiteral("   "), QVariant(logicalToday()), -1, 0, QString()), -1);
    QCOMPARE(TaskManager::instance()->createTask(
                 QStringLiteral("日期非法"), QVariant(QStringLiteral("不是日期")), -1, 0, QString()), -1);

    QCOMPARE(spy.count(), 0);
    QCOMPARE(TaskManager::instance()->getTodayTasks().size(), 0);
}

void ServiceTests::deleteTaskPreservesFocusSessionHistory()
{
    QVERIFY(TaskManager::instance()->addTask("操作系统真题", QVariant(logicalToday()), "操作系统"));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value("id").toInt();

    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, 1200)"));
    insert.bindValue(QStringLiteral(":taskId"), taskId);
    insert.bindValue(QStringLiteral(":startTime"), dateTimeText(logicalToday()));
    insert.bindValue(QStringLiteral(":endTime"), dateTimeText(logicalToday(), QStringLiteral("12:30:00")));
    QVERIFY(insert.exec());

    QVERIFY(TaskManager::instance()->deleteTask(taskId));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec("SELECT task_id, duration FROM focus_sessions"));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());
    QCOMPARE(query.value(1).toInt(), 1200);
}

void ServiceTests::statisticsReturnsTodayCompletionAndDuration()
{
    const QDate today = logicalToday();
    QVERIFY(TaskManager::instance()->addTask("英语阅读", QVariant(today), "英语"));
    QVERIFY(TaskManager::instance()->addTask("数学错题", QVariant(today), "数学"));
    // TaskManager 的无参“今天”要到计划二才切换；本用例只验证 StatisticsService。
    const QVariantList tasks = TaskManager::instance()->getTasksByDate(today);
    QVERIFY(TaskManager::instance()->completeTask(tasks.first().toMap().value("id").toInt()));

    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (NULL, :startTime, :endTime, 1800)"));
    insert.bindValue(QStringLiteral(":startTime"), dateTimeText(today));
    insert.bindValue(QStringLiteral(":endTime"), dateTimeText(today, QStringLiteral("12:30:00")));
    QVERIFY(insert.exec());

    const QVariantMap stats = StatisticsService::instance()->getTodayStats();
    QCOMPARE(stats.value("totalDuration").toInt(), 1800);
    QCOMPARE(stats.value("completedTasks").toInt(), 1);
    QCOMPARE(stats.value("totalTasks").toInt(), 2);
    QCOMPARE(stats.value("completionRate").toDouble(), 0.5);
}

void ServiceTests::statisticsBucketsSessionsByLogicalDay()
{
    AppSettings::instance()->setDayStartHour(4);
    StatisticsService* service = StatisticsService::instance();

    const QDate day(2026, 7, 8);
    const int taskId = insertTaskRow(QStringLiteral("凌晨自习"), day, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("01:00:00"),
                                    QStringLiteral("01:25:00"), 1500));
    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("05:00:00"),
                                    QStringLiteral("05:15:00"), 900));

    QCOMPARE(service->getDayStats(day.addDays(-1)).value(QStringLiteral("totalDuration")).toInt(),
             1500);
    QCOMPARE(service->getDayStats(day).value(QStringLiteral("totalDuration")).toInt(), 900);

    QCOMPARE(service->getFocusSessionCount(day.addDays(-1), day.addDays(-1)), 1);
    QCOMPARE(service->getFocusSessionCount(day, day), 1);

    QCOMPARE(service->getEffectiveDays(day.addDays(-1), day), 2);
    QCOMPARE(service->getEffectiveDays(day.addDays(-1), day.addDays(-1)), 1);

    const QVariantMap categoryStats = service->getCategoryStats(
        day.addDays(-1).toString(Qt::ISODate), day.addDays(-1).toString(Qt::ISODate));
    QCOMPARE(categoryStats.value(QStringLiteral("totalDuration")).toInt(), 1500);
}

void ServiceTests::statisticsTodayUsesLogicalToday()
{
    AppSettings::instance()->setDayStartHour(4);
    StatisticsService* service = StatisticsService::instance();

    const QDate today = LogicalDay::today(4);
    const int taskId = insertTaskRow(QStringLiteral("今日等价"), today, QStringLiteral("英语"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, today, QStringLiteral("12:00:00"),
                                    QStringLiteral("12:30:00"), 1800));

    QCOMPARE(service->getTodayStats(), service->getDayStats(today));
}

void ServiceTests::getDayStatsUsesSpecifiedHistoricalDate()
{
    const QDate targetDate(2026, 6, 10);
    const QDate otherDate = targetDate.addDays(1);
    const int completedTaskId = insertTaskRow(QStringLiteral("历史完成任务"),
                                              targetDate,
                                              QStringLiteral("数学"),
                                              true);
    const int pendingTaskId = insertTaskRow(QStringLiteral("历史未完成任务"),
                                            targetDate,
                                            QStringLiteral("英语"));
    const int otherTaskId = insertTaskRow(QStringLiteral("其他日期任务"),
                                          otherDate,
                                          QStringLiteral("政治"),
                                          true);
    QVERIFY(completedTaskId > 0);
    QVERIFY(pendingTaskId > 0);
    QVERIFY(otherTaskId > 0);

    QVERIFY(insertFocusSessionRow(completedTaskId, targetDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(pendingTaskId, targetDate, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(otherTaskId, otherDate, kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(completedTaskId, targetDate, kTestMinimumValidDurationSeconds - 1));

    const QVariantMap stats = StatisticsService::instance()->getDayStats(targetDate);

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds * 3);
    QCOMPARE(stats.value(QStringLiteral("sessionCount")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completedTasks")).toInt(), 1);
    QCOMPARE(stats.value(QStringLiteral("totalTasks")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completionRate")).toDouble(), 0.5);

    const QVariantMap invalidStats = StatisticsService::instance()->getDayStats(QDate());
    QCOMPARE(invalidStats.value(QStringLiteral("totalDuration")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("sessionCount")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("completedTasks")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("totalTasks")).toInt(), 0);
    QCOMPARE(invalidStats.value(QStringLiteral("completionRate")).toDouble(), 0.0);
}

void ServiceTests::getDayComparisonReturnsTrendTextAndRejectsInvalidDate()
{
    const QDate targetDate(2026, 6, 10);

    QVERIFY(insertTaskRow(QStringLiteral("昨天完成任务"),
                          targetDate.addDays(-1),
                          QStringLiteral("数学"),
                          true) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("今天完成任务一"),
                          targetDate,
                          QStringLiteral("数学"),
                          true) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("今天完成任务二"),
                          targetDate,
                          QStringLiteral("英语"),
                          true) > 0);
    QVERIFY(insertFocusSessionRow(-1, targetDate.addDays(-1), 1200));
    QVERIFY(insertFocusSessionRow(-1, targetDate, 1800));
    QVERIFY(insertFocusSessionRow(-1, targetDate, 600));
    QVERIFY(insertFocusSessionRow(-1, targetDate.addDays(10), 2400));

    const QVariantMap comparison = StatisticsService::instance()->getDayComparison(targetDate);
    const QVariantMap duration = comparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(duration.value(QStringLiteral("currentValue")).toInt(), 2400);
    QCOMPARE(duration.value(QStringLiteral("previousValue")).toInt(), 1200);
    QCOMPARE(duration.value(QStringLiteral("changePercent")).toInt(), 100);
    QCOMPARE(duration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(duration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +100% vs 昨天"));
    QVERIFY(duration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap sessionCount = comparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(sessionCount.value(QStringLiteral("currentValue")).toInt(), 2);
    QCOMPARE(sessionCount.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(sessionCount.value(QStringLiteral("changePercent")).toInt(), 100);
    QCOMPARE(sessionCount.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(sessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +100% vs 昨天"));
    QVERIFY(sessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap taskCompletion = comparison.value(QStringLiteral("taskCompletion")).toMap();
    QCOMPARE(taskCompletion.value(QStringLiteral("currentValue")).toInt(), 2);
    QCOMPARE(taskCompletion.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(taskCompletion.value(QStringLiteral("changePercent")).toInt(), 100);
    QCOMPARE(taskCompletion.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(taskCompletion.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +100% vs 昨天"));
    QVERIFY(taskCompletion.value(QStringLiteral("hasData")).toBool());

    const QVariantMap firstRecord = StatisticsService::instance()->getDayComparison(targetDate.addDays(10));
    const QVariantMap firstDuration = firstRecord.value(QStringLiteral("duration")).toMap();
    QCOMPARE(firstDuration.value(QStringLiteral("currentValue")).toInt(), 2400);
    QCOMPARE(firstDuration.value(QStringLiteral("previousValue")).toInt(), 0);
    QCOMPARE(firstDuration.value(QStringLiteral("changePercent")).toInt(), 0);
    QCOMPARE(firstDuration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(firstDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("首次记录"));
    QVERIFY(firstDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap noData = StatisticsService::instance()->getDayComparison(QDate(2026, 6, 30));
    QCOMPARE(noData.value(QStringLiteral("duration")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(noData.value(QStringLiteral("sessionCount")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(noData.value(QStringLiteral("taskCompletion")).toMap().value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalid = StatisticsService::instance()->getDayComparison(QDate());
    QCOMPARE(invalid.value(QStringLiteral("hasData")).toBool(), false);
}

void ServiceTests::focusHistoryBucketsSessionsByLogicalDay()
{
    AppSettings::instance()->setDayStartHour(4);
    FocusHistoryService* service = FocusHistoryService::instance();

    const QDate monthFirst(2026, 8, 1);
    const int taskId = insertTaskRow(QStringLiteral("跨月凌晨"), monthFirst);
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, monthFirst, QStringLiteral("01:00:00"),
                                    QStringLiteral("01:30:00"), 1800));

    const QVariantList julySessions = service->getMonthSessions(2026, 7);
    QCOMPARE(julySessions.size(), 1);
    QCOMPARE(julySessions.first().toMap().value(QStringLiteral("date")).toString(),
             QStringLiteral("2026-07-31"));
    QVERIFY(service->getMonthSessions(2026, 8).isEmpty());

    QCOMPARE(service->getDaySessions(QDate(2026, 7, 31)).size(), 1);
    QVERIFY(service->getDaySessions(monthFirst).isEmpty());
}

void ServiceTests::focusHistoryReturnsMonthSessionsWithinBoundaries()
{
    const QDate targetDate(2026, 6, 10);
    const int mathTaskId = insertTaskRow(QStringLiteral("数学二"), targetDate, QStringLiteral("数学"));
    const int englishTaskId = insertTaskRow(QStringLiteral("英语阅读"), targetDate.addDays(1), QStringLiteral("英语"));
    QVERIFY(mathTaskId > 0);
    QVERIFY(englishTaskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                mathTaskId,
                QStringLiteral("2026-06-10T15:37:00"),
                QStringLiteral("2026-06-10T17:34:00"),
                7020) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                englishTaskId,
                QStringLiteral("2026-06-11T08:00:00"),
                QStringLiteral("2026-06-11T08:30:00"),
                1800) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                mathTaskId,
                QStringLiteral("2026-05-31T23:30:00"),
                QStringLiteral("2026-06-01T00:10:00"),
                2400) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                mathTaskId,
                QStringLiteral("2026-07-01T00:00:00"),
                QStringLiteral("2026-07-01T00:10:00"),
                600) > 0);

    const QVariantList sessions = FocusHistoryService::instance()->getMonthSessions(2026, 6);

    // 7月1日 00:00 在 4 点日界前，逻辑日仍是 6月30日，因此属于 6 月历史。
    QCOMPARE(sessions.size(), 3);
    const QVariantMap first = sessions.at(0).toMap();
    const QVariantMap second = sessions.at(1).toMap();
    const QVariantMap third = sessions.at(2).toMap();
    QCOMPARE(first.value(QStringLiteral("taskId")).toInt(), mathTaskId);
    QCOMPARE(first.value(QStringLiteral("taskTitle")).toString(), QStringLiteral("数学二"));
    QCOMPARE(first.value(QStringLiteral("startTime")).toString(), QStringLiteral("2026-06-10T15:37:00"));
    QCOMPARE(first.value(QStringLiteral("endTime")).toString(), QStringLiteral("2026-06-10T17:34:00"));
    QCOMPARE(first.value(QStringLiteral("durationSeconds")).toInt(), 7020);
    QCOMPARE(first.value(QStringLiteral("date")).toString(), QStringLiteral("2026-06-10"));
    QCOMPARE(second.value(QStringLiteral("taskTitle")).toString(), QStringLiteral("英语阅读"));
    QCOMPARE(third.value(QStringLiteral("startTime")).toString(), QStringLiteral("2026-07-01T00:00:00"));
    QCOMPARE(third.value(QStringLiteral("date")).toString(), QStringLiteral("2026-06-30"));
}

void ServiceTests::focusHistoryReturnsDayTotalsAndFormattedDurations()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("数学复盘"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T09:00:00"),
                QStringLiteral("2026-06-10T09:20:00"),
                1200) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T10:00:00"),
                QStringLiteral("2026-06-10T10:10:00"),
                600) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-11T10:00:00"),
                QStringLiteral("2026-06-11T10:30:00"),
                1800) > 0);

    const QVariantList daySessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(daySessions.size(), 2);
    QCOMPARE(FocusHistoryService::instance()->getDayTotalDuration(targetDate), 1800);
    QCOMPARE(FocusHistoryService::instance()->formatDuration(30), QStringLiteral("0分钟"));
    QCOMPARE(FocusHistoryService::instance()->formatDuration(43 * 60), QStringLiteral("43分钟"));
    QCOMPARE(FocusHistoryService::instance()->formatDuration(117 * 60), QStringLiteral("1小时57分"));
    QCOMPARE(FocusHistoryService::instance()->formatDuration(120 * 60), QStringLiteral("2小时"));
}

void ServiceTests::focusHistoryFallsBackWhenTaskWasDeleted()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("会被删除的任务"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T13:00:00"),
                QStringLiteral("2026-06-10T13:30:00"),
                1800) > 0);

    // 外键会把 focus_sessions.task_id 置空；历史页仍要展示这条专注记录。
    QSqlQuery deleteTask(DatabaseManager::instance()->database());
    deleteTask.prepare(QStringLiteral("DELETE FROM tasks WHERE id = :id"));
    deleteTask.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(deleteTask.exec());

    const QVariantList daySessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(daySessions.size(), 1);
    const QVariantMap session = daySessions.first().toMap();
    QVERIFY(session.value(QStringLiteral("taskId")).isNull()
            || !session.value(QStringLiteral("taskId")).isValid());
    QCOMPARE(session.value(QStringLiteral("taskTitle")).toString(), QStringLiteral("未知任务"));
}

void ServiceTests::focusHistoryDistinguishesEmptyResultFromQueryError()
{
    QCOMPARE(FocusHistoryService::instance()->getMonthSessions(2026, 12).size(), 0);
    QCOMPARE(FocusHistoryService::instance()->lastError(), QString());

    QTest::ignoreMessage(QtWarningMsg,
                         "Failed to get month focus sessions: invalid year/month 2026 13");
    QCOMPARE(FocusHistoryService::instance()->getMonthSessions(2026, 13).size(), 0);
    QVERIFY(!FocusHistoryService::instance()->lastError().isEmpty());
}

void ServiceTests::focusHistorySkipsUnfinishedSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("进行中的专注"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:00:00"),
                QStringLiteral("2026-06-10T08:30:00"),
                1800) > 0);

    QSqlQuery unfinished(DatabaseManager::instance()->database());
    unfinished.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time) "
        "VALUES (:taskId, :startTime)"));
    unfinished.bindValue(QStringLiteral(":taskId"), taskId);
    unfinished.bindValue(QStringLiteral(":startTime"), QStringLiteral("2026-06-10T09:00:00"));
    QVERIFY(unfinished.exec());

    QVERIFY(insertFocusSessionWithNullDuration(taskId, targetDate));

    const QVariantList sessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(sessions.size(), 1);
    QCOMPARE(sessions.first().toMap().value(QStringLiteral("durationSeconds")).toInt(), 1800);
}

void ServiceTests::focusHistorySkipsInvalidShortSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("短时专注"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:00:00"),
                QStringLiteral("2026-06-10T08:00:00"),
                0) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:10:00"),
                QStringLiteral("2026-06-10T08:11:00"),
                60) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:20:00"),
                QStringLiteral("2026-06-10T08:22:59"),
                kTestMinimumValidDurationSeconds - 1) > 0);
    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:30:00"),
                QStringLiteral("2026-06-10T08:33:00"),
                kTestMinimumValidDurationSeconds) > 0);

    const QVariantList sessions = FocusHistoryService::instance()->getDaySessions(targetDate);

    QCOMPARE(sessions.size(), 1);
    QCOMPARE(sessions.first().toMap().value(QStringLiteral("durationSeconds")).toInt(),
             kTestMinimumValidDurationSeconds);
    QCOMPARE(FocusHistoryService::instance()->getDayTotalDuration(targetDate),
             kTestMinimumValidDurationSeconds);
}

void ServiceTests::focusHistoryCleansInvalidShortSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("清理测试"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, targetDate, 0));
    QVERIFY(insertFocusSessionRow(taskId, targetDate, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionRow(taskId, targetDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionWithNullDuration(taskId, targetDate));

    QCOMPARE(FocusHistoryService::instance()->invalidSessionCount(), 2);
    QCOMPARE(FocusHistoryService::instance()->cleanupInvalidSessions(), 2);
    QCOMPARE(FocusHistoryService::instance()->invalidSessionCount(), 0);
    QCOMPARE(countFocusSessions(), 2);
    QCOMPARE(FocusHistoryService::instance()->getDaySessions(targetDate).size(), 1);
}

void ServiceTests::getWeekStatsUsesCurrentNaturalWeek()
{
    const QDate today = logicalToday();
    const QDate weekStart = today.addDays(1 - today.dayOfWeek());

    QVERIFY(insertFocusSessionRow(-1, weekStart, 120));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(6), 240));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-1), 999));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(7), 888));

    const QVariantList weekStats = StatisticsService::instance()->getWeekStats();

    QCOMPARE(weekStats.size(), 7);
    QCOMPARE(weekStats.first().toMap().value(QStringLiteral("date")).toDate(), weekStart);
    QCOMPARE(weekStats.last().toMap().value(QStringLiteral("date")).toDate(), weekStart.addDays(6));

    int totalDuration = 0;
    for (const QVariant& dayValue : weekStats) {
        totalDuration += dayValue.toMap().value(QStringLiteral("duration")).toInt();
    }
    QCOMPARE(totalDuration, 240);
}

void ServiceTests::getWeekStatsUsesSpecifiedMondayAndRejectsInvalidStart()
{
    const QDate weekStart(2026, 6, 8);
    QCOMPARE(weekStart.dayOfWeek(), static_cast<int>(Qt::Monday));

    QVERIFY(insertFocusSessionRow(-1, weekStart, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(6), kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(7), kTestMinimumValidDurationSeconds * 10));

    const QVariantList weekStats = StatisticsService::instance()->getWeekStats(weekStart);

    QCOMPARE(weekStats.size(), 7);
    QCOMPARE(weekStats.first().toMap().value(QStringLiteral("date")).toDate(), weekStart);
    QCOMPARE(weekStats.last().toMap().value(QStringLiteral("date")).toDate(), weekStart.addDays(6));
    QCOMPARE(weekStats.at(0).toMap().value(QStringLiteral("duration")).toInt(),
             kTestMinimumValidDurationSeconds);
    QCOMPARE(weekStats.at(6).toMap().value(QStringLiteral("duration")).toInt(),
             kTestMinimumValidDurationSeconds * 2);

    int totalDuration = 0;
    for (const QVariant& dayValue : weekStats) {
        totalDuration += dayValue.toMap().value(QStringLiteral("duration")).toInt();
    }
    QCOMPARE(totalDuration, kTestMinimumValidDurationSeconds * 3);

    QVERIFY(StatisticsService::instance()->getWeekStats(QDate()).isEmpty());
    QVERIFY(StatisticsService::instance()->getWeekStats(weekStart.addDays(1)).isEmpty());
}

void ServiceTests::weekStatsGroupedDurationsEqualPerDayQueries()
{
    // getWeekStats 原本按天调 7 次单日时长查询（每次一遍全表扫描），现在改成
    // 一次 GROUP BY。这条用例钉死两点：逐日结果仍与单日查询逐一相等，
    // 且没有会话的日子必须是 0——GROUP BY 不会为空日返回行，缺失键要能正确落到 0。
    const QDate weekStart(2026, 4, 6);
    QCOMPARE(weekStart.dayOfWeek(), static_cast<int>(Qt::Monday));

    // 周一、周三、周日有数据，其余四天空着。
    QVERIFY(insertFocusSessionRow(-1, weekStart, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(2), kTestMinimumValidDurationSeconds * 5));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(2), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(6), kTestMinimumValidDurationSeconds * 3));
    // 低于有效门槛，任何一天都不该计入。
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(1), kTestMinimumValidDurationSeconds - 1));

    const QVariantList weekStats = StatisticsService::instance()->getWeekStats(weekStart);
    QCOMPARE(weekStats.size(), 7);

    const QList<int> expected = {
        kTestMinimumValidDurationSeconds * 2,
        0,
        kTestMinimumValidDurationSeconds * 6,
        0,
        0,
        0,
        kTestMinimumValidDurationSeconds * 3,
    };
    for (int offset = 0; offset < 7; ++offset) {
        const QVariantMap day = weekStats.at(offset).toMap();
        QCOMPARE(day.value(QStringLiteral("date")).toDate(), weekStart.addDays(offset));
        QCOMPARE(day.value(QStringLiteral("duration")).toInt(), expected.at(offset));
        // 与单日查询逐一比对：两条路径必须给出同一个数。
        const QVariantMap dayStats =
            StatisticsService::instance()->getDayStats(weekStart.addDays(offset));
        QCOMPARE(day.value(QStringLiteral("duration")).toInt(),
                 dayStats.value(QStringLiteral("totalDuration")).toInt());
    }
}

void ServiceTests::weekComparisonRangeQueryEqualsPerDaySum()
{
    // getWeekComparison 原本按天循环查 14 次，现在改成两次区间查询。这条改动的
    // 前提是「7 天各自求和」与「同一区间求和」完全等价——每条会话只属于一个逻辑日，
    // 区间谓词两端闭合，行集和过滤条件相同。这里把这个前提本身钉死，
    // 而不只是校验某组固定数字，将来任何一边改了口径都会被抓到。
    const QDate weekStart(2026, 3, 2);
    QCOMPARE(weekStart.dayOfWeek(), static_cast<int>(Qt::Monday));

    // 每天放不同时长，并混入一条低于有效门槛的会话（它两边都不该计入）。
    for (int offset = 0; offset < 7; ++offset) {
        QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(offset),
                                      kTestMinimumValidDurationSeconds * (offset + 1)));
    }
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(2),
                                  kTestMinimumValidDurationSeconds - 1));

    int perDaySum = 0;
    for (int offset = 0; offset < 7; ++offset) {
        const QVariantMap dayStats =
            StatisticsService::instance()->getDayStats(weekStart.addDays(offset));
        perDaySum += dayStats.value(QStringLiteral("totalDuration")).toInt();
    }

    // 传一个晚于所测周的逻辑今天：已结束周才做整周比较。
    const QVariantMap comparison =
        StatisticsService::instance()->getWeekComparison(weekStart, QStringLiteral("2026-03-09"));
    const QVariantMap duration = comparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(duration.value(QStringLiteral("currentValue")).toInt(), perDaySum);
    // 1+2+...+7 = 28 倍门槛；不足门槛的那条被两边一致地排除。
    QCOMPARE(perDaySum, kTestMinimumValidDurationSeconds * 28);
}

void ServiceTests::getWeekComparisonSumsNaturalWeeksAndRejectsInvalidStart()
{
    const QDate weekStart(2026, 6, 8);
    QCOMPARE(weekStart.dayOfWeek(), static_cast<int>(Qt::Monday));

    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-7), kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-1), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(-1, weekStart, kTestMinimumValidDurationSeconds * 4));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(6), kTestMinimumValidDurationSeconds * 8));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(3), kTestMinimumValidDurationSeconds));

    const QVariantMap comparison =
        StatisticsService::instance()->getWeekComparison(weekStart, QStringLiteral("2026-06-15"));
    const QVariantMap duration = comparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(duration.value(QStringLiteral("currentValue")).toInt(),
             kTestMinimumValidDurationSeconds * 13);
    QCOMPARE(duration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 5);
    QCOMPARE(duration.value(QStringLiteral("changePercent")).toInt(), 160);
    QCOMPARE(duration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(duration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +160% vs 上周"));
    QVERIFY(duration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap sessionCount = comparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(sessionCount.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(sessionCount.value(QStringLiteral("previousValue")).toInt(), 2);
    QCOMPARE(sessionCount.value(QStringLiteral("changePercent")).toInt(), 50);
    QCOMPARE(sessionCount.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(sessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +50% vs 上周"));
    QVERIFY(sessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap effectiveDays = comparison.value(QStringLiteral("effectiveDays")).toMap();
    QCOMPARE(effectiveDays.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(effectiveDays.value(QStringLiteral("previousValue")).toInt(), 2);
    QCOMPARE(effectiveDays.value(QStringLiteral("changePercent")).toInt(), 50);
    QCOMPARE(effectiveDays.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(effectiveDays.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +50% vs 上周"));
    QVERIFY(effectiveDays.value(QStringLiteral("hasData")).toBool());

    const QVariantMap invalidDate =
        StatisticsService::instance()->getWeekComparison(QDate(), QStringLiteral("2026-06-15"));
    QCOMPARE(invalidDate.value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalidWeekStart =
        StatisticsService::instance()->getWeekComparison(weekStart.addDays(1), QStringLiteral("2026-06-15"));
    QCOMPARE(invalidWeekStart.value(QStringLiteral("hasData")).toBool(), false);
}

void ServiceTests::getWeekTasksReturnsInclusiveRangeAndRequiredOrder()
{
    const QDate startDate(2026, 6, 9);
    QVERIFY(insertTaskRow("范围前", startDate.addDays(-1), "数学") > 0);
    QVERIFY(insertTaskRow("周开始", startDate, "数学", false, "2026-06-09T08:00:00") > 0);
    QVERIFY(insertTaskRow("同创建时间低ID", startDate.addDays(1), "英语", false, "2026-06-10T07:00:00") > 0);
    QVERIFY(insertTaskRow("同创建时间高ID", startDate.addDays(1), "英语", false, "2026-06-10T07:00:00") > 0);
    QVERIFY(insertTaskRow("未完成较晚", startDate.addDays(1), "英语", false, "2026-06-10T08:00:00") > 0);
    QVERIFY(insertTaskRow("已完成较早", startDate.addDays(1), "英语", true, "2026-06-10T06:00:00") > 0);
    QVERIFY(insertTaskRow("周结束", startDate.addDays(6), "政治", false, "2026-06-15T08:00:00") > 0);
    QVERIFY(insertTaskRow("范围后", startDate.addDays(7), "数学") > 0);

    const QVariantList tasks = TaskManager::instance()->getWeekTasks(startDate.toString(Qt::ISODate));

    QCOMPARE(taskTitles(tasks), QStringList({
        "周开始",
        "同创建时间低ID",
        "同创建时间高ID",
        "未完成较晚",
        "已完成较早",
        "周结束"
    }));
    QCOMPARE(tasks.first().toMap().value("date").toDate(), startDate);
    QVERIFY(tasks.first().toMap().contains(QStringLiteral("createdAt")));
}

void ServiceTests::getMonthTasksReturnsInclusiveMonthRange()
{
    QVERIFY(insertTaskRow("一月最后一天", QDate(2026, 1, 31), "数学") > 0);
    QVERIFY(insertTaskRow("二月第一天", QDate(2026, 2, 1), "数学") > 0);
    QVERIFY(insertTaskRow("二月最后一天", QDate(2026, 2, 28), "英语") > 0);
    QVERIFY(insertTaskRow("三月第一天", QDate(2026, 3, 1), "政治") > 0);

    const QVariantList tasks = TaskManager::instance()->getMonthTasks(2026, 2);

    QCOMPARE(taskTitles(tasks), QStringList({"二月第一天", "二月最后一天"}));
}

void ServiceTests::getMonthTasksRejectsInvalidMonth()
{
    QVERIFY(insertTaskRow("有效任务", QDate(2026, 6, 1), "数学") > 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to get month tasks: invalid year/month 2026 0");
    QCOMPARE(TaskManager::instance()->getMonthTasks(2026, 0).size(), 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to get month tasks: invalid year/month 2026 13");
    QCOMPARE(TaskManager::instance()->getMonthTasks(2026, 13).size(), 0);
}

void ServiceTests::getEffectiveDaysFiltersInvalidSessions()
{
    const QDate startDate(2026, 6, 10);
    const QDate endDate = startDate.addDays(6);
    const int taskId = insertTaskRow(QStringLiteral("有效天数统计"), startDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionWithNullDuration(taskId, startDate.addDays(1)));
    QVERIFY(insertUnfinishedFocusSessionRow(taskId, startDate.addDays(2), kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, startDate.addDays(3), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(taskId, endDate.addDays(1), kTestMinimumValidDurationSeconds));

    QCOMPARE(StatisticsService::instance()->getEffectiveDays(startDate, endDate), 2);
}

void ServiceTests::getFocusSessionCountCountsOnlyValidFinishedSessions()
{
    const QDate startDate(2026, 7, 1);
    const QDate endDate = startDate.addDays(9);
    const int taskId = insertTaskRow(QStringLiteral("专注次数统计"), startDate, QStringLiteral("英语"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, startDate, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, startDate.addDays(1), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(taskId, startDate.addDays(2), kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionWithNullDuration(taskId, startDate.addDays(3)));
    QVERIFY(insertUnfinishedFocusSessionRow(taskId, startDate.addDays(4), kTestMinimumValidDurationSeconds * 4));
    QVERIFY(insertFocusSessionRow(taskId, endDate.addDays(1), kTestMinimumValidDurationSeconds));

    QCOMPARE(StatisticsService::instance()->getFocusSessionCount(startDate, endDate), 3);
}

void ServiceTests::validPomodoroCountExcludesFreeTimerAndManualStops()
{
    const QDate day(2026, 7, 12);
    const int taskId = insertTaskRow(QStringLiteral("番茄口径对照"), day, QStringLiteral("英语"));
    QVERIFY(taskId > 0);

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions "
        "(task_id, start_time, end_time, duration, mode, pomodoro_completed) "
        "VALUES (:taskId, :startTime, :endTime, :duration, :mode, :completed)"));
    const auto insertSession = [&](const QString& time, int duration, int mode, int completed) {
        query.bindValue(QStringLiteral(":taskId"), taskId);
        query.bindValue(QStringLiteral(":startTime"), dateTimeText(day, time));
        query.bindValue(QStringLiteral(":endTime"), dateTimeText(day, QStringLiteral("23:59:00")));
        query.bindValue(QStringLiteral(":duration"), duration);
        query.bindValue(QStringLiteral(":mode"), mode);
        query.bindValue(QStringLiteral(":completed"), completed);
        return query.exec();
    };

    QVERIFY(insertSession(QStringLiteral("08:00:00"), 1500, 1, 1));
    QVERIFY(insertSession(QStringLiteral("09:00:00"), 1440, 1, 0));
    QVERIFY(insertSession(QStringLiteral("10:00:00"), 2400, 0, 0));
    QVERIFY(insertSession(QStringLiteral("11:00:00"), 100, 1, 0));

    // 旧函数仍是“有效会话数”，新函数才是“有效番茄数”；两者不能被顺手统一。
    QCOMPARE(StatisticsService::instance()->getFocusSessionCount(day, day), 3);
    QCOMPARE(StatisticsService::instance()->getValidPomodoroCount(day, day), 1);
}

void ServiceTests::validPomodoroCountUsesSameLogicalDayAsSessionCount()
{
    AppSettings::instance()->setDayStartHour(4);
    const QDate naturalDay(2026, 7, 21);
    const int taskId = insertTaskRow(QStringLiteral("逻辑日番茄口径"), naturalDay,
                                     QStringLiteral("数学"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, naturalDay, QStringLiteral("02:00:00"),
                                    QStringLiteral("02:25:00"), 1500));
    QVERIFY(insertFocusSessionRowAt(taskId, naturalDay, QStringLiteral("12:00:00"),
                                    QStringLiteral("12:25:00"), 1500));

    const QDate previousLogicalDay = naturalDay.addDays(-1);
    QCOMPARE(StatisticsService::instance()->getFocusSessionCount(previousLogicalDay,
                                                                  previousLogicalDay), 1);
    QCOMPARE(StatisticsService::instance()->getValidPomodoroCount(previousLogicalDay,
                                                                   previousLogicalDay), 1);
    QCOMPARE(StatisticsService::instance()->getFocusSessionCount(naturalDay, naturalDay), 1);
    QCOMPARE(StatisticsService::instance()->getValidPomodoroCount(naturalDay, naturalDay), 1);
}

void ServiceTests::getStreakDaysCountsBackFromLogicalToday()
{
    const QDate today = logicalToday();

    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-2), kTestMinimumValidDurationSeconds));
    // 第 3 天断档；更早的记录不能透过断档续上连击。
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-4), kTestMinimumValidDurationSeconds));

    QCOMPARE(StatisticsService::instance()->getStreakDays(), 3);
}

void ServiceTests::getStreakDaysStartsFromYesterdayWhenTodayHasNoFocus()
{
    const QDate today = logicalToday();
    QCOMPARE(StatisticsService::instance()->getStreakDays(), 0);

    QVERIFY(insertFocusSessionRow(-1, today.addDays(-1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-2), kTestMinimumValidDurationSeconds));
    // 今天只有无效短会话：不算今天，但也不打断从昨天起算的连击。
    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds - 1));

    QCOMPARE(StatisticsService::instance()->getStreakDays(), 2);
}

void ServiceTests::getTotalFocusDurationSumsOnlyValidSessions()
{
    const QDate today = logicalToday();
    QCOMPARE(StatisticsService::instance()->getTotalFocusDuration(), 0);

    const int taskId = insertTaskRow(QStringLiteral("累计时长任务"), today);
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, today.addDays(-30), kTestMinimumValidDurationSeconds * 3));
    QVERIFY(insertFocusSessionRow(-1, today, kTestMinimumValidDurationSeconds - 1));
    // NULL 时长辅助函数不转换 -1 任务号，这里必须挂在真实任务上才能通过外键。
    QVERIFY(insertFocusSessionWithNullDuration(taskId, today));

    QCOMPARE(StatisticsService::instance()->getTotalFocusDuration(), kTestMinimumValidDurationSeconds * 4);
}

void ServiceTests::getMonthStatsUsesCurrentMonthAndTaskDate()
{
    const QDate today = logicalToday();
    const QDate firstDay(today.year(), today.month(), 1);
    const QDate lastDay(today.year(), today.month(), today.daysInMonth());

    const int completedTaskId = insertTaskRow(QStringLiteral("本月完成任务"),
                                              firstDay,
                                              QStringLiteral("数学"),
                                              true,
                                              dateTimeText(firstDay.addDays(-1)));
    const int pendingTaskId = insertTaskRow(QStringLiteral("本月未完成任务"),
                                            lastDay,
                                            QStringLiteral("英语"),
                                            false,
                                            dateTimeText(firstDay));
    QVERIFY(insertTaskRow(QStringLiteral("日期在下月但创建于本月"),
                          lastDay.addDays(1),
                          QStringLiteral("政治"),
                          true,
                          dateTimeText(firstDay)) > 0);
    QVERIFY(completedTaskId > 0);
    QVERIFY(pendingTaskId > 0);

    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertUnfinishedFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 5));

    const QVariantMap stats = StatisticsService::instance()->getMonthStats();

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds * 3);
    QCOMPARE(stats.value(QStringLiteral("effectiveDays")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("sessionCount")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completedTasks")).toInt(), 1);
    QCOMPARE(stats.value(QStringLiteral("totalTasks")).toInt(), 2);
}

void ServiceTests::getMonthStatsUsesSpecifiedMonthAndRejectsInvalidYearMonth()
{
    const QDate firstDay(2026, 2, 1);
    const QDate lastDay(2026, 2, firstDay.daysInMonth());
    const int completedTaskId = insertTaskRow(QStringLiteral("二月完成任务"),
                                              firstDay,
                                              QStringLiteral("数学"),
                                              true,
                                              dateTimeText(firstDay.addDays(-1)));
    const int pendingTaskId = insertTaskRow(QStringLiteral("二月未完成任务"),
                                            lastDay,
                                            QStringLiteral("英语"),
                                            false,
                                            dateTimeText(firstDay));
    QVERIFY(insertTaskRow(QStringLiteral("三月任务"),
                          lastDay.addDays(1),
                          QStringLiteral("政治"),
                          true,
                          dateTimeText(firstDay)) > 0);
    QVERIFY(completedTaskId > 0);
    QVERIFY(pendingTaskId > 0);

    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(pendingTaskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(completedTaskId, firstDay, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertUnfinishedFocusSessionRow(pendingTaskId, lastDay, kTestMinimumValidDurationSeconds * 5));

    const QVariantMap stats = StatisticsService::instance()->getMonthStats(2026, 2);

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds * 3);
    QCOMPARE(stats.value(QStringLiteral("effectiveDays")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("sessionCount")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("completedTasks")).toInt(), 1);
    QCOMPARE(stats.value(QStringLiteral("totalTasks")).toInt(), 2);

    const QVariantMap invalidMonth = StatisticsService::instance()->getMonthStats(2026, 13);
    QCOMPARE(invalidMonth.value(QStringLiteral("totalDuration")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("effectiveDays")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("sessionCount")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("completedTasks")).toInt(), 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("totalTasks")).toInt(), 0);

    const QVariantMap invalidYear = StatisticsService::instance()->getMonthStats(1999, 2);
    QCOMPARE(invalidYear.value(QStringLiteral("totalDuration")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("effectiveDays")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("sessionCount")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("completedTasks")).toInt(), 0);
    QCOMPARE(invalidYear.value(QStringLiteral("totalTasks")).toInt(), 0);
}

void ServiceTests::getMonthComparisonHandlesPreviousMonthAndInvalidYearMonth()
{
    const QDate januaryFirst(2026, 1, 1);
    const QDate previousDecemberFirst(2025, 12, 1);
    const QDate februaryFirst(2026, 2, 1);

    QVERIFY(insertFocusSessionRow(-1, previousDecemberFirst, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, previousDecemberFirst.addDays(1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, januaryFirst, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(-1, februaryFirst, kTestMinimumValidDurationSeconds * 5));
    QVERIFY(insertFocusSessionRow(-1, februaryFirst.addDays(1), kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(-1, februaryFirst.addDays(2), kTestMinimumValidDurationSeconds));

    const QVariantMap februaryComparison = StatisticsService::instance()->getMonthComparison(2026, 2);
    const QVariantMap februaryDuration = februaryComparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(februaryDuration.value(QStringLiteral("currentValue")).toInt(),
             kTestMinimumValidDurationSeconds * 7);
    QCOMPARE(februaryDuration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 2);
    QCOMPARE(februaryDuration.value(QStringLiteral("changePercent")).toInt(), 250);
    QCOMPARE(februaryDuration.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(februaryDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +250% vs 上月"));
    QVERIFY(februaryDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap februarySessionCount = februaryComparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(februarySessionCount.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(februarySessionCount.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(februarySessionCount.value(QStringLiteral("changePercent")).toInt(), 200);
    QCOMPARE(februarySessionCount.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(februarySessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +200% vs 上月"));
    QVERIFY(februarySessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap februaryEffectiveDays = februaryComparison.value(QStringLiteral("effectiveDays")).toMap();
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("currentValue")).toInt(), 3);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("previousValue")).toInt(), 1);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("changePercent")).toInt(), 200);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("trend")).toInt(), 1);
    QCOMPARE(februaryEffectiveDays.value(QStringLiteral("displayText")).toString(), QStringLiteral("↗ +200% vs 上月"));
    QVERIFY(februaryEffectiveDays.value(QStringLiteral("hasData")).toBool());

    const QVariantMap januaryComparison = StatisticsService::instance()->getMonthComparison(2026, 1);
    const QVariantMap januaryDuration = januaryComparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(januaryDuration.value(QStringLiteral("currentValue")).toInt(),
             kTestMinimumValidDurationSeconds * 2);
    QCOMPARE(januaryDuration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 2);
    QCOMPARE(januaryDuration.value(QStringLiteral("changePercent")).toInt(), 0);
    QCOMPARE(januaryDuration.value(QStringLiteral("trend")).toInt(), 0);
    QCOMPARE(januaryDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("→ 0% vs 上月"));
    QVERIFY(januaryDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap januarySessionCount = januaryComparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(januarySessionCount.value(QStringLiteral("currentValue")).toInt(), 1);
    QCOMPARE(januarySessionCount.value(QStringLiteral("previousValue")).toInt(), 2);
    QCOMPARE(januarySessionCount.value(QStringLiteral("changePercent")).toInt(), -50);
    QCOMPARE(januarySessionCount.value(QStringLiteral("trend")).toInt(), -1);
    QCOMPARE(januarySessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↘ -50% vs 上月"));
    QVERIFY(januarySessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap marchComparison = StatisticsService::instance()->getMonthComparison(2026, 3);
    const QVariantMap marchDuration = marchComparison.value(QStringLiteral("duration")).toMap();
    QCOMPARE(marchDuration.value(QStringLiteral("currentValue")).toInt(), 0);
    QCOMPARE(marchDuration.value(QStringLiteral("previousValue")).toInt(),
             kTestMinimumValidDurationSeconds * 7);
    QCOMPARE(marchDuration.value(QStringLiteral("changePercent")).toInt(), -100);
    QCOMPARE(marchDuration.value(QStringLiteral("trend")).toInt(), -1);
    QCOMPARE(marchDuration.value(QStringLiteral("displayText")).toString(), QStringLiteral("↘ -100% vs 上月"));
    QVERIFY(marchDuration.value(QStringLiteral("hasData")).toBool());

    const QVariantMap marchSessionCount = marchComparison.value(QStringLiteral("sessionCount")).toMap();
    QCOMPARE(marchSessionCount.value(QStringLiteral("currentValue")).toInt(), 0);
    QCOMPARE(marchSessionCount.value(QStringLiteral("previousValue")).toInt(), 3);
    QCOMPARE(marchSessionCount.value(QStringLiteral("changePercent")).toInt(), -100);
    QCOMPARE(marchSessionCount.value(QStringLiteral("trend")).toInt(), -1);
    QCOMPARE(marchSessionCount.value(QStringLiteral("displayText")).toString(), QStringLiteral("↘ -100% vs 上月"));
    QVERIFY(marchSessionCount.value(QStringLiteral("hasData")).toBool());

    const QVariantMap equalZeroComparison = StatisticsService::instance()->getMonthComparison(2026, 4);
    QCOMPARE(equalZeroComparison.value(QStringLiteral("duration")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(equalZeroComparison.value(QStringLiteral("sessionCount")).toMap().value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(equalZeroComparison.value(QStringLiteral("effectiveDays")).toMap().value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalidMonth = StatisticsService::instance()->getMonthComparison(2026, 0);
    QCOMPARE(invalidMonth.value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalidYear = StatisticsService::instance()->getMonthComparison(1999, 2);
    QCOMPARE(invalidYear.value(QStringLiteral("hasData")).toBool(), false);
}

void ServiceTests::getMonthWeeklySummaryStaysInsideCurrentMonth()
{
    const QDate today = logicalToday();
    const QDate firstDay(today.year(), today.month(), 1);
    const QDate lastDay(today.year(), today.month(), today.daysInMonth());
    const int taskId = insertTaskRow(QStringLiteral("本月周汇总"), firstDay, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(taskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));

    const QVariantList summary = StatisticsService::instance()->getMonthWeeklySummary();

    QVERIFY(!summary.isEmpty());
    QDate expectedStart = firstDay;
    int totalDuration = 0;
    bool coversFirstDay = false;
    bool coversLastDay = false;

    for (int index = 0; index < summary.size(); ++index) {
        const QVariantMap week = summary.at(index).toMap();
        const QDate startDate = QDate::fromString(week.value(QStringLiteral("startDate")).toString(), Qt::ISODate);
        const QDate endDate = QDate::fromString(week.value(QStringLiteral("endDate")).toString(), Qt::ISODate);

        QVERIFY(startDate.isValid());
        QVERIFY(endDate.isValid());
        QVERIFY(startDate >= firstDay);
        QVERIFY(endDate <= lastDay);
        QVERIFY(startDate <= endDate);
        QCOMPARE(startDate, expectedStart);
        QCOMPARE(week.value(QStringLiteral("label")).toString(), QStringLiteral("第%1周").arg(index + 1));

        // 周桶不能跨出本月；如果不是最后一天，就应该停在自然周日。
        QVERIFY(endDate == lastDay || endDate.dayOfWeek() == Qt::Sunday);

        totalDuration += week.value(QStringLiteral("duration")).toInt();
        coversFirstDay = coversFirstDay || (startDate <= firstDay && firstDay <= endDate);
        coversLastDay = coversLastDay || (startDate <= lastDay && lastDay <= endDate);
        expectedStart = endDate.addDays(1);
    }

    QCOMPARE(summary.first().toMap().value(QStringLiteral("startDate")).toString(), firstDay.toString(Qt::ISODate));
    QCOMPARE(summary.last().toMap().value(QStringLiteral("endDate")).toString(), lastDay.toString(Qt::ISODate));
    QCOMPARE(expectedStart, lastDay.addDays(1));
    QVERIFY(coversFirstDay);
    QVERIFY(coversLastDay);
    QCOMPARE(totalDuration, kTestMinimumValidDurationSeconds * 3);
}

void ServiceTests::getMonthWeeklySummaryUsesSpecifiedMonthAndRejectsInvalidYearMonth()
{
    const QDate firstDay(2026, 2, 1);
    const QDate lastDay(2026, 2, firstDay.daysInMonth());
    const int taskId = insertTaskRow(QStringLiteral("二月周汇总"), firstDay, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, firstDay, kTestMinimumValidDurationSeconds));
    QVERIFY(insertFocusSessionRow(taskId, lastDay, kTestMinimumValidDurationSeconds * 2));
    QVERIFY(insertFocusSessionRow(taskId, firstDay.addDays(-1), kTestMinimumValidDurationSeconds * 10));
    QVERIFY(insertFocusSessionRow(taskId, lastDay.addDays(1), kTestMinimumValidDurationSeconds * 10));

    const QVariantList summary = StatisticsService::instance()->getMonthWeeklySummary(2026, 2);

    QVERIFY(!summary.isEmpty());
    QDate expectedStart = firstDay;
    int totalDuration = 0;

    for (int index = 0; index < summary.size(); ++index) {
        const QVariantMap week = summary.at(index).toMap();
        const QDate startDate = QDate::fromString(week.value(QStringLiteral("startDate")).toString(), Qt::ISODate);
        const QDate endDate = QDate::fromString(week.value(QStringLiteral("endDate")).toString(), Qt::ISODate);

        QVERIFY(startDate.isValid());
        QVERIFY(endDate.isValid());
        QVERIFY(startDate >= firstDay);
        QVERIFY(endDate <= lastDay);
        QVERIFY(startDate <= endDate);
        QCOMPARE(startDate, expectedStart);
        QCOMPARE(week.value(QStringLiteral("label")).toString(), QStringLiteral("第%1周").arg(index + 1));
        QVERIFY(endDate == lastDay || endDate.dayOfWeek() == Qt::Sunday);

        totalDuration += week.value(QStringLiteral("duration")).toInt();
        expectedStart = endDate.addDays(1);
    }

    QCOMPARE(summary.first().toMap().value(QStringLiteral("startDate")).toString(), firstDay.toString(Qt::ISODate));
    QCOMPARE(summary.last().toMap().value(QStringLiteral("endDate")).toString(), lastDay.toString(Qt::ISODate));
    QCOMPARE(expectedStart, lastDay.addDays(1));
    QCOMPARE(totalDuration, kTestMinimumValidDurationSeconds * 3);
    QVERIFY(StatisticsService::instance()->getMonthWeeklySummary(2026, 0).isEmpty());
    QVERIFY(StatisticsService::instance()->getMonthWeeklySummary(2101, 2).isEmpty());
}

void ServiceTests::getCategoryStatsAggregatesDurationsAndPercentages()
{
    const QDate startDate(2026, 6, 1);
    const QDate endDate(2026, 6, 30);
    const int mathTaskId = insertTaskRow("数学题", startDate, "数学");
    const int secondMathTaskId = insertTaskRow("高数复盘", startDate.addDays(1), "数学");
    const int englishTaskId = insertTaskRow("英语阅读", startDate.addDays(2), "英语");
    const int emptyCategoryTaskId = insertTaskRow("无分类", startDate.addDays(3), "");
    QVERIFY(mathTaskId > 0);
    QVERIFY(secondMathTaskId > 0);
    QVERIFY(englishTaskId > 0);
    QVERIFY(emptyCategoryTaskId > 0);

    QVERIFY(insertFocusSessionRow(mathTaskId, startDate, 1200));
    QVERIFY(insertFocusSessionRow(secondMathTaskId, startDate.addDays(1), 600));
    QVERIFY(insertFocusSessionRow(englishTaskId, startDate.addDays(2), 600));
    QVERIFY(insertFocusSessionWithNullDuration(englishTaskId, startDate.addDays(2)));
    QVERIFY(insertFocusSessionRow(emptyCategoryTaskId, startDate.addDays(3), 500));
    QVERIFY(insertFocusSessionRow(mathTaskId, startDate.addDays(-1), 900));
    QVERIFY(insertFocusSessionRow(-1, startDate, 700));

    const QVariantMap stats = StatisticsService::instance()->getCategoryStats(
        startDate.toString(Qt::ISODate),
        QVariant(endDate));
    const QVariantList categories = stats.value(QStringLiteral("categories")).toList();

    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(), 3600);
    QCOMPARE(categories.size(), 4);

    const QVariantMap math = categories.at(0).toMap();
    QCOMPARE(math.value(QStringLiteral("name")).toString(), QString("数学"));
    QCOMPARE(math.value(QStringLiteral("color")).toString(), QStringLiteral("#d4a574"));
    QCOMPARE(math.value(QStringLiteral("duration")).toInt(), 1800);
    QCOMPARE(math.value(QStringLiteral("percentage")).toDouble(), 50.0);

    const QVariantMap detached = categories.at(1).toMap();
    QCOMPARE(detached.value(QStringLiteral("name")).toString(), QStringLiteral("未关联任务"));
    QCOMPARE(detached.value(QStringLiteral("duration")).toInt(), 700);

    const QVariantMap english = categories.at(2).toMap();
    QCOMPARE(english.value(QStringLiteral("name")).toString(), QString("英语"));
    QCOMPARE(english.value(QStringLiteral("color")).toString(), QStringLiteral("#c9956e"));
    QCOMPARE(english.value(QStringLiteral("duration")).toInt(), 600);
    QCOMPARE(english.value(QStringLiteral("percentage")).toDouble(), 600.0 * 100.0 / 3600.0);

    const QVariantMap uncategorized = categories.at(3).toMap();
    QCOMPARE(uncategorized.value(QStringLiteral("name")).toString(), QStringLiteral("未分类"));
    QCOMPARE(uncategorized.value(QStringLiteral("duration")).toInt(), 500);
}

void ServiceTests::statisticsIgnoresInvalidShortSessions()
{
    const QDate today = logicalToday();
    const int mathTaskId = insertTaskRow(QStringLiteral("数学短记录"), today, QStringLiteral("数学"));
    const int englishTaskId = insertTaskRow(QStringLiteral("英语有效记录"), today, QStringLiteral("英语"));
    QVERIFY(mathTaskId > 0);
    QVERIFY(englishTaskId > 0);

    QVERIFY(insertFocusSessionRow(mathTaskId, today, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionRow(englishTaskId, today, kTestMinimumValidDurationSeconds));

    const QVariantMap todayStats = StatisticsService::instance()->getTodayStats();
    QCOMPARE(todayStats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds);

    const QVariantMap categoryStats = StatisticsService::instance()->getCategoryStats(today, today);
    QCOMPARE(categoryStats.value(QStringLiteral("totalDuration")).toInt(),
             kTestMinimumValidDurationSeconds);
    const QVariantList categories = categoryStats.value(QStringLiteral("categories")).toList();
    QCOMPARE(categories.size(), 1);
    QCOMPARE(categories.first().toMap().value(QStringLiteral("name")).toString(), QStringLiteral("英语"));
}

void ServiceTests::getDayTaskStatsAggregatesPerTask()
{
    const QDate today = logicalToday();
    const int mathId = insertTaskRow(QStringLiteral("高数第七章"), today, QStringLiteral("数学"));
    const int engId = insertTaskRow(QStringLiteral("英语阅读"), today, QStringLiteral("英语"));
    QVERIFY(mathId > 0);
    QVERIFY(engId > 0);

    // 数学：两段有效(1500+900=2400)，各计一个番茄；英语：一段 600。
    QVERIFY(insertFocusSessionRow(mathId, today, 1500));
    QVERIFY(insertFocusSessionRow(mathId, today, 900));
    QVERIFY(insertFocusSessionRow(engId, today, 600));
    // 排除项：短于阈值、null 时长、其它逻辑日，都不进今日聚合。
    QVERIFY(insertFocusSessionRow(mathId, today, kTestMinimumValidDurationSeconds - 1));
    QVERIFY(insertFocusSessionWithNullDuration(engId, today));
    QVERIFY(insertFocusSessionRow(mathId, today.addDays(-1), 3000));

    const QVariantMap stats = StatisticsService::instance()->getDayTaskStats(today);
    const QVariantList tasks = stats.value(QStringLiteral("tasks")).toList();

    QCOMPARE(stats.value(QStringLiteral("taskCount")).toInt(), 2);
    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(), 3000); // 2400 + 600
    QCOMPARE(tasks.size(), 2);

    // 按今日时长降序：数学(2400)在前，英语(600)在后。
    const QVariantMap first = tasks.at(0).toMap();
    QCOMPARE(first.value(QStringLiteral("taskId")).toInt(), mathId);
    QCOMPARE(first.value(QStringLiteral("title")).toString(), QStringLiteral("高数第七章"));
    QCOMPARE(first.value(QStringLiteral("focusedSeconds")).toInt(), 2400);
    QCOMPARE(first.value(QStringLiteral("pomodoros")).toInt(), 2);
    QCOMPARE(first.value(QStringLiteral("unassigned")).toBool(), false);

    const QVariantMap second = tasks.at(1).toMap();
    QCOMPARE(second.value(QStringLiteral("taskId")).toInt(), engId);
    QCOMPARE(second.value(QStringLiteral("focusedSeconds")).toInt(), 600);
    QCOMPARE(second.value(QStringLiteral("pomodoros")).toInt(), 1);
}

void ServiceTests::getDayTaskStatsUsesLatestValidCategorySnapshot()
{
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("跨科目任务"), today, QStringLiteral("当前科目"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionWithSnapshot(taskId, today, QStringLiteral("09:00:00"), 600,
                                           QStringLiteral("上午科目"), QStringLiteral("#112233")));
    QVERIFY(insertFocusSessionWithSnapshot(taskId, today, QStringLiteral("15:00:00"), 900,
                                           QStringLiteral("下午科目"), QStringLiteral("#445566")));

    const QVariantList tasks = StatisticsService::instance()->getDayTaskStats(today)
                                   .value(QStringLiteral("tasks")).toList();
    QCOMPARE(tasks.size(), 1);
    const QVariantMap row = tasks.first().toMap();
    QCOMPARE(row.value(QStringLiteral("focusedSeconds")).toInt(), 1500);
    QCOMPARE(row.value(QStringLiteral("categoryName")).toString(), QStringLiteral("下午科目"));
    QCOMPARE(row.value(QStringLiteral("color")).toString(), QStringLiteral("#445566"));
}

void ServiceTests::getDayTaskStatsGroupsUnassignedFocus()
{
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("有主任务"), today, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRow(taskId, today, 600));
    // 两段未关联任务(task_id 为空)的专注应汇成单独一行。
    QVERIFY(insertFocusSessionRow(-1, today, 1200));
    QVERIFY(insertFocusSessionRow(-1, today, 300));

    const QVariantMap stats = StatisticsService::instance()->getDayTaskStats(today);
    const QVariantList tasks = stats.value(QStringLiteral("tasks")).toList();
    QCOMPARE(stats.value(QStringLiteral("taskCount")).toInt(), 2);

    QVariantMap unassigned;
    for (const QVariant& value : tasks) {
        const QVariantMap row = value.toMap();
        if (row.value(QStringLiteral("unassigned")).toBool()) {
            unassigned = row;
            break;
        }
    }
    QVERIFY(!unassigned.isEmpty());
    QCOMPARE(unassigned.value(QStringLiteral("focusedSeconds")).toInt(), 1500); // 1200 + 300
    QCOMPARE(unassigned.value(QStringLiteral("taskId")).toInt(), -1);
    // 未关联行时长最大(1500 > 600)，排在首位。
    QCOMPARE(tasks.at(0).toMap().value(QStringLiteral("unassigned")).toBool(), true);
}

void ServiceTests::getDayTaskStatsPomodoroCountUsesValidRule()
{
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("专注任务"), today, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    // 番茄段(mode=1)计一个番茄；自由计时(mode=0)只累计时长、不计番茄。
    QVERIFY(insertFocusSessionRowWithMode(taskId, today, 25 * 60, 1));
    QVERIFY(insertFocusSessionRowWithMode(taskId, today, 30 * 60, 0));

    const QVariantMap stats = StatisticsService::instance()->getDayTaskStats(today);
    const QVariantList tasks = stats.value(QStringLiteral("tasks")).toList();
    QCOMPARE(tasks.size(), 1);

    const QVariantMap row = tasks.at(0).toMap();
    QCOMPARE(row.value(QStringLiteral("focusedSeconds")).toInt(), 25 * 60 + 30 * 60); // 两段都计时长
    QCOMPARE(row.value(QStringLiteral("pomodoros")).toInt(), 1);                       // 只番茄段计番茄
}

void ServiceTests::getDayTaskStatsRespectsLogicalDayAndEmptyDate()
{
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("跨界任务"), today, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    // dayStartHour=4：今天凌晨 02:00 的一段应归入「逻辑昨天」，不进 today。
    const QString earlyStart = today.toString(Qt::ISODate) + QStringLiteral("T02:00:00");
    const QString earlyEnd = today.toString(Qt::ISODate) + QStringLiteral("T02:30:00");
    QVERIFY(insertFocusSessionRowWithTimes(taskId, earlyStart, earlyEnd, 1800) > 0);

    const QVariantMap todayStats = StatisticsService::instance()->getDayTaskStats(today);
    QCOMPARE(todayStats.value(QStringLiteral("taskCount")).toInt(), 0);
    QVERIFY(todayStats.value(QStringLiteral("tasks")).toList().isEmpty());

    const QVariantMap yesterdayStats =
        StatisticsService::instance()->getDayTaskStats(today.addDays(-1));
    QCOMPARE(yesterdayStats.value(QStringLiteral("taskCount")).toInt(), 1);
    QCOMPARE(yesterdayStats.value(QStringLiteral("tasks")).toList().at(0).toMap()
                 .value(QStringLiteral("focusedSeconds")).toInt(),
             1800);

    // 无效日期安全返回空。
    const QVariantMap invalid = StatisticsService::instance()->getDayTaskStats(QDate());
    QCOMPARE(invalid.value(QStringLiteral("taskCount")).toInt(), 0);
    QVERIFY(invalid.value(QStringLiteral("tasks")).toList().isEmpty());
}

void ServiceTests::routinesTableExistsAfterInitialize()
{
    // init() 已用全新临时库初始化，迁移应已建好 routines 表。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY2(query.exec(QStringLiteral(
        "SELECT id, title, category_id, active, display_order, last_generated_date, created_at FROM routines")),
        qPrintable(query.lastError().text()));
}

void ServiceTests::databaseReinitializeEmitsRoutineChangeOnce()
{
    // 两个单例必须先构造，再换库；否则测试只是在验证“尚未建立的连接不会发信号”。
    CategoryManager* categoryManager = CategoryManager::instance();
    RoutineManager* routineManager = RoutineManager::instance();
    QVERIFY(categoryManager);
    QVERIFY(routineManager);

    QSignalSpy routinesChangedSpy(routineManager, &RoutineManager::routinesChanged);
    QVERIFY(routinesChangedSpy.isValid());

    const QString reopenedDatabase = m_tempDir->filePath(QStringLiteral("reopened.sqlite"));
    QVERIFY(DatabaseManager::instance()->initialize(reopenedDatabase));

    // CategoryManager 已将换库事实转发一次；RoutineManager 不能再直连数据库重复广播。
    QCOMPARE(routinesChangedSpy.count(), 1);
}

void ServiceTests::version2MigrationAddsRoutinesSchemaAndIndex()
{
    DatabaseManager::instance()->close();
    const QString version2Path = m_tempDir->filePath(QStringLiteral("version2.sqlite"));
    QVERIFY(createVersion2Database(version2Path));
    QVERIFY(DatabaseManager::instance()->initialize(version2Path));

    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);

    // v3 从真实 v2 库升级时必须补齐 routines 表和索引，不能只覆盖全新库。
    QSqlQuery tableQuery(DatabaseManager::instance()->database());
    QVERIFY2(tableQuery.exec(QStringLiteral(
                 "SELECT id, title, category_id, active, display_order, last_generated_date, created_at FROM routines")),
             qPrintable(tableQuery.lastError().text()));

    QSqlQuery indexQuery(DatabaseManager::instance()->database());
    indexQuery.prepare(QStringLiteral(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = :name"));
    indexQuery.bindValue(QStringLiteral(":name"), QStringLiteral("idx_routines_active"));
    QVERIFY(indexQuery.exec());
    QVERIFY(indexQuery.next());
    QCOMPARE(indexQuery.value(0).toString(), QStringLiteral("idx_routines_active"));

    QSqlQuery insertRoutine(DatabaseManager::instance()->database());
    QVERIFY2(insertRoutine.exec(QStringLiteral("INSERT INTO routines (title) VALUES ('v2 升级例行')")),
             qPrintable(insertRoutine.lastError().text()));

    QSqlQuery defaults(DatabaseManager::instance()->database());
    QVERIFY(defaults.exec(QStringLiteral(
        "SELECT active, display_order, created_at FROM routines WHERE title = 'v2 升级例行'")));
    QVERIFY(defaults.next());
    QCOMPARE(defaults.value(0).toInt(), 1);
    QCOMPARE(defaults.value(1).toInt(), 0);
    QVERIFY(!defaults.value(2).toString().isEmpty());
}

void ServiceTests::routinesCategoryForeignKeyClearsWhenCategoryDeleted()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("每日专业课"), QStringLiteral("#123456"));
    QVERIFY(categoryId > 0);

    QSqlQuery insertRoutine(DatabaseManager::instance()->database());
    insertRoutine.prepare(QStringLiteral(
        "INSERT INTO routines (title, category_id) VALUES (:title, :categoryId)"));
    insertRoutine.bindValue(QStringLiteral(":title"), QStringLiteral("每日复盘"));
    insertRoutine.bindValue(QStringLiteral(":categoryId"), categoryId);
    QVERIFY2(insertRoutine.exec(), qPrintable(insertRoutine.lastError().text()));

    // routines.category_id 使用 ON DELETE SET NULL，保持“删除科目只影响未来分类关联，不删除例行项”的语义。
    QVERIFY(manager->deleteCategory(categoryId));

    QSqlQuery routine(DatabaseManager::instance()->database());
    routine.prepare(QStringLiteral("SELECT category_id FROM routines WHERE title = :title"));
    routine.bindValue(QStringLiteral(":title"), QStringLiteral("每日复盘"));
    QVERIFY(routine.exec());
    QVERIFY(routine.next());
    QVERIFY(routine.value(0).isNull());
}

void ServiceTests::routineCrudAddsGetsUpdatesDeletes()
{
    RoutineManager* manager = RoutineManager::instance();
    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("例行科目"), QStringLiteral("#123456"));
    QVERIFY(categoryId > 0);

    QSignalSpy spy(manager, &RoutineManager::routinesChanged);

    // 空标题被拒
    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: title is empty");
    QVERIFY(!manager->addRoutine(QStringLiteral("   "), -1));
    QCOMPARE(spy.count(), 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: category not found 999999");
    QVERIFY(!manager->addRoutine(QStringLiteral("无效科目例行"), 999999));
    QCOMPARE(spy.count(), 0);

    // 正常新增（带前后空格，应被 trim）
    QVERIFY(manager->addRoutine(QStringLiteral("  背单词 list  "), -1));
    QCOMPARE(spy.count(), 1);

    QVariantList routines = manager->getRoutines();
    QCOMPARE(routines.size(), 1);
    QVariantMap r = routines.first().toMap();
    QCOMPARE(r.value(QStringLiteral("title")).toString(), QStringLiteral("背单词 list"));
    QCOMPARE(r.value(QStringLiteral("categoryId")).toInt(), -1);
    QCOMPARE(r.value(QStringLiteral("displayOrder")).toInt(), 1);
    QCOMPARE(r.value(QStringLiteral("active")).toBool(), true);
    const int id = r.value(QStringLiteral("id")).toInt();
    QVERIFY(id > 0);

    QVERIFY(manager->addRoutine(QStringLiteral("专业课复盘"), categoryId));
    QCOMPARE(spy.count(), 2);
    routines = manager->getRoutines();
    QCOMPARE(routines.size(), 2);
    const QVariantMap categoryRoutine = routines.at(1).toMap();
    QCOMPARE(categoryRoutine.value(QStringLiteral("title")).toString(), QStringLiteral("专业课复盘"));
    QCOMPARE(categoryRoutine.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(categoryRoutine.value(QStringLiteral("categoryName")).toString(), QStringLiteral("例行科目"));
    QCOMPARE(categoryRoutine.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#123456"));
    QCOMPARE(categoryRoutine.value(QStringLiteral("displayOrder")).toInt(), 2);
    const int categoryRoutineId = categoryRoutine.value(QStringLiteral("id")).toInt();
    QVERIFY(categoryRoutineId > 0);

    QTest::ignoreMessage(QtWarningMsg, "Failed to update routine: routine not found 999999");
    QVERIFY(!manager->updateRoutine(999999, QStringLiteral("不存在"), -1));
    QTest::ignoreMessage(QtWarningMsg, "Failed to set routine active: routine not found 999999");
    QVERIFY(!manager->setRoutineActive(999999, false));
    QTest::ignoreMessage(QtWarningMsg, "Failed to delete routine: routine not found 999999");
    QVERIFY(!manager->deleteRoutine(999999));
    QCOMPARE(spy.count(), 2);

    // 更新标题
    QVERIFY(manager->updateRoutine(id, QStringLiteral("背单词 list 2"), -1));
    QCOMPARE(spy.count(), 3);
    QCOMPARE(manager->getRoutines().first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("背单词 list 2"));

    // 停用
    QVERIFY(manager->setRoutineActive(id, false));
    QCOMPARE(spy.count(), 4);
    QCOMPARE(manager->getRoutines().first().toMap().value(QStringLiteral("active")).toBool(), false);

    // 删除分类会让例行项的科目关联变成 NULL，RoutineManager 也要通知列表刷新。
    QVERIFY(CategoryManager::instance()->deleteCategory(categoryId));
    QCOMPARE(spy.count(), 5);
    routines = manager->getRoutines();
    QCOMPARE(routines.at(1).toMap().value(QStringLiteral("categoryId")).toInt(), -1);
    QCOMPARE(routines.at(1).toMap().value(QStringLiteral("categoryName")).toString(), QString());

    // 删除
    QVERIFY(manager->deleteRoutine(id));
    QCOMPARE(spy.count(), 6);
    QVERIFY(manager->deleteRoutine(categoryRoutineId));
    QCOMPARE(spy.count(), 7);
    QVERIFY(manager->getRoutines().isEmpty());
}

void ServiceTests::deletingRoutineReclaimsUntouchedTodayTask()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("删除后收回任务"), -1));
    const int routineId = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(routineId > 0);
    QCOMPARE(manager->materializeToday(), 1);

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(tasks.size(), 1);
    const int taskId = tasks.first().toMap().value(QStringLiteral("id")).toInt();

    // 删除的事实要按 TaskManager 的信号约定广播：计时器这类持有任务编号的服务靠 taskDeleted
    // 解绑，只订阅 tasksChanged 的页面靠后一个信号刷新。少发任何一个都会留下不一致的界面。
    QSignalSpy deletedSpy(TaskManager::instance(), &TaskManager::taskDeleted);
    QSignalSpy changedSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    QVERIFY(deletedSpy.isValid());
    QVERIFY(changedSpy.isValid());

    QVERIFY(manager->deleteRoutine(routineId));

    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
    QCOMPARE(deletedSpy.count(), 1);
    QCOMPARE(deletedSpy.first().first().toInt(), taskId);
    QCOMPARE(changedSpy.count(), 1);
}

void ServiceTests::deletingRoutineKeepsTouchedTodayTask()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("已完成例行"), -1));
    QVERIFY(manager->addRoutine(QStringLiteral("专注过的例行"), -1));
    const QVariantList routines = manager->getRoutines();
    QCOMPARE(routines.size(), 2);
    const int completedRoutineId = routines.at(0).toMap().value(QStringLiteral("id")).toInt();
    const int focusedRoutineId = routines.at(1).toMap().value(QStringLiteral("id")).toInt();
    QCOMPARE(manager->materializeToday(), 2);

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(logicalToday());
    const int completedTaskId = taskIdByTitle(tasks, QStringLiteral("已完成例行"));
    const int focusedTaskId = taskIdByTitle(tasks, QStringLiteral("专注过的例行"));
    QVERIFY(completedTaskId > 0);
    QVERIFY(focusedTaskId > 0);

    QVERIFY(TaskManager::instance()->completeTask(completedTaskId));
    // 专注记录在「开始专注」那一刻就落库，所以这一条同时代表「专注过」和「正在专注」两种情况。
    QSqlQuery insertSession(DatabaseManager::instance()->database());
    insertSession.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, mode) VALUES (:taskId, :startTime, 0)"));
    insertSession.bindValue(QStringLiteral(":taskId"), focusedTaskId);
    insertSession.bindValue(QStringLiteral(":startTime"), dateTimeText(logicalToday()));
    QVERIFY2(insertSession.exec(), qPrintable(insertSession.lastError().text()));

    QSignalSpy deletedSpy(TaskManager::instance(), &TaskManager::taskDeleted);
    QVERIFY(deletedSpy.isValid());

    QVERIFY(manager->deleteRoutine(completedRoutineId));
    QVERIFY(manager->deleteRoutine(focusedRoutineId));

    // 碰过的实例一条都不能删：已完成代表今天确实做过，有专注记录代表时间已经花出去了。
    // 它们退化成普通任务——只清 routine_id 而留着 routine_generated=1 的话，
    // 逾期结转仍会把它们当成受规则管理的任务，最终变成看不见的黑洞。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "SELECT routine_id, routine_generated FROM tasks WHERE id IN (:completedId, :focusedId)"));
    query.bindValue(QStringLiteral(":completedId"), completedTaskId);
    query.bindValue(QStringLiteral(":focusedId"), focusedTaskId);
    QVERIFY(query.exec());
    int survivors = 0;
    while (query.next()) {
        QVERIFY(query.value(0).isNull());
        QCOMPARE(query.value(1).toInt(), 0);
        ++survivors;
    }
    QCOMPARE(survivors, 2);
    QCOMPARE(deletedSpy.count(), 0);
}

void ServiceTests::updatingRoutineSyncsTodayTask()
{
    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("同步科目"),
                                                                    QStringLiteral("#abcdef"));
    QVERIFY(categoryId > 0);

    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("旧标题"), -1));
    const int routineId = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QCOMPARE(manager->materializeToday(), 1);
    const int taskId = TaskManager::instance()->getTasksByDate(logicalToday())
                           .first().toMap().value(QStringLiteral("id")).toInt();

    QSignalSpy changedSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    QVERIFY(changedSpy.isValid());
    QVERIFY(manager->updateRoutine(routineId, QStringLiteral("新标题"), categoryId));
    QCOMPARE(changedSpy.count(), 1);

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT title, category_id, category FROM tasks WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(query.exec());
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("新标题"));
    QCOMPARE(query.value(1).toInt(), categoryId);
    // category 是科目名快照。漏掉它的话只有 category_id 变了，任务卡上的科目标签还是旧名字。
    QCOMPARE(query.value(2).toString(), QStringLiteral("同步科目"));

    // 已完成的当日实例同样跟着改：改名不破坏任何数据，列表上留着旧名字才是用户看到的问题。
    QVERIFY(TaskManager::instance()->completeTask(taskId));
    QVERIFY(manager->updateRoutine(routineId, QStringLiteral("再改一次"), -1));

    QSqlQuery recheck(DatabaseManager::instance()->database());
    recheck.prepare(QStringLiteral("SELECT title, category_id, category FROM tasks WHERE id = :id"));
    recheck.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(recheck.exec());
    QVERIFY(recheck.next());
    QCOMPARE(recheck.value(0).toString(), QStringLiteral("再改一次"));
    QVERIFY(recheck.value(1).isNull());
    QCOMPARE(recheck.value(2).toString(), QString());
}

void ServiceTests::deactivatingRoutineReclaimsTodayTaskAndRestoresOnReactivate()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("停用收回"), -1));
    const int routineId = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QCOMPARE(manager->materializeToday(), 1);

    QVERIFY(manager->setRoutineActive(routineId, false));
    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
    // 停着的时候不会被任何一次刷新重新生成。
    QCOMPARE(manager->materializeToday(), 0);

    // 回收时把生成戳退回了 NULL，所以重新启用当天就能补回来；
    // 不退回的话用户误点一下开关，今天这件事就再也回不来了，还看不出原因。
    QVERIFY(manager->setRoutineActive(routineId, true));
    QCOMPARE(manager->materializeToday(), 1);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 1);
}

void ServiceTests::removingTodayFromWeekdaysReclaimsTodayTask()
{
    // 用例不能假设今天是周几：按逻辑日算出今天那一位，再构造「只有今天」和「刚好避开今天」。
    const int todayBit = RoutineRules::maskForDayOfWeek(logicalToday().dayOfWeek());
    QVERIFY(todayBit > 0);
    const int withoutToday = RoutineRules::kEveryDayMask & ~todayBit;

    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("重复日收回"), -1, todayBit));
    const int routineId = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QCOMPARE(manager->materializeToday(), 1);

    QVERIFY(manager->setRoutineWeekdays(routineId, withoutToday));
    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
    QCOMPARE(manager->materializeToday(), 0);

    // 两个方向必须对称：把今天勾回来，下一次刷新就该把任务补出来。
    QVERIFY(manager->setRoutineWeekdays(routineId, RoutineRules::kEveryDayMask));
    QCOMPARE(manager->materializeToday(), 1);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 1);
}

void ServiceTests::reclaimingTodayTaskDoesNotResurrectManuallyDeletedTask()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("手删不复活"), -1));
    const int routineId = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QCOMPARE(manager->materializeToday(), 1);
    const int taskId = TaskManager::instance()->getTasksByDate(logicalToday())
                           .first().toMap().value(QStringLiteral("id")).toInt();

    // 用户自己删掉了今天这条实例：此时已经没有可回收的任务，停用就不该退回生成戳。
    // 退回了的话，「停用→启用」会把用户刚刚亲手删掉的任务又送回来，破坏「删不复活」。
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    QVERIFY(manager->setRoutineActive(routineId, false));
    QVERIFY(manager->setRoutineActive(routineId, true));

    QCOMPARE(manager->materializeToday(), 0);
    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
}

void ServiceTests::databaseCloseRemovesNamedConnection()
{
    QVERIFY(QSqlDatabase::contains(QStringLiteral("PomodoroTodoConnection")));
    DatabaseManager::instance()->close();
    QVERIFY(!QSqlDatabase::contains(QStringLiteral("PomodoroTodoConnection")));
}

void ServiceTests::databaseOpenedExistingFlagTracksSuccessfulStartupOnly()
{
    DatabaseManager* manager = DatabaseManager::instance();
    manager->close();

    const QString newDatabasePath = m_tempDir->filePath(QStringLiteral("notice-context.sqlite"));
    QVERIFY(!QFileInfo::exists(newDatabasePath));
    QVERIFY(manager->initialize(newDatabasePath));
    QCOMPARE(manager->openedExistingDatabase(), false);

    // 同路径重入仍属于这次新安装启动，不能因为文件已经被 SQLite 创建而改判成旧安装。
    QVERIFY(manager->initialize(newDatabasePath));
    QCOMPARE(manager->openedExistingDatabase(), false);

    manager->close();
    QVERIFY(manager->initialize(newDatabasePath));
    QCOMPARE(manager->openedExistingDatabase(), true);

    const QString invalidDatabasePath = m_tempDir->filePath(QStringLiteral("not-a-database-directory"));
    QVERIFY(QDir().mkpath(invalidDatabasePath));
    QVERIFY(!manager->initialize(invalidDatabasePath));
    // 失败路径只留下诊断，不得覆盖上一次成功初始化的启动上下文。
    QCOMPARE(manager->openedExistingDatabase(), true);
}

void ServiceTests::materializeTodayIsIdempotentAndDoesNotBackfill()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("背单词"), -1));

    const QString today = logicalToday().toString(Qt::ISODate);

    QCOMPARE(manager->materializeToday(), 1);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 1);

    QCOMPARE(manager->materializeToday(), 0);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 1);

    QSqlQuery upd(DatabaseManager::instance()->database());
    QVERIFY2(upd.exec(QStringLiteral("UPDATE routines SET last_generated_date = '2000-01-01'")),
             qPrintable(upd.lastError().text()));
    QCOMPARE(manager->materializeToday(), 1);

    QSqlQuery check(DatabaseManager::instance()->database());
    QVERIFY2(check.exec(QStringLiteral("SELECT last_generated_date FROM routines")),
             qPrintable(check.lastError().text()));
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toString(), today);
}

void ServiceTests::materializeTodayPreservesCategoryAndDoesNotEmitSignals()
{
    RoutineManager* manager = RoutineManager::instance();
    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("例行生成科目"), QStringLiteral("#654321"));
    QVERIFY(categoryId > 0);
    QVERIFY(manager->addRoutine(QStringLiteral("带科目例行"), categoryId));
    QVERIFY(manager->addRoutine(QStringLiteral("无科目例行"), -1));

    QSignalSpy taskSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    QSignalSpy routineSpy(manager, &RoutineManager::routinesChanged);

    QCOMPARE(manager->materializeToday(), 2);
    QCOMPARE(taskSpy.count(), 0);
    QCOMPARE(routineSpy.count(), 0);

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(tasks.size(), 2);

    const QVariantMap categorized = tasks.at(0).toMap();
    QCOMPARE(categorized.value(QStringLiteral("title")).toString(), QStringLiteral("带科目例行"));
    QCOMPARE(categorized.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(categorized.value(QStringLiteral("categoryText")).toString(), QStringLiteral("例行生成科目"));
    QCOMPARE(categorized.value(QStringLiteral("categoryName")).toString(), QStringLiteral("例行生成科目"));
    QCOMPARE(categorized.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#654321"));

    const QVariantMap uncategorized = tasks.at(1).toMap();
    QCOMPARE(uncategorized.value(QStringLiteral("title")).toString(), QStringLiteral("无科目例行"));
    QVERIFY(uncategorized.value(QStringLiteral("categoryId")).isNull());
    QCOMPARE(uncategorized.value(QStringLiteral("categoryText")).toString(), QString());

    QSqlQuery rawTask(DatabaseManager::instance()->database());
    rawTask.prepare(QStringLiteral("SELECT category FROM tasks WHERE title = :title"));
    rawTask.bindValue(QStringLiteral(":title"), QStringLiteral("无科目例行"));
    QVERIFY(rawTask.exec());
    QVERIFY(rawTask.next());
    QCOMPARE(rawTask.value(0).toString(), QString());

    QSqlQuery rawCategorizedTask(DatabaseManager::instance()->database());
    rawCategorizedTask.prepare(QStringLiteral("SELECT category, category_id FROM tasks WHERE title = :title"));
    rawCategorizedTask.bindValue(QStringLiteral(":title"), QStringLiteral("带科目例行"));
    QVERIFY(rawCategorizedTask.exec());
    QVERIFY(rawCategorizedTask.next());
    QCOMPARE(rawCategorizedTask.value(0).toString(), QStringLiteral("例行生成科目"));
    QCOMPARE(rawCategorizedTask.value(1).toInt(), categoryId);
}

void ServiceTests::materializeTodayStampsRoutineId()
{
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("晨间背单词"), -1));
    QCOMPARE(RoutineManager::instance()->materializeToday(), 1);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT t.routine_id, t.routine_generated FROM tasks t JOIN routines r ON r.id = t.routine_id "
        "WHERE t.title = '晨间背单词'")));
    QVERIFY(query.next());
    QVERIFY(query.value(0).toInt() > 0);
    QCOMPARE(query.value(1).toInt(), 1);
}

void ServiceTests::materializeTodayRollsBackClaimWhenTaskInsertFails()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("失败例行"), -1));

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY2(trigger.exec(QStringLiteral(R"SQL(
        CREATE TRIGGER fail_routine_task_insert
        BEFORE INSERT ON tasks
        WHEN NEW.title = '失败例行'
        BEGIN
            SELECT RAISE(ABORT, 'forced routine insert failure');
        END
    )SQL")), qPrintable(trigger.lastError().text()));

    // 触发器模拟插入任务失败；事务必须回滚 last_generated_date 的抢占更新，
    // 否则用户当天会既没有任务，又被标记为已生成。
    QCOMPARE(manager->materializeToday(), 0);

    QSqlQuery routine(DatabaseManager::instance()->database());
    QVERIFY(routine.exec(QStringLiteral("SELECT last_generated_date FROM routines WHERE title = '失败例行'")));
    QVERIFY(routine.next());
    QVERIFY(routine.value(0).isNull());

    QSqlQuery countTasks(DatabaseManager::instance()->database());
    QVERIFY(countTasks.exec(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '失败例行'")));
    QVERIFY(countTasks.next());
    QCOMPARE(countTasks.value(0).toInt(), 0);
}

void ServiceTests::materializeTodayDoesNotResurrectDeletedTask()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("数学真题"), -1));
    QCOMPARE(manager->materializeToday(), 1);

    QVariantList todays = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(todays.size(), 1);
    const int taskId = todays.first().toMap().value(QStringLiteral("id")).toInt();

    // 删掉今天生成的任务后再生成：last_generated_date 已是今天，所以当天不应复活。
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    QCOMPARE(manager->materializeToday(), 0);
    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
}

void ServiceTests::materializeTodaySkipsInactiveRoutines()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("停用项"), -1));
    const int id = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(manager->setRoutineActive(id, false));

    QCOMPARE(manager->materializeToday(), 0);
    QVERIFY(TaskManager::instance()->getTasksByDate(logicalToday()).isEmpty());
}

void ServiceTests::routineWeekdayMaskMatchesIsoWeekdayNumbers()
{
    // 这条用例钉的是整条链路的锚点：界面上的「一」是第 0 位，第 0 位必须是 ISO 的周一。
    // 其余用例都用 maskForDayOfWeek 自己算今天那一位，等号两边用的是同一个函数——
    // 整体平移一天（比如写成 1 << dayOfWeek）它们照样全绿，用户却会发现设了周一三五
    // 任务落在周日二四。所以这里只写字面量，不调用被测函数去解释被测函数。
    QCOMPARE(RoutineRules::kEveryDayMask, 0b1111111);
    QCOMPARE(RoutineRules::maskForDayOfWeek(1), 0b0000001);
    QCOMPARE(RoutineRules::maskForDayOfWeek(2), 0b0000010);
    QCOMPARE(RoutineRules::maskForDayOfWeek(3), 0b0000100);
    QCOMPARE(RoutineRules::maskForDayOfWeek(4), 0b0001000);
    QCOMPARE(RoutineRules::maskForDayOfWeek(5), 0b0010000);
    QCOMPARE(RoutineRules::maskForDayOfWeek(6), 0b0100000);
    QCOMPARE(RoutineRules::maskForDayOfWeek(7), 0b1000000);

    // 越界返回 0：与任何合法掩码相与都是 0，调用方据此判定「今天不生成」。
    QCOMPARE(RoutineRules::maskForDayOfWeek(0), 0);
    QCOMPARE(RoutineRules::maskForDayOfWeek(8), 0);
    QCOMPARE(RoutineRules::maskForDayOfWeek(-1), 0);

    // 再用两个确定的日历日把编号焊到真实星期上，防止「1 号位」本身被理解成周日。
    QCOMPARE(QDate(2026, 9, 21).dayOfWeek(), 1);   // 2026-09-21 是周一
    QCOMPARE(QDate(2026, 9, 27).dayOfWeek(), 7);   // 2026-09-27 是周日
    QCOMPARE(RoutineRules::maskForDayOfWeek(QDate(2026, 9, 21).dayOfWeek()), 0b0000001);
    QCOMPARE(RoutineRules::maskForDayOfWeek(QDate(2026, 9, 27).dayOfWeek()), 0b1000000);
}

void ServiceTests::routineWeekdaysDefaultToEveryDayAndRejectInvalidMask()
{
    RoutineManager* manager = RoutineManager::instance();

    // 省略 weekdays 即「每天」：不传这个参数的老调用方语义必须和加功能之前完全一样。
    QVERIFY(manager->addRoutine(QStringLiteral("每天例行"), -1));
    QVariantList routines = manager->getRoutines();
    QCOMPARE(routines.size(), 1);
    QCOMPARE(routines.first().toMap().value(QStringLiteral("weekdays")).toInt(),
             RoutineRules::kEveryDayMask);

    // 掩码 0 是「一天都不选」这种合法零值：类型、范围检查都拦不住它，
    // 存下去却会让这条例行永远不生成任务，只能靠专门的校验拒绝。
    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: invalid weekday mask 0");
    QVERIFY(!manager->addRoutine(QStringLiteral("空掩码"), -1, 0));
    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: invalid weekday mask 128");
    QVERIFY(!manager->addRoutine(QStringLiteral("越界掩码"), -1, 128));
    QTest::ignoreMessage(QtWarningMsg, "Failed to add routine: invalid weekday mask -1");
    QVERIFY(!manager->addRoutine(QStringLiteral("负掩码"), -1, -1));
    QCOMPARE(manager->getRoutines().size(), 1);

    // 周一、周三、周五 = 1 + 4 + 16。
    const int monWedFri = 0b0010101;
    QVERIFY(manager->addRoutine(QStringLiteral("周一三五"), -1, monWedFri));
    routines = manager->getRoutines();
    QCOMPARE(routines.size(), 2);
    const QVariantMap weekly = routines.at(1).toMap();
    QCOMPARE(weekly.value(QStringLiteral("weekdays")).toInt(), monWedFri);

    const int weeklyId = weekly.value(QStringLiteral("id")).toInt();
    QVERIFY(weeklyId > 0);

    // 重复日走单独的入口，非法掩码在那里也必须被拒绝。
    QTest::ignoreMessage(QtWarningMsg, "Failed to set weekdays of routine: invalid weekday mask 0");
    QVERIFY(!manager->setRoutineWeekdays(weeklyId, 0));
    QTest::ignoreMessage(QtWarningMsg, "Failed to set weekdays of routine: invalid weekday mask 128");
    QVERIFY(!manager->setRoutineWeekdays(weeklyId, 128));
    QTest::ignoreMessage(QtWarningMsg, "Failed to set routine weekdays: routine not found 999999");
    QVERIFY(!manager->setRoutineWeekdays(999999, monWedFri));
    const QVariantMap unchanged = manager->getRoutines().at(1).toMap();
    QCOMPARE(unchanged.value(QStringLiteral("weekdays")).toInt(), monWedFri);

    // 改标题/科目绝不能顺手动重复日：两者是两个入口，SQL 里也各写各的列。
    // 合成一条语句覆盖写时，少传一个参数就会把「周一三五」静默改回「每天」。
    QVERIFY(manager->updateRoutine(weeklyId, QStringLiteral("周一三五改名"), -1));
    const QVariantMap renamed = manager->getRoutines().at(1).toMap();
    QCOMPARE(renamed.value(QStringLiteral("title")).toString(), QStringLiteral("周一三五改名"));
    QCOMPARE(renamed.value(QStringLiteral("weekdays")).toInt(), monWedFri);

    // 服务层校验之外，库层也必须挡住非法掩码：以后新增的写路径、外部编辑、损坏的备份
    // 都不走服务层，只有 CHECK 是最后一道。
    QSqlQuery rawInsert(DatabaseManager::instance()->database());
    QVERIFY(rawInsert.prepare(QStringLiteral(
        "INSERT INTO routines (title, weekdays) VALUES ('库层零掩码', 0)")));
    QVERIFY(!rawInsert.exec());
    QSqlQuery rawUpdate(DatabaseManager::instance()->database());
    QVERIFY(rawUpdate.prepare(QStringLiteral("UPDATE routines SET weekdays = 128")));
    QVERIFY(!rawUpdate.exec());

    // 周六、周日 = 32 + 64。改重复日同样不该动标题。
    const int weekend = 0b1100000;
    QSignalSpy weekdaySpy(manager, &RoutineManager::routinesChanged);
    QVERIFY(weekdaySpy.isValid());
    QVERIFY(manager->setRoutineWeekdays(weeklyId, weekend));
    QCOMPARE(weekdaySpy.count(), 1);
    const QVariantMap updated = manager->getRoutines().at(1).toMap();
    QCOMPARE(updated.value(QStringLiteral("title")).toString(), QStringLiteral("周一三五改名"));
    QCOMPARE(updated.value(QStringLiteral("weekdays")).toInt(), weekend);
}

void ServiceTests::materializeTodayOnlyGeneratesOnSelectedWeekdays()
{
    RoutineManager* manager = RoutineManager::instance();

    // 用例不能假设今天是周几，否则一周里只有一天能通过。按逻辑日算出今天那一位，
    // 再分别构造「命中今天」和「刚好避开今天」的掩码。
    const int todayBit = RoutineRules::maskForDayOfWeek(logicalToday().dayOfWeek());
    QVERIFY(todayBit > 0);
    const int withoutToday = RoutineRules::kEveryDayMask & ~todayBit;

    QVERIFY(manager->addRoutine(QStringLiteral("今天要做"), -1, todayBit));
    QVERIFY(manager->addRoutine(QStringLiteral("今天不做"), -1, withoutToday));

    QCOMPARE(manager->materializeToday(), 1);
    const QVariantList tasks = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("今天要做"));

    // 今天不命中的例行不能被盖上今天的生成戳。盖了的话它照样「今天已生成」，
    // 真正该出现的那天反而会被当成重复而跳过——错误只会晚几天才显形。
    QSqlQuery stamp(DatabaseManager::instance()->database());
    stamp.prepare(QStringLiteral("SELECT last_generated_date FROM routines WHERE title = :title"));
    stamp.bindValue(QStringLiteral(":title"), QStringLiteral("今天不做"));
    QVERIFY2(stamp.exec(), qPrintable(stamp.lastError().text()));
    QVERIFY(stamp.next());
    QVERIFY(stamp.value(0).isNull());

    // 重复日改成每天之后，同一天再刷新就应该补出来：生成按当前设置算，不看改之前的设置。
    const int skippedId = manager->getRoutines().at(1).toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(skippedId > 0);
QVERIFY(manager->setRoutineWeekdays(skippedId, RoutineRules::kEveryDayMask));
    QCOMPARE(manager->materializeToday(), 1);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 2);

    // 幂等性不能因为加了星期条件而破掉：同一天再跑一次仍然是 0 条。
    QCOMPARE(manager->materializeToday(), 0);
    QCOMPARE(TaskManager::instance()->getTasksByDate(logicalToday()).size(), 2);
}

void ServiceTests::migrationV15AddsRoutineWeekdaysAndKeepsExistingRoutines()
{
    QSqlQuery query(DatabaseManager::instance()->database());

    // 把 routines 换回 v14 形态（没有 weekdays 列）。外键开关要在事务外关掉，
    // 否则 DROP 旧表会触发 tasks 上的级联动作；重建完立刻恢复。
    QVERIFY(dropSyncTriggers(DatabaseManager::instance()->database()));
    QVERIFY2(query.exec(QStringLiteral("PRAGMA foreign_keys = OFF")),
             qPrintable(query.lastError().text()));
    QVERIFY2(query.exec(QStringLiteral(R"SQL(
        CREATE TABLE routines_v14 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            active INTEGER NOT NULL DEFAULT 1,
            display_order INTEGER NOT NULL DEFAULT 0,
            last_generated_date TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    )SQL")),
             qPrintable(query.lastError().text()));
    QVERIFY2(query.exec(QStringLiteral(
                 "INSERT INTO routines_v14 (title, active, display_order, last_generated_date) "
                 "VALUES ('升级前的例行', 1, 3, '2026-06-10')")),
             qPrintable(query.lastError().text()));
    QVERIFY2(query.exec(QStringLiteral("DROP TABLE routines")),
             qPrintable(query.lastError().text()));
    QVERIFY2(query.exec(QStringLiteral("ALTER TABLE routines_v14 RENAME TO routines")),
             qPrintable(query.lastError().text()));
    QVERIFY2(query.exec(QStringLiteral("PRAGMA foreign_keys = ON")),
             qPrintable(query.lastError().text()));
    QVERIFY2(query.exec(QStringLiteral("PRAGMA user_version = 14")),
             qPrintable(query.lastError().text()));

    QVERIFY(DatabaseManager::instance()->createTables());

    // 既有例行原样保留，并按「每天」回落：升级前它天天生成，升级后也必须天天生成。
    QVERIFY2(query.exec(QStringLiteral(
                 "SELECT title, active, display_order, last_generated_date, weekdays FROM routines")),
             qPrintable(query.lastError().text()));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("升级前的例行"));
    QCOMPARE(query.value(1).toInt(), 1);
    QCOMPARE(query.value(2).toInt(), 3);
    QCOMPARE(query.value(3).toString(), QStringLiteral("2026-06-10"));
    QCOMPARE(query.value(4).toInt(), RoutineRules::kEveryDayMask);
    QVERIFY(!query.next());

    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);

    // DROP TABLE 会把表上的索引一起带走；建表收尾那一步必须把它重新建回来。
    QVERIFY(query.exec(QStringLiteral(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_routines_active'")));
    QVERIFY(query.next());

    // ALTER TABLE ADD COLUMN 带的 CHECK 是否真的生效，必须在迁移出来的库上验一次：
    // 只验新建库的话，旧用户升上来的那张表可能没有任何库层约束，而那正是最需要兜底的一张。
    QSqlQuery rawInsert(DatabaseManager::instance()->database());
    QVERIFY(rawInsert.prepare(QStringLiteral(
        "INSERT INTO routines (title, weekdays) VALUES ('迁移后零掩码', 0)")));
    QVERIFY(!rawInsert.exec());
    QSqlQuery rawUpdate(DatabaseManager::instance()->database());
    QVERIFY(rawUpdate.prepare(QStringLiteral("UPDATE routines SET weekdays = -1")));
    QVERIFY(!rawUpdate.exec());

    // 重跑一次不应再改动任何东西：结构守卫看的是列在不在，不是版本号。
    QVERIFY(DatabaseManager::instance()->createTables());
    QVERIFY(query.exec(QStringLiteral("SELECT weekdays FROM routines")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), RoutineRules::kEveryDayMask);
}

void ServiceTests::migrationV16AddsCompletionNoteAndKeepsExistingTasks()
{
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("升级前的任务"), today, QString(), true);
    QVERIFY(taskId > 0);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.prepare(QStringLiteral("UPDATE tasks SET notes = '升级前的备注' WHERE id = :id")));
    query.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY2(query.exec(), qPrintable(query.lastError().text()));

    // 把 tasks 退回 v15 形态：删掉完成记录列，版本号改回 15。
    QVERIFY(dropSyncTriggers(DatabaseManager::instance()->database()));
    QVERIFY2(query.exec(QStringLiteral("ALTER TABLE tasks DROP COLUMN completion_note")),
             qPrintable(query.lastError().text()));
    QVERIFY2(query.exec(QStringLiteral("PRAGMA user_version = 15")),
             qPrintable(query.lastError().text()));

    QVERIFY(DatabaseManager::instance()->createTables());

    // 既有任务原样保留，完成记录按「没写」回落——是空串，不是 NULL。
    QVERIFY(query.prepare(QStringLiteral(
        "SELECT title, completed, notes, completion_note FROM tasks WHERE id = :id")));
    query.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY2(query.exec(), qPrintable(query.lastError().text()));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("升级前的任务"));
    QCOMPARE(query.value(1).toInt(), 1);
    QCOMPARE(query.value(2).toString(), QStringLiteral("升级前的备注"));
    QVERIFY(!query.value(3).isNull());
    QVERIFY(query.value(3).toString().isEmpty());

    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);

    // ALTER TABLE ADD COLUMN 带的 NOT NULL 要在迁移出来的表上真的生效，
    // 只验新建库的话，旧用户升上来的那张表可能没有这道库层约束。
    QSqlQuery rawUpdate(DatabaseManager::instance()->database());
    QVERIFY(rawUpdate.prepare(QStringLiteral("UPDATE tasks SET completion_note = NULL")));
    QVERIFY(!rawUpdate.exec());

    // 迁移后服务层能直接写读这一列。
    TaskManager* tasks = TaskManager::instance();
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("升级后补的记录")));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("升级后补的记录"));

    // 重跑一次不再改动任何东西：结构守卫看的是列在不在，不是版本号。
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("升级后补的记录"));

    // 半迁移状态：版本号已经是当前版本，列却不在（中断的恢复、外部改库都会留下这种库）。
    // 守卫只看版本号的话这一列永远补不回来，每次打开任务页都查询失败。
    // 上面的 createTables 又装回了同步触发器，外部删列之前同样得先拆掉它们。
    QVERIFY(dropSyncTriggers(DatabaseManager::instance()->database()));
    QVERIFY2(query.exec(QStringLiteral("ALTER TABLE tasks DROP COLUMN completion_note")),
             qPrintable(query.lastError().text()));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
    query.finish();
    QVERIFY(DatabaseManager::instance()->createTables());
    QVERIFY(tasks->getTask(taskId).value(QStringLiteral("id")).toInt() == taskId);
    QVERIFY(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString().isEmpty());
}

// 2026-09「目标」页连同数据一起删掉：v17 删 long_goals 表。
// 删表丢的是用户写下的目标，所以表在的时候，删之前必须先有一份迁移快照，而且快照里真有那条目标。
// 从来没有这张表的库只推版本号，不为此重建整库副本（会挤掉更早的快照）。
void ServiceTests::migrationV17DropsLongGoalsAfterSnapshot()
{
    DatabaseManager::instance()->close();

    // 迁移快照写在数据库同目录。用独立子目录，免得数到 init() 给默认测试库留下的快照。
    const QString dirPath = m_tempDir->filePath(QStringLiteral("v17-drop-goals"));
    QVERIFY(QDir().mkpath(dirPath));
    const QDir dir(dirPath);
    const QStringList snapshotPattern{QStringLiteral("pomodoro_backup_*.db")};
    const QString dbPath = dir.filePath(QStringLiteral("before-v17.sqlite"));

    // 先用当前代码建一份完整的库，再退回 v16：补上旧版目标服务懒建的那张表、它的索引和一条目标。
    // 任务必须走 createTask：直接 INSERT 的行排序号是 0，会触发 v12 的排序自愈，
    // 那一步自己就会建迁移快照——下面数到的就不是 v17 建的那份了，断言等于没验。
    QVERIFY(DatabaseManager::instance()->initialize(dbPath));
    const int taskId = TaskManager::instance()->createTask(
        QStringLiteral("升级前的任务"), QVariant(logicalToday()), -1, 0, QString());
    QVERIFY(taskId > 0);
    const QString createGoalTable = QStringLiteral(
        "CREATE TABLE long_goals ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,"
        " category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,"
        " start_date TEXT NOT NULL, deadline TEXT,"
        " display_order INTEGER NOT NULL DEFAULT 0,"
        " fired_milestones INTEGER NOT NULL DEFAULT 0, achieved_at TEXT,"
        " created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        " target_minutes INTEGER NOT NULL DEFAULT 0)");
    const auto goalObjectCount = [] {
        QSqlQuery count(DatabaseManager::instance()->database());
        if (!count.exec(QStringLiteral(
                "SELECT COUNT(*) FROM sqlite_master "
                "WHERE name IN ('long_goals', 'idx_long_goals_order')"))
            || !count.next()) {
            return -1;
        }
        return count.value(0).toInt();
    };
    const auto schemaVersion = [] {
        QSqlQuery version(DatabaseManager::instance()->database());
        return version.exec(QStringLiteral("PRAGMA user_version")) && version.next()
            ? version.value(0).toInt() : -1;
    };
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY2(query.exec(createGoalTable), qPrintable(query.lastError().text()));
        QVERIFY(query.exec(QStringLiteral(
            "CREATE INDEX idx_long_goals_order ON long_goals(display_order)")));
        QVERIFY(query.exec(QStringLiteral(
            "INSERT INTO long_goals (title, start_date, target_minutes, achieved_at) "
            "VALUES ('升级前的目标', '2026-08-01', 600, '2026-08-20T21:00:00')")));
        QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 16")));
    }
    QCOMPARE(goalObjectCount(), 2);

    const QStringList snapshotsBefore = dir.entryList(snapshotPattern, QDir::Files);
    QVERIFY(DatabaseManager::instance()->createTables());

    // 表和索引都没了，其它数据原样，版本号推到当前版本。
    QCOMPARE(goalObjectCount(), 0);
    QCOMPARE(TaskManager::instance()->getTask(taskId).value(QStringLiteral("title")).toString(),
             QStringLiteral("升级前的任务"));
    QCOMPARE(schemaVersion(), DatabaseManager::kCurrentSchemaVersion);
    // 版本号变了就回来复核本用例。v18 复核过：v17 这一步照旧建快照，紧接着的 v18 迁移
    // 发现本轮已经建过快照就不再建，所以下面「新增快照恰好一份」仍然成立。
    QCOMPARE(DatabaseManager::kCurrentSchemaVersion, 18);

    // 删之前留了一份快照，里面那条目标还在：用户真想找回，数据目录里有。
    QStringList newSnapshots = dir.entryList(snapshotPattern, QDir::Files);
    for (const QString& name : snapshotsBefore) {
        newSnapshots.removeAll(name);
    }
    QCOMPARE(newSnapshots.size(), 1);
    const QString verificationConnection = QStringLiteral("V17SnapshotVerificationConnection");
    {
        QSqlDatabase snapshot = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),
                                                          verificationConnection);
        snapshot.setDatabaseName(dir.filePath(newSnapshots.constFirst()));
        QVERIFY(snapshot.open());
        QSqlQuery goalQuery(snapshot);
        QVERIFY(goalQuery.exec(QStringLiteral("SELECT title, target_minutes FROM long_goals")));
        QVERIFY(goalQuery.next());
        QCOMPARE(goalQuery.value(0).toString(), QStringLiteral("升级前的目标"));
        QCOMPARE(goalQuery.value(1).toInt(), 600);
        QVERIFY(!goalQuery.next());
        goalQuery.finish();
        snapshot.close();
    }
    QSqlDatabase::removeDatabase(verificationConnection);

    // 从没用过目标页的 v16 库（没有这张表）升上来：v17 照样执行、推版本号，但不为此新建快照。
    const int snapshotCountAfterDrop = dir.entryList(snapshotPattern, QDir::Files).size();
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 16")));
    }
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(schemaVersion(), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(dir.entryList(snapshotPattern, QDir::Files).size(), snapshotCountAfterDrop);

    // 半迁移：版本号已经是当前版本，表却在（外部改库、恢复中途被打断）。守卫只看版本号的话，
    // 这张表会一直留着；这里要照样删掉。
    {
        QSqlQuery query(DatabaseManager::instance()->database());
        QVERIFY2(query.exec(createGoalTable), qPrintable(query.lastError().text()));
    }
    QCOMPARE(schemaVersion(), DatabaseManager::kCurrentSchemaVersion);
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(goalObjectCount(), 0);
}

void ServiceTests::migrationV5RebuildKeepsCompletionNote()
{
    // v5 整表重建用的是写死的列清单。完成记录是 v16 才加的列，
    // 漏进清单的话，一次外键修复就会把所有完成记录静默抹掉。
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("写过记录的任务"), today, QString(), true);
    QVERIFY(taskId > 0);

    QSqlQuery seed(DatabaseManager::instance()->database());
    QVERIFY(seed.prepare(QStringLiteral(
        "UPDATE tasks SET completion_note = '做完第二章' WHERE id = :id")));
    seed.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY2(seed.exec(), qPrintable(seed.lastError().text()));

    // 同样用「外键动作不对」把 v5 重建逼出来；user_version 保持当前版本，
    // 模拟一个已经迁移完成、只是外键被外部改坏的库。
    QSqlQuery rebuild(DatabaseManager::instance()->database());
    QVERIFY(rebuild.exec(QStringLiteral("PRAGMA foreign_keys = OFF")));
    const QStringList breakForeignKey = {
        QStringLiteral(R"SQL(
            CREATE TABLE tasks_broken (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                category_id INTEGER REFERENCES categories(id),
                routine_id INTEGER REFERENCES routines(id) ON DELETE CASCADE,
                routine_generated INTEGER NOT NULL DEFAULT 0 CHECK(routine_generated IN (0, 1)),
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                estimated_minutes INTEGER NOT NULL DEFAULT 0,
                notes TEXT NOT NULL DEFAULT '',
                display_order INTEGER NOT NULL DEFAULT 0,
                completion_note TEXT NOT NULL DEFAULT ''
            )
        )SQL"),
        QStringLiteral("INSERT INTO tasks_broken SELECT id, title, category, category_id, "
                       "routine_id, routine_generated, date, completed, created_at, "
                       "estimated_minutes, notes, display_order, completion_note FROM tasks"),
        QStringLiteral("DROP TABLE tasks"),
        QStringLiteral("ALTER TABLE tasks_broken RENAME TO tasks")
    };
    for (const QString& statement : breakForeignKey) {
        QVERIFY2(rebuild.exec(statement), qPrintable(rebuild.lastError().text()));
    }
    QVERIFY(rebuild.exec(QStringLiteral("PRAGMA foreign_keys = ON")));

    QVERIFY(DatabaseManager::instance()->createTables());

    QSqlQuery check(DatabaseManager::instance()->database());
    QVERIFY(check.prepare(QStringLiteral("SELECT completion_note FROM tasks WHERE id = :id")));
    check.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY2(check.exec(), qPrintable(check.lastError().text()));
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toString(), QStringLiteral("做完第二章"));
}

void ServiceTests::freshDatabaseHasRoutineIdColumn()
{
    // 新库直建路径必须同时带关联和可信来源列，不能再靠 routine_id 猜任务来源。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT routine_id, routine_generated FROM tasks LIMIT 1")));
}

void ServiceTests::migrationV4DoesNotGuessRoutineLineage()
{
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1));
    const QDate yesterday = QDate::currentDate().addDays(-1);
    const int routineLikeId = insertTaskRow(QStringLiteral("背单词"), yesterday);
    const int plainId = insertTaskRow(QStringLiteral("普通任务"), yesterday);
    QVERIFY(routineLikeId > 0);
    QVERIFY(plainId > 0);

    // 把版本拨回 3 重跑升级路径；同名只能证明文本相同，不能证明任务由例行规则生成。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 3")));
    QVERIFY(DatabaseManager::instance()->createTables());

    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks WHERE id = %1").arg(routineLikeId)));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());

    QVERIFY(query.exec(QStringLiteral("SELECT routine_id FROM tasks WHERE id = %1").arg(plainId)));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());

    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
}

void ServiceTests::migrationV6ClearsUntrustedRoutineLineage()
{
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("同名旧任务"), -1));
    const int taskId = insertTaskRow(QStringLiteral("同名旧任务"), logicalToday().addDays(-1));
    QVERIFY(taskId > 0);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "UPDATE tasks SET routine_id = (SELECT id FROM routines WHERE title = '同名旧任务'), "
        "routine_generated = 0 WHERE id = %1").arg(taskId)));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 5")));

    QVERIFY(DatabaseManager::instance()->createTables());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT routine_id, routine_generated FROM tasks WHERE id = %1").arg(taskId)));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());
    QCOMPARE(query.value(1).toInt(), 0);

    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
}

void ServiceTests::migrationV14CreatesKnowledgeGapsAndKeepsExistingData()
{
    // 带旧数据跑升级：迁移正确与否要看既有内容有没有被动过，光看版本号涨了不算数。
    const int taskId = insertTaskRow(QStringLiteral("升级前就有的任务"), logicalToday());
    QVERIFY(taskId > 0);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DROP TABLE IF EXISTS knowledge_gaps")));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 13")));

    QVERIFY(DatabaseManager::instance()->createTables());

    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);

    QVERIFY(query.exec(QStringLiteral(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_gaps'")));
    QVERIFY(query.next());

    // v14 是纯新增表，不读也不写任何旧表；既有任务必须原封不动。
    QVERIFY(query.exec(QStringLiteral("SELECT title FROM tasks WHERE id = %1").arg(taskId)));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toString(), QStringLiteral("升级前就有的任务"));
}

void ServiceTests::migrationV14RejectsStructurallyBrokenKnowledgeGapTable()
{
    // 只判表名存在是假安全：缺列的表照样能通过 CREATE TABLE IF NOT EXISTS，
    // 随后一路报成功，直到用户真的打开知识缺口页才查询失败。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("DROP TABLE IF EXISTS knowledge_gaps")));
    QVERIFY(query.exec(QStringLiteral(
        "CREATE TABLE knowledge_gaps (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)")));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = %1")
                           .arg(DatabaseManager::kCurrentSchemaVersion)));

    QVERIFY(!DatabaseManager::instance()->createTables());

    // 收拾干净，避免这条用例把坏结构留给后面的用例。
    QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 13")));
    QVERIFY(DatabaseManager::instance()->createTables());
}

void ServiceTests::migrationV14RejectsKnowledgeGapForeignKeyThatCascades()
{
    // 列和 CHECK 全对、只把外键动作写成 CASCADE 的表，只看前两样的结构校验会放行。
    // 放行之后一切正常，直到用户删掉一条来源任务——手写的缺口被连带删除，没有任何报错。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_gaps'")));
    QVERIFY(query.next());
    QString createSql = query.value(0).toString();
    query.finish();
    const QString setNull =
        QStringLiteral("source_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL");
    QVERIFY(createSql.contains(setNull));
    createSql.replace(setNull,
                      QStringLiteral("source_task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE"));

    QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
    QVERIFY2(query.exec(createSql), qPrintable(query.lastError().text()));

    QVERIFY(!DatabaseManager::instance()->createTables());

    // 收拾干净，避免这条用例把坏结构留给后面的用例。
    QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 13")));
    QVERIFY(DatabaseManager::instance()->createTables());
}

void ServiceTests::migrationV14RejectsCompositeKnowledgeGapForeignKey()
{
    // 把两列并成一条复合外键：PRAGMA foreign_key_list 排出来的每一行，目标表、目标列、
    // 删除动作都符合契约，只有约束编号和列序号能看出它们其实是同一条约束。
    // 放行的代价不是理论上的：tasks 上没有 (id, id) 的复合唯一索引，这样的库能正常启动，
    // 但用户新增任何一条知识缺口都会被 SQLite 以 foreign key mismatch 拒绝——
    // 界面只会说保存失败，看不出是结构问题。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_gaps'")));
    QVERIFY(query.next());
    QString createSql = query.value(0).toString();
    query.finish();

    const QString sourceColumn =
        QStringLiteral("source_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL");
    const QString linkedColumn =
        QStringLiteral("linked_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL");
    QVERIFY(createSql.contains(sourceColumn));
    QVERIFY(createSql.contains(linkedColumn));
    createSql.replace(sourceColumn, QStringLiteral("source_task_id INTEGER"));
    createSql.replace(linkedColumn, QStringLiteral("linked_task_id INTEGER"));
    const int closingParen = createSql.lastIndexOf(QLatin1Char(')'));
    QVERIFY(closingParen > 0);
    createSql.insert(closingParen,
                     QStringLiteral(", FOREIGN KEY (source_task_id, linked_task_id) "
                                    "REFERENCES tasks(id, id) ON DELETE SET NULL\n        "));

    QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
    QVERIFY2(query.exec(createSql), qPrintable(query.lastError().text()));

    QVERIFY(!DatabaseManager::instance()->createTables());

    // 收拾干净，避免这条用例把坏结构留给后面的用例。
    QVERIFY(query.exec(QStringLiteral("DROP TABLE knowledge_gaps")));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 13")));
    QVERIFY(DatabaseManager::instance()->createTables());
}

void ServiceTests::freshDatabaseCreatesVersion4PresetCategories()
{
    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);

    const QVariantList presets = CategoryManager::instance()->getPresetCategories();
    QCOMPARE(presets.size(), 5);

    const QStringList expectedNames = {
        QStringLiteral("数学"),
        QStringLiteral("英语"),
        QStringLiteral("政治"),
        QStringLiteral("专业课"),
        QStringLiteral("其他")
    };
    const QStringList expectedColors = {
        QStringLiteral("#d4a574"),
        QStringLiteral("#c9956e"),
        QStringLiteral("#be8568"),
        QStringLiteral("#b37562"),
        QStringLiteral("#a8655c")
    };

    for (int index = 0; index < presets.size(); ++index) {
        const QVariantMap category = presets.at(index).toMap();
        QCOMPARE(category.value(QStringLiteral("name")).toString(), expectedNames.at(index));
        QCOMPARE(category.value(QStringLiteral("color")).toString(), expectedColors.at(index));
        QCOMPARE(category.value(QStringLiteral("isPreset")).toBool(), true);
        QCOMPARE(category.value(QStringLiteral("displayOrder")).toInt(), index + 1);
    }
}

void ServiceTests::migrationV10ConvertsPomodoroEstimateToMinutes()
{
    // v10 把「预估番茄数」换成「预计用时（分钟）」。换算基准无法从旧数据还原
    // （旧库只存个数，没存当时的专注时长设置），实现里固定用 25 分钟折算，
    // 这条用例把那个基准钉死——将来有人改基准，必须是有意识的决定。
    QSqlQuery setup(DatabaseManager::instance()->database());
    QVERIFY(setup.exec(QStringLiteral("PRAGMA user_version = 9")));
    QVERIFY(setup.exec(QStringLiteral(
        "ALTER TABLE tasks ADD COLUMN estimated_pomodoros INTEGER NOT NULL DEFAULT 0")));

    const int estimated = insertTaskRow(QStringLiteral("有预估的任务"), logicalToday());
    const int plain = insertTaskRow(QStringLiteral("没预估的任务"), logicalToday());
    QVERIFY(estimated > 0 && plain > 0);
    setup.prepare(QStringLiteral(
        "UPDATE tasks SET estimated_pomodoros = 4, estimated_minutes = 0 WHERE id = :id"));
    setup.bindValue(QStringLiteral(":id"), estimated);
    QVERIFY(setup.exec());

    QVERIFY(DatabaseManager::instance()->createTables());

    QSqlQuery check(DatabaseManager::instance()->database());
    check.prepare(QStringLiteral("SELECT estimated_minutes FROM tasks WHERE id = :id"));
    check.bindValue(QStringLiteral(":id"), estimated);
    QVERIFY(check.exec());
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toInt(), 100);   // 4 个番茄 × 25 分钟

    check.bindValue(QStringLiteral(":id"), plain);
    QVERIFY(check.exec());
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toInt(), 0);     // 原本没预估的保持 0，不该被折算出数字

    // 旧列换算完就删掉，不留一个没人读却像事实源的死列。
    QSqlQuery info(DatabaseManager::instance()->database());
    QVERIFY(info.exec(QStringLiteral("PRAGMA table_info(tasks)")));
    QStringList columns;
    while (info.next()) {
        columns.append(info.value(1).toString());
    }
    QVERIFY(columns.contains(QStringLiteral("estimated_minutes")));
    QVERIFY(!columns.contains(QStringLiteral("estimated_pomodoros")));
}

void ServiceTests::migrationV10IsIdempotentAndDoesNotLoop()
{
    // 回归点：v7 的结构检查原本查 estimated_pomodoros，而 v10 会删掉那一列。
    // 若仍按旧列名判断，一个已迁到 v10 的库每次启动都会重跑 v7–v10 四步迁移。
    //
    // 注意最终状态是自愈的（v7 重加旧列，v10 又删掉；回填有 estimated_minutes = 0
    // 守卫所以不覆写用户数据）——所以光看结束状态**测不出来**，必须观察「有没有重跑」
    // 本身。这里拦截迁移日志：已经是最新版本时，再次建表不得输出任何 migrated 记录。
    const int taskId = insertTaskRow(QStringLiteral("已换算的任务"), logicalToday());
    QVERIFY(taskId > 0);
    QSqlQuery seed(DatabaseManager::instance()->database());
    seed.prepare(QStringLiteral("UPDATE tasks SET estimated_minutes = 90 WHERE id = :id"));
    seed.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(seed.exec());

    // 第一次先把库带到最新版本。
    QVERIFY(DatabaseManager::instance()->createTables());

    // 之后再建表两次，捕获迁移日志：不该再有任何一步迁移被执行。
    static QStringList migrationLogs;
    migrationLogs.clear();
    QtMessageHandler previous = qInstallMessageHandler(
        [](QtMsgType type, const QMessageLogContext&, const QString& text) {
            if (type == QtInfoMsg && text.contains(QStringLiteral("migrated to version"))) {
                migrationLogs.append(text);
            }
        });
    for (int i = 0; i < 2; ++i) {
        QVERIFY(DatabaseManager::instance()->createTables());
    }
    qInstallMessageHandler(previous);
    QVERIFY2(migrationLogs.isEmpty(),
             qPrintable(QStringLiteral("已是最新版本却仍重跑了迁移: ")
                        + migrationLogs.join(QStringLiteral(" / "))));

    QSqlQuery info(DatabaseManager::instance()->database());
    QVERIFY(info.exec(QStringLiteral("PRAGMA table_info(tasks)")));
    QStringList columns;
    while (info.next()) {
        columns.append(info.value(1).toString());
    }
    // 旧列不该被重新加回来。
    QVERIFY(!columns.contains(QStringLiteral("estimated_pomodoros")));

    // 用户填的分钟数必须原样保留，不被回填覆写。
    QSqlQuery check(DatabaseManager::instance()->database());
    check.prepare(QStringLiteral("SELECT estimated_minutes FROM tasks WHERE id = :id"));
    check.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(check.exec());
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toInt(), 90);

    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
}

void ServiceTests::migrationV12NormalizesVisibleOrderAndIsIdempotent()
{
    const QString date = QStringLiteral("2026-08-12");
    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, created_at, display_order) "
        "VALUES (:title, :date, :completed, :createdAt, :displayOrder)"));

    auto insertLegacyTask = [&](const QString& title, bool completed,
                                const QString& createdAt, int displayOrder) {
        insert.bindValue(QStringLiteral(":title"), title);
        insert.bindValue(QStringLiteral(":date"), date);
        insert.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
        insert.bindValue(QStringLiteral(":createdAt"), createdAt);
        insert.bindValue(QStringLiteral(":displayOrder"), displayOrder);
        return insert.exec();
    };

    // 正序号、0、重复序号、完成组和相同时间戳都出现，才能覆盖 v11 的完整可见顺序。
    QVERIFY(insertLegacyTask(QStringLiteral("正序二"), false,
                             QStringLiteral("2026-08-12T08:00:00"), 2));
    QVERIFY(insertLegacyTask(QStringLiteral("零序"), false,
                             QStringLiteral("2026-08-12T07:00:00"), 0));
    QVERIFY(insertLegacyTask(QStringLiteral("正序一甲"), false,
                             QStringLiteral("2026-08-12T09:00:00"), 1));
    QVERIFY(insertLegacyTask(QStringLiteral("正序一乙"), false,
                             QStringLiteral("2026-08-12T09:00:00"), 1));
    QVERIFY(insertLegacyTask(QStringLiteral("已完成"), true,
                             QStringLiteral("2026-08-12T06:00:00"), 0));

    QSqlQuery legacyOrder(DatabaseManager::instance()->database());
    legacyOrder.prepare(QStringLiteral(
        "SELECT id, title FROM tasks WHERE date = :date "
        "ORDER BY completed ASC, "
        "CASE WHEN display_order = 0 THEN 1 ELSE 0 END ASC, "
        "display_order ASC, created_at ASC, id ASC"));
    legacyOrder.bindValue(QStringLiteral(":date"), date);
    QVERIFY(legacyOrder.exec());
    QList<int> expectedIds;
    QStringList expectedTitles;
    while (legacyOrder.next()) {
        expectedIds.append(legacyOrder.value(0).toInt());
        expectedTitles.append(legacyOrder.value(1).toString());
    }
    QCOMPARE(expectedTitles,
             QStringList({QStringLiteral("正序一甲"), QStringLiteral("正序一乙"),
                          QStringLiteral("正序二"), QStringLiteral("零序"),
                          QStringLiteral("已完成")}));

    QSqlQuery version(DatabaseManager::instance()->database());
    QVERIFY(version.exec(QStringLiteral("PRAGMA user_version = 11")));
    QVERIFY(DatabaseManager::instance()->createTables());

    auto readNormalizedRows = [&]() {
        QList<QPair<int, int>> rows;
        QSqlQuery query(DatabaseManager::instance()->database());
        query.prepare(QStringLiteral(
            "SELECT id, display_order FROM tasks WHERE date = :date "
            "ORDER BY completed ASC, display_order ASC"));
        query.bindValue(QStringLiteral(":date"), date);
        if (!query.exec()) {
            return rows;
        }
        while (query.next()) {
            rows.append({query.value(0).toInt(), query.value(1).toInt()});
        }
        return rows;
    };

    const QList<QPair<int, int>> migratedRows = readNormalizedRows();
    QCOMPARE(migratedRows.size(), expectedIds.size());
    for (int index = 0; index < migratedRows.size(); ++index) {
        QCOMPARE(migratedRows.at(index).first, expectedIds.at(index));
        QCOMPARE(migratedRows.at(index).second, index + 1);
    }
    QVERIFY(version.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(version.next());
    // createTables 会把整条迁移链跑到头，不会停在 v12；断言的是「链跑完了」，
    // 而不是「当前最高版本恰好是 12」——写死数字会让每次新增迁移都误伤这条用例。
    QCOMPARE(version.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);
    version.finish();

    // 已归一的 v12 再次初始化不得重排，也不得重复跑迁移。
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(readNormalizedRows(), migratedRows);

    // 防御性重入不能只看 user_version：恢复中断留下 0 时也必须重新归一。
    QSqlQuery corrupt(DatabaseManager::instance()->database());
    corrupt.prepare(QStringLiteral("UPDATE tasks SET display_order = 0 WHERE id = :id"));
    corrupt.bindValue(QStringLiteral(":id"), expectedIds.last());
    QVERIFY(corrupt.exec());
    QVERIFY(DatabaseManager::instance()->createTables());
    const QList<QPair<int, int>> repairedRows = readNormalizedRows();
    QCOMPARE(repairedRows.size(), expectedIds.size());
    QSet<int> uniqueOrders;
    for (const auto& row : repairedRows) {
        QVERIFY(row.second > 0);
        QVERIFY(!uniqueOrders.contains(row.second));
        uniqueOrders.insert(row.second);
    }
}

void ServiceTests::migrationV5RebuildKeepsColumnsAddedAfterV5()
{
    // v5 迁移的触发条件是「version < 5 **或** tasks.routine_id 的外键动作不是 SET NULL」。
    // 后一条是为了修半迁移状态，但它会让一个已经是 v9 的库也走进 v5 的整表重建，
    // 而那次重建用的是冻结在 v5 那一刻的列清单——v5 之后新增的列会被静默丢掉。
    //
    // v6 的 routine_generated 被专门保住了（provenanceExpression），说明写的人想过这件事；
    // v7 的预估列没有——这正是本用例要锁住的缺口（该列在 v10 已更名为 estimated_minutes）。
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("有预估的任务"), today);
    QVERIFY(taskId > 0);

    QSqlQuery seed(DatabaseManager::instance()->database());
    seed.prepare(QStringLiteral(
        "UPDATE tasks SET estimated_minutes = 125 WHERE id = :id"));
    seed.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(seed.exec());

    // 把 tasks 的外键动作改成非 SET NULL，制造出「结构检查判定需要重建」的局面。
    // 现实中同一条路径还有另一个入口：routineForeignKeyUsesSetNull() 在 PRAGMA
    // 查询失败时也返回 false，分不清「外键真的不对」和「这次没查成功」。
    // user_version 保持在当前版本不动，模拟的就是一个已完成迁移的库。
    QSqlQuery rebuild(DatabaseManager::instance()->database());
    QVERIFY(rebuild.exec(QStringLiteral("PRAGMA foreign_keys = OFF")));
    const QStringList breakForeignKey = {
        QStringLiteral(R"SQL(
            CREATE TABLE tasks_broken (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                category_id INTEGER REFERENCES categories(id),
                routine_id INTEGER REFERENCES routines(id) ON DELETE CASCADE,
                routine_generated INTEGER NOT NULL DEFAULT 0 CHECK(routine_generated IN (0, 1)),
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                estimated_minutes INTEGER NOT NULL DEFAULT 0
            )
        )SQL"),
        QStringLiteral("INSERT INTO tasks_broken SELECT id, title, category, category_id, "
                       "routine_id, routine_generated, date, completed, created_at, "
                       "estimated_minutes FROM tasks"),
        QStringLiteral("DROP TABLE tasks"),
        QStringLiteral("ALTER TABLE tasks_broken RENAME TO tasks")
    };
    for (const QString& statement : breakForeignKey) {
        QVERIFY2(rebuild.exec(statement), qPrintable(rebuild.lastError().text()));
    }
    QVERIFY(rebuild.exec(QStringLiteral("PRAGMA foreign_keys = ON")));

    QVERIFY(DatabaseManager::instance()->createTables());

    // 重建后预计用时必须原样还在——丢的是用户手填的数据，且没有任何提示。
    QSqlQuery check(DatabaseManager::instance()->database());
    check.prepare(QStringLiteral("SELECT estimated_minutes FROM tasks WHERE id = :id"));
    check.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(check.exec());
    QVERIFY(check.next());
    QCOMPARE(check.value(0).toInt(), 125);
}

void ServiceTests::migrationV5RefusesToRebuildWhenTasksHasAnUnknownColumn()
{
    // 复发路径：以后给 tasks 加了列却忘了更新 v5 重建清单。此前的行为是静默丢列丢数据，
    // 事后既察觉不到也还原不了。现在要求它直接失败并留下日志。
    QSqlQuery prepare(DatabaseManager::instance()->database());
    QVERIFY(prepare.exec(QStringLiteral(
        "ALTER TABLE tasks ADD COLUMN future_column TEXT")));

    // 同样用「外键动作不对」把 v5 重建逼出来。
    QVERIFY(prepare.exec(QStringLiteral("PRAGMA foreign_keys = OFF")));
    const QStringList breakForeignKey = {
        QStringLiteral(R"SQL(
            CREATE TABLE tasks_broken (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                category_id INTEGER REFERENCES categories(id),
                routine_id INTEGER REFERENCES routines(id) ON DELETE CASCADE,
                routine_generated INTEGER NOT NULL DEFAULT 0 CHECK(routine_generated IN (0, 1)),
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                estimated_minutes INTEGER NOT NULL DEFAULT 0,
                future_column TEXT
            )
        )SQL"),
        QStringLiteral("INSERT INTO tasks_broken SELECT id, title, category, category_id, "
                       "routine_id, routine_generated, date, completed, created_at, "
                       "estimated_minutes, future_column FROM tasks"),
        QStringLiteral("DROP TABLE tasks"),
        QStringLiteral("ALTER TABLE tasks_broken RENAME TO tasks")
    };
    for (const QString& statement : breakForeignKey) {
        QVERIFY2(prepare.exec(statement), qPrintable(prepare.lastError().text()));
    }
    QVERIFY(prepare.exec(QStringLiteral("PRAGMA foreign_keys = ON")));

    // 迁移必须失败，而不是丢掉 future_column。
    QVERIFY(!DatabaseManager::instance()->createTables());

    // 未知列与其它列都必须原封不动地还在。
    QSqlQuery info(DatabaseManager::instance()->database());
    QVERIFY(info.exec(QStringLiteral("PRAGMA table_info(tasks)")));
    QStringList columns;
    while (info.next()) {
        columns.append(info.value(1).toString());
    }
    QVERIFY(columns.contains(QStringLiteral("future_column")));
    QVERIFY(columns.contains(QStringLiteral("estimated_minutes")));
}

void ServiceTests::migrationMapsLegacyCategoryTextToCategoryIds()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy.sqlite"));
    QVERIFY(createLegacyVersion1Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery versionQuery(DatabaseManager::instance()->database());
    QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
    QVERIFY(versionQuery.next());
    QCOMPARE(versionQuery.value(0).toInt(), DatabaseManager::kCurrentSchemaVersion);

    QSqlQuery presetTask(DatabaseManager::instance()->database());
    presetTask.prepare(QStringLiteral(
        "SELECT t.category, t.category_id, c.name, c.color, c.is_preset "
        "FROM tasks t JOIN categories c ON t.category_id = c.id "
        "WHERE t.title = :title"));
    presetTask.bindValue(QStringLiteral(":title"), QStringLiteral("旧数学任务"));
    QVERIFY(presetTask.exec());
    QVERIFY(presetTask.next());
    QCOMPARE(presetTask.value(0).toString(), QStringLiteral("数学"));
    QVERIFY(presetTask.value(1).toInt() > 0);
    QCOMPARE(presetTask.value(2).toString(), QStringLiteral("数学"));
    QCOMPARE(presetTask.value(3).toString(), QStringLiteral("#d4a574"));
    QCOMPARE(presetTask.value(4).toBool(), true);

    QSqlQuery customTask(DatabaseManager::instance()->database());
    customTask.prepare(QStringLiteral(
        "SELECT t.category, t.category_id, c.name, c.is_preset "
        "FROM tasks t JOIN categories c ON t.category_id = c.id "
        "WHERE t.title = :title"));
    customTask.bindValue(QStringLiteral(":title"), QStringLiteral("旧自定义任务"));
    QVERIFY(customTask.exec());
    QVERIFY(customTask.next());
    QCOMPARE(customTask.value(0).toString(), QStringLiteral("数据结构"));
    QVERIFY(customTask.value(1).toInt() > 0);
    QCOMPARE(customTask.value(2).toString(), QStringLiteral("数据结构"));
    QCOMPARE(customTask.value(3).toBool(), false);

    QSqlQuery emptyTask(DatabaseManager::instance()->database());
    emptyTask.prepare(QStringLiteral("SELECT category, category_id FROM tasks WHERE title = :title"));
    emptyTask.bindValue(QStringLiteral(":title"), QStringLiteral("旧空科目任务"));
    QVERIFY(emptyTask.exec());
    QVERIFY(emptyTask.next());
    QCOMPARE(emptyTask.value(0).toString(), QString());
    QVERIFY(emptyTask.value(1).isNull());
}

void ServiceTests::migrationCategoryMappingHandlesWhitespaceAndCaseBoundaries()
{
    // 这里锁的不是「现在有 bug」，而是一组必须成对存在的约定：
    // migrateTaskCategories 在 SELECT DISTINCT 和 UPDATE 两处各写了一次 trim()，
    // categories.name 的 UNIQUE 与查找端的 `name = :name` 各自用二进制排序规则。
    // 任何一侧被单独改掉，用户的科目就会被静默拆开或合并，且没有任何报错。
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-boundaries.sqlite"));
    const QList<QPair<QString, QString>> boundaryRows = {
        {QStringLiteral("旧带空格任务"), QStringLiteral("  数学  ")},
        {QStringLiteral("旧纯空白科目任务"), QStringLiteral("   ")},
        {QStringLiteral("旧小写英文任务"), QStringLiteral("english")},
        {QStringLiteral("旧大写英文任务"), QStringLiteral("English")}
    };
    QVERIFY(createLegacyVersion1Database(legacyPath, boundaryRows));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    auto categoryIdOf = [](const QString& taskTitle) {
        QSqlQuery query(DatabaseManager::instance()->database());
        query.prepare(QStringLiteral("SELECT category_id FROM tasks WHERE title = :title"));
        query.bindValue(QStringLiteral(":title"), taskTitle);
        if (!query.exec() || !query.next()) {
            return QVariant();
        }
        return query.value(0);
    };

    // 前后空白必须被裁掉，和不带空白的同名任务归到同一个科目。
    const QVariant paddedId = categoryIdOf(QStringLiteral("旧带空格任务"));
    const QVariant plainId = categoryIdOf(QStringLiteral("旧数学任务"));
    QVERIFY(!paddedId.isNull());
    QCOMPARE(paddedId.toInt(), plainId.toInt());

    // 纯空白等同于「没有科目」，不能建出一个名字是空白的科目行。
    QVERIFY(categoryIdOf(QStringLiteral("旧纯空白科目任务")).isNull());
    QSqlQuery blankCategory(DatabaseManager::instance()->database());
    QVERIFY(blankCategory.exec(QStringLiteral(
        "SELECT COUNT(*) FROM categories WHERE trim(name) = ''")));
    QVERIFY(blankCategory.next());
    QCOMPARE(blankCategory.value(0).toInt(), 0);

    // 大小写不同视为两个科目——UNIQUE 与查找端都是二进制比较，两侧一致。
    // 若将来给其中一侧加上 COLLATE NOCASE 而另一侧没加，迁移会在插入时撞唯一约束
    // 而整体失败；这条断言会先把那次改动拦下来。
    const QVariant lowerId = categoryIdOf(QStringLiteral("旧小写英文任务"));
    const QVariant upperId = categoryIdOf(QStringLiteral("旧大写英文任务"));
    QVERIFY(!lowerId.isNull());
    QVERIFY(!upperId.isNull());
    QVERIFY(lowerId.toInt() != upperId.toInt());
}

void ServiceTests::migrationCreatesDatabaseBackup()
{
    DatabaseManager::instance()->close();

    // 迁移备份会写到数据库同目录。用独立子目录隔离 init() 为默认测试库生成的快照，
    // 否则按文件名取第一份会偶然验证到另一个库，与快照策略无关。
    const QString migrationDirPath = m_tempDir->filePath(QStringLiteral("wal-migration-backup"));
    QVERIFY(QDir().mkpath(migrationDirPath));
    const QString legacyPath = QDir(migrationDirPath).filePath(QStringLiteral("legacy-backup.sqlite"));
    QVERIFY(createLegacyVersion1Database(legacyPath));

    // 保持 WAL 连接打开，确保新插入行尚未被检查点回写到主库文件。
    // 这能稳定区分 SQLite 快照与错误的单文件复制。
    const QString walConnectionName = QStringLiteral("MigrationWalSetupConnection");
    bool initialized = false;
    {
        QSqlDatabase walDatabase = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),
                                                              walConnectionName);
        walDatabase.setDatabaseName(legacyPath);
        QVERIFY(walDatabase.open());

        QSqlQuery walQuery(walDatabase);
        QVERIFY(walQuery.exec(QStringLiteral("PRAGMA journal_mode = WAL")));
        QVERIFY(walQuery.next());
        QCOMPARE(walQuery.value(0).toString().toLower(), QStringLiteral("wal"));
        QVERIFY(walQuery.exec(QStringLiteral("PRAGMA wal_autocheckpoint = 0")));
        QVERIFY(walQuery.exec(QStringLiteral(
            "INSERT INTO tasks (title, category, date, completed, created_at) "
            "VALUES ('WAL 中的迁移任务', '数学', '2026-06-11', 0, '2026-06-11T08:00:00')")));
        QVERIFY(QFileInfo::exists(legacyPath + QStringLiteral("-wal")));

        initialized = DatabaseManager::instance()->initialize(legacyPath);
        walDatabase.close();
    }
    QSqlDatabase::removeDatabase(walConnectionName);
    QVERIFY(initialized);

    const QStringList backups = QDir(migrationDirPath).entryList(
        QStringList{QStringLiteral("pomodoro_backup_*.db")},
        QDir::Files);
    QCOMPARE(backups.size(), 1);

    const QString verificationConnection = QStringLiteral("MigrationBackupVerificationConnection");
    {
        QSqlDatabase backupDatabase = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),
                                                                 verificationConnection);
        backupDatabase.setDatabaseName(QDir(migrationDirPath).filePath(backups.constFirst()));
        QVERIFY(backupDatabase.open());

        QSqlQuery taskQuery(backupDatabase);
        QVERIFY(taskQuery.exec(QStringLiteral(
            "SELECT COUNT(*) FROM tasks WHERE title = 'WAL 中的迁移任务'")));
        QVERIFY(taskQuery.next());
        QCOMPARE(taskQuery.value(0).toInt(), 1);
        backupDatabase.close();
    }
    QSqlDatabase::removeDatabase(verificationConnection);
}

void ServiceTests::migrationV8BackfillsPomodoroCompletedPerRow()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-v7-pomodoro.sqlite"));
    QVERIFY(createLegacyVersion7Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT id, pomodoro_completed FROM focus_sessions ORDER BY id")));
    const QList<int> expected{1, 1, 0, 1, 0, 0, 0};
    for (int index = 0; index < expected.size(); ++index) {
        QVERIFY2(query.next(), "v8 回填后的行数少于夹具输入");
        QCOMPARE(query.value(0).toInt(), index + 1);
        // 必须逐行断言：聚合 COUNT 会漏掉一行误增、另一行误减的抵消错误。
        QCOMPARE(query.value(1).toInt(), expected.at(index));
    }
    QVERIFY2(!query.next(), "v8 回填夹具出现未断言的额外行");
}

void ServiceTests::migrationV8DoesNotInventPomodorosForFreeTimerSessions()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-v7-free-timer.sqlite"));
    QVERIFY(createLegacyVersion7Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT pomodoro_completed FROM focus_sessions WHERE id = 5 AND mode = 0")));
    QVERIFY(query.next());
    // 自由计时即使远超 3 分钟也只累计专注时长，不得伪造完整番茄。
    QCOMPARE(query.value(0).toInt(), 0);
}

void ServiceTests::migrationV9SnapshotsCategoryForSessionsWithTasks()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-v7-snapshot.sqlite"));
    QVERIFY(createLegacyVersion7Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT category_id_snapshot, category_name_snapshot, category_color_snapshot "
        "FROM focus_sessions WHERE id = 1")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 1);
    QCOMPARE(query.value(1).toString(), QStringLiteral("学习"));
    QCOMPARE(query.value(2).toString(), QStringLiteral("#d4a574"));
}

void ServiceTests::migrationV9LeavesSnapshotEmptyWhenTaskIsGone()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-v7-missing-task.sqlite"));
    QVERIFY(createLegacyVersion7Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT task_id, category_id_snapshot, category_name_snapshot, category_color_snapshot "
        "FROM focus_sessions WHERE id = 2")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 2);
    QVERIFY(query.value(1).isNull());
    QCOMPARE(query.value(2).toString(), QString());
    QCOMPARE(query.value(3).toString(), QString());
}

void ServiceTests::migrationV9PreservesSnapshotAfterCategoryDeletion()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-v7-delete-category.sqlite"));
    QVERIFY(createLegacyVersion7Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QVERIFY(CategoryManager::instance()->deleteCategory(1));
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT category_id_snapshot, category_name_snapshot, category_color_snapshot "
        "FROM focus_sessions WHERE id = 1")));
    QVERIFY(query.next());
    // 快照列故意不设外键：科目删除后，历史归属仍必须可追溯。
    QCOMPARE(query.value(0).toInt(), 1);
    QCOMPARE(query.value(1).toString(), QStringLiteral("学习"));
    QCOMPARE(query.value(2).toString(), QStringLiteral("#d4a574"));
}

void ServiceTests::migrationV8BackfillIsIndependentOfDayStartHour()
{
    AppSettings::instance()->setDayStartHour(4);
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-v7-day-boundary.sqlite"));
    QVERIFY(createLegacyVersion7Database(legacyPath, true));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT id, pomodoro_completed FROM focus_sessions WHERE id IN (8, 9) ORDER BY id")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 8);
    QCOMPARE(query.value(1).toInt(), 1);
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 9);
    QCOMPARE(query.value(1).toInt(), 1);
    // 逻辑日只影响统计归属，v8 回填是逐行事实推断，不得把 04:00 日界点混入判定。
    QVERIFY(!query.next());
}

void ServiceTests::migrationV8DoesNotRewriteExistingCompletionFacts()
{
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-v7-existing-fact.sqlite"));
    QVERIFY(createLegacyVersion7Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    QSqlQuery query(DatabaseManager::instance()->database());
    // 模拟恢复了“列已存在、但版本号偏旧”的库：0 是用户手动停止的真实事实。
    QVERIFY(query.exec(QStringLiteral(
        "UPDATE focus_sessions SET pomodoro_completed = 0 WHERE id = 1")));
    QVERIFY(query.exec(QStringLiteral("PRAGMA user_version = 7")));
    QVERIFY(DatabaseManager::instance()->createTables());

    QVERIFY(query.exec(QStringLiteral(
        "SELECT pomodoro_completed FROM focus_sessions WHERE id = 1")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 0);
}

void ServiceTests::multiStepMigrationKeepsOnlyThePreMigrationSnapshot()
{
    DatabaseManager::instance()->close();
    const QString migrationDirPath = m_tempDir->filePath(QStringLiteral("snapshot-chain"));
    QVERIFY(QDir().mkpath(migrationDirPath));
    const QString legacyPath = QDir(migrationDirPath).filePath(QStringLiteral("legacy-v1.sqlite"));
    QVERIFY(createLegacyVersion1Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    const QStringList backups = QDir(migrationDirPath).entryList(
        QStringList{QStringLiteral("pomodoro_backup_*.db")}, QDir::Files);
    QCOMPARE(backups.size(), 1);

    const QString connectionName = QStringLiteral("PreMigrationSnapshotVerificationConnection");
    {
        QSqlDatabase snapshot = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        snapshot.setDatabaseName(QDir(migrationDirPath).filePath(backups.constFirst()));
        QVERIFY(snapshot.open());
        QSqlQuery versionQuery(snapshot);
        QVERIFY(versionQuery.exec(QStringLiteral("PRAGMA user_version")));
        QVERIFY(versionQuery.next());
        // 保留的必须是整条迁移开始前的 v1，不是中间某一级的半成品。
        QCOMPARE(versionQuery.value(0).toInt(), 1);
        snapshot.close();
    }
    QSqlDatabase::removeDatabase(connectionName);
}

void ServiceTests::customCategoryCrudValidatesAndEmitsChanges()
{
    CategoryManager* manager = CategoryManager::instance();
    QSignalSpy spy(manager, &CategoryManager::categoriesChanged);

    QTest::ignoreMessage(QtWarningMsg, "Failed to add category: name is empty");
    QCOMPARE(manager->addCategory(QStringLiteral("   "), QStringLiteral("#112233")), -1);

    QTest::ignoreMessage(QtWarningMsg, "Failed to add category: invalid color \"112233\"");
    QCOMPARE(manager->addCategory(QStringLiteral("算法"), QStringLiteral("112233")), -1);

    const int id = manager->addCategory(QStringLiteral("  算法  "), QStringLiteral("#112233"));
    QVERIFY(id > 0);
    QCOMPARE(spy.count(), 1);

    QVariantMap category = manager->getCategoryById(id);
    QCOMPARE(category.value(QStringLiteral("name")).toString(), QStringLiteral("算法"));
    QCOMPARE(category.value(QStringLiteral("color")).toString(), QStringLiteral("#112233"));
    QCOMPARE(category.value(QStringLiteral("isPreset")).toBool(), false);

    QTest::ignoreMessage(QtWarningMsg, "Failed to update category: invalid color \"red\"");
    QVERIFY(!manager->updateCategory(id, QStringLiteral("算法复盘"), QStringLiteral("red")));

    QVERIFY(manager->updateCategory(id, QStringLiteral("  算法复盘  "), QStringLiteral("#445566")));
    QCOMPARE(spy.count(), 2);
    category = manager->getCategoryById(id);
    QCOMPARE(category.value(QStringLiteral("name")).toString(), QStringLiteral("算法复盘"));
    QCOMPARE(category.value(QStringLiteral("color")).toString(), QStringLiteral("#445566"));

    QVERIFY(manager->canDeleteCategory(id));
    QVERIFY(manager->deleteCategory(id));
    QCOMPARE(spy.count(), 3);
    QVERIFY(manager->getCategoryById(id).isEmpty());
}

void ServiceTests::presetCategoriesCanBeEditedButNotDeleted()
{
    CategoryManager* manager = CategoryManager::instance();
    const QVariantMap preset = manager->getPresetCategories().first().toMap();
    const int presetId = preset.value(QStringLiteral("id")).toInt();

    QVERIFY(manager->updateCategory(presetId, QStringLiteral("数学改名"), QStringLiteral("#112233")));

    const QVariantMap updated = manager->getCategoryById(presetId);
    QCOMPARE(updated.value(QStringLiteral("name")).toString(), QStringLiteral("数学改名"));
    QCOMPARE(updated.value(QStringLiteral("color")).toString(), QStringLiteral("#112233"));
    QCOMPARE(updated.value(QStringLiteral("isPreset")).toBool(), true);

    QTest::ignoreMessage(QtWarningMsg, "Failed to delete category: preset category cannot be deleted");
    QVERIFY(!manager->deleteCategory(presetId));
    QVERIFY(!manager->canDeleteCategory(presetId));

    // 重启会再次执行默认科目播种；编辑过的预设行必须按稳定顺序识别，不能按旧名称复制一份。
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath(QStringLiteral("test.sqlite"))));
    QCOMPARE(manager->getPresetCategories().size(), 5);
    const QVariantMap persisted = manager->getCategoryById(presetId);
    QCOMPARE(persisted.value(QStringLiteral("name")).toString(), QStringLiteral("数学改名"));
    QCOMPARE(persisted.value(QStringLiteral("color")).toString(), QStringLiteral("#112233"));
}

void ServiceTests::deletingAssociatedCategoryDetachesTasks()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("408"), QStringLiteral("#abcdef"));
    QVERIFY(categoryId > 0);

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("计组错题"), QVariant(logicalToday()), categoryId));

    // 删除科目不应该删除任务，只应该把任务变成未分类。
    QVERIFY(manager->canDeleteCategory(categoryId));
    QVERIFY(manager->deleteCategory(categoryId));
    QVERIFY(manager->getCategoryById(categoryId).isEmpty());

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("计组错题"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), 0);
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QString());
    QVERIFY(task.value(QStringLiteral("category")).toMap().isEmpty());
}

void ServiceTests::deletingLegacyTextCategoryClearsTaskCategoryText()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("网络原理"), QStringLiteral("#778899"));
    QVERIFY(categoryId > 0);
    QVERIFY(insertTaskRowWithCategoryId(
                QStringLiteral("旧文本任务"),
                logicalToday(),
                -1,
                QStringLiteral("网络原理"),
                false,
                dateTimeText(logicalToday())) > 0);

    // 旧数据只有文本科目，也必须跟新 category_id 逻辑保持同样结果。
    QVERIFY(manager->canDeleteCategory(categoryId));
    QVERIFY(manager->deleteCategory(categoryId));
    QVERIFY(manager->getCategoryById(categoryId).isEmpty());

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("旧文本任务"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), 0);
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QString());
    QVERIFY(task.value(QStringLiteral("category")).toMap().isEmpty());
}

void ServiceTests::taskManagerReturnsFullCategoryInfo()
{
    CategoryManager* manager = CategoryManager::instance();
    const int categoryId = manager->addCategory(QStringLiteral("数据结构"), QStringLiteral("#123abc"));
    QVERIFY(categoryId > 0);

    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("图论专题"), QVariant(logicalToday()), categoryId));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);

    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(task.value(QStringLiteral("categoryName")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(task.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#123abc"));

    const QVariantMap category = task.value(QStringLiteral("category")).toMap();
    QCOMPARE(category.value(QStringLiteral("id")).toInt(), categoryId);
    QCOMPARE(category.value(QStringLiteral("name")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(category.value(QStringLiteral("color")).toString(), QStringLiteral("#123abc"));

    const QVariantMap nestedCategory = task.value(QStringLiteral("categoryData")).toMap();
    QCOMPARE(nestedCategory.value(QStringLiteral("id")).toInt(), categoryId);
    QCOMPARE(nestedCategory.value(QStringLiteral("name")).toString(), QStringLiteral("数据结构"));
    QCOMPARE(nestedCategory.value(QStringLiteral("color")).toString(), QStringLiteral("#123abc"));
}

void ServiceTests::taskCreatedAtTreatsSqliteTimestampAsUtc()
{
    const QString storedUtc = QStringLiteral("2026-06-09 16:30:00");
    const int taskId = insertTaskRow(QStringLiteral("UTC 创建时间任务"), logicalToday(),
                                     QString(), false, storedUtc);
    QVERIFY(taskId > 0);

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QDateTime expected(QDate(2026, 6, 9), QTime(16, 30), QTimeZone::UTC);
    expected = expected.toLocalTime();
    QCOMPARE(task.value(QStringLiteral("createdAt")).toDateTime(), expected);

    const QString exportPath = m_tempDir->filePath(QStringLiteral("utc-created-at.csv"));
    QVERIFY(ExportService::instance()->exportTasks(logicalToday(), logicalToday(), exportPath));
    QVERIFY(readUtf8File(exportPath).contains(expected.toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"))));
}

void ServiceTests::taskManagerTodayUsesLogicalToday()
{
    AppSettings::instance()->setDayStartHour(4);
    TaskManager* manager = TaskManager::instance();

    QVERIFY(manager->addTask(QStringLiteral("逻辑今日任务"), QVariant(logicalToday()), QString()));
    QVERIFY(manager->addTask(QStringLiteral("逻辑昨日任务"),
                             QVariant(logicalToday().addDays(-1)), QString()));

    QCOMPARE(manager->getTodayTasks(), manager->getTasksByDate(logicalToday()));
    QCOMPARE(manager->getTodayTasks().size(), 1);

    const QVariantList overdue = manager->getOverdueUncompletedTasks();
    QCOMPARE(overdue.size(), 1);
    QCOMPARE(overdue.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("逻辑昨日任务"));

    QVERIFY(manager->moveTasksToToday(
        QVariantList{overdue.first().toMap().value(QStringLiteral("id"))}));
    QCOMPARE(manager->getTasksByDate(logicalToday()).size(), 2);
    QVERIFY(manager->getOverdueUncompletedTasks().isEmpty());
}

void ServiceTests::legacyAddTaskWithTextCategoryRemainsCompatible()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("政治选择题"), QVariant(logicalToday()), QStringLiteral("政治")));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QCOMPARE(tasks.size(), 1);

    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QStringLiteral("政治"));
    QVERIFY(task.value(QStringLiteral("categoryId")).toInt() > 0);
    QCOMPARE(task.value(QStringLiteral("categoryName")).toString(), QStringLiteral("政治"));
    QCOMPARE(task.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#be8568"));

    const QVariantMap nestedCategory = task.value(QStringLiteral("categoryData")).toMap();
    QCOMPARE(nestedCategory.value(QStringLiteral("name")).toString(), QStringLiteral("政治"));
}

void ServiceTests::updateTaskChangesTitleCategoryAndDate()
{
    TaskManager* manager = TaskManager::instance();
    const QDate today = QDate::currentDate();
    const int taskId = insertTaskRow(QStringLiteral("原标题"), today);
    QVERIFY(taskId > 0);

    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("数学编辑"), QStringLiteral("#d4a574"));
    QVERIFY(categoryId > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    const QDate tomorrow = today.addDays(1);
    QVERIFY(manager->updateTask(taskId,
                                QStringLiteral("  新标题  "),
                                categoryId,
                                tomorrow.toString(Qt::ISODate)));
    QCOMPARE(changedSpy.count(), 1);

    const QVariantList todayTasks = manager->getTasksByDate(today);
    QVERIFY(todayTasks.isEmpty());

    const QVariantList tasks = manager->getTasksByDate(tomorrow);
    QCOMPARE(tasks.size(), 1);
    const QVariantMap task = tasks.first().toMap();
    QCOMPARE(task.value(QStringLiteral("title")).toString(), QStringLiteral("新标题"));
    QCOMPARE(task.value(QStringLiteral("categoryId")).toInt(), categoryId);
    QCOMPARE(task.value(QStringLiteral("categoryText")).toString(), QStringLiteral("数学编辑"));
}

void ServiceTests::updateTaskRejectsBlankTitleAndInvalidId()
{
    TaskManager* manager = TaskManager::instance();
    const int taskId = insertTaskRow(QStringLiteral("保持不变"), logicalToday());
    QVERIFY(taskId > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    QTest::ignoreMessage(QtWarningMsg, "Failed to update task: title is empty after trimming");
    QVERIFY(!manager->updateTask(taskId,
                                 QStringLiteral("   "),
                                 -1,
                                 logicalToday().toString(Qt::ISODate)));
    QTest::ignoreMessage(QtWarningMsg, "Failed to update task: invalid task id -5");
    QVERIFY(!manager->updateTask(-5,
                                 QStringLiteral("有效标题"),
                                 -1,
                                 logicalToday().toString(Qt::ISODate)));
    QTest::ignoreMessage(QtWarningMsg, "Failed to update task: task not found 999999");
    QVERIFY(!manager->updateTask(999999,
                                 QStringLiteral("有效标题"),
                                 -1,
                                 logicalToday().toString(Qt::ISODate)));
    QCOMPARE(changedSpy.count(), 0);

    const QVariantList tasks = manager->getTodayTasks();
    QCOMPARE(tasks.size(), 1);
    QCOMPARE(tasks.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("保持不变"));
}

void ServiceTests::overdueQueryExcludesTodayCompletedAndTrustedRoutine()
{
    TaskManager* manager = TaskManager::instance();
    const QDate today = logicalToday();
    const QDate yesterday = today.addDays(-1);
    const QDate lastWeek = today.addDays(-6);

    const int oldPending = insertTaskRow(QStringLiteral("上周残留"), lastWeek);
    const int yesterdayPending = insertTaskRow(QStringLiteral("昨天残留"), yesterday);
    QVERIFY(oldPending > 0);
    QVERIFY(yesterdayPending > 0);
    QVERIFY(insertTaskRow(QStringLiteral("昨天已完成"), yesterday, QString(), true) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("今天的任务"), today) > 0);

    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("结转排除例行"), -1));
    const int ambiguousSameTitle = insertTaskRow(QStringLiteral("结转排除例行"), yesterday);
    const int trustedRoutine = insertTaskRow(QStringLiteral("可信例行"), yesterday);
    QVERIFY(ambiguousSameTitle > 0);
    QVERIFY(trustedRoutine > 0);

    QSqlQuery mark(DatabaseManager::instance()->database());
    QVERIFY2(mark.exec(QStringLiteral(
                  "UPDATE tasks SET routine_id = (SELECT id FROM routines WHERE title = '结转排除例行') "
                  "WHERE id = %1").arg(ambiguousSameTitle)),
             qPrintable(mark.lastError().text()));
    QVERIFY2(mark.exec(QStringLiteral(
                  "UPDATE tasks SET routine_id = (SELECT id FROM routines WHERE title = '结转排除例行'), "
                  "routine_generated = 1 WHERE id = %1").arg(trustedRoutine)),
             qPrintable(mark.lastError().text()));

    const QVariantList overdue = manager->getOverdueUncompletedTasks();
    QCOMPARE(overdue.size(), 3);
    QCOMPARE(overdue.at(0).toMap().value(QStringLiteral("id")).toInt(), oldPending);
    QCOMPARE(overdue.at(1).toMap().value(QStringLiteral("id")).toInt(), yesterdayPending);
    QCOMPARE(overdue.at(2).toMap().value(QStringLiteral("id")).toInt(), ambiguousSameTitle);
}

// 结转只回看最近 kOverdueRolloverDays 天：用户实测攒到 41 条，39 条是一个多月前每天一条的背词任务。
// 窗口两端都要钉住：今天往前第 7 天仍算，第 8 天起放弃追踪；更早的任务本身不动，只是不再被提示。
void ServiceTests::overdueQueryOnlyLooksBackTheRolloverWindow()
{
    TaskManager* manager = TaskManager::instance();
    const QDate today = logicalToday();
    QCOMPARE(TaskManager::kOverdueRolloverDays, 7);
    // QML 的提示条文案读的是这个常量属性，必须与服务端口径是同一个数。
    QCOMPARE(manager->property("overdueRolloverDays").toInt(), TaskManager::kOverdueRolloverDays);

    const int yesterday = insertTaskRow(QStringLiteral("昨天没做完"), today.addDays(-1));
    const int edge = insertTaskRow(QStringLiteral("整一周前"),
                                   today.addDays(-TaskManager::kOverdueRolloverDays));
    const int justOutside = insertTaskRow(QStringLiteral("八天前"),
                                          today.addDays(-TaskManager::kOverdueRolloverDays - 1));
    const int monthAgo = insertTaskRow(QStringLiteral("一个多月前"), today.addDays(-40));
    QVERIFY(yesterday > 0);
    QVERIFY(edge > 0);
    QVERIFY(justOutside > 0);
    QVERIFY(monthAgo > 0);

    const QVariantList overdue = manager->getOverdueUncompletedTasks();
    QCOMPARE(overdue.size(), 2);
    // 按日期升序：窗口最早那天在前。
    QCOMPARE(overdue.at(0).toMap().value(QStringLiteral("id")).toInt(), edge);
    QCOMPARE(overdue.at(1).toMap().value(QStringLiteral("id")).toInt(), yesterday);

    // 放弃追踪不是删除：窗口外的任务原样留在原来的日期上，未完成状态也不变。
    const QVariantList oldDay = manager->getTasksByDate(today.addDays(-40));
    QCOMPARE(oldDay.size(), 1);
    QCOMPARE(oldDay.first().toMap().value(QStringLiteral("id")).toInt(), monthAgo);
    QCOMPARE(oldDay.first().toMap().value(QStringLiteral("completed")).toBool(), false);
    QCOMPARE(manager->getTasksByDate(today.addDays(-TaskManager::kOverdueRolloverDays - 1)).size(), 1);
}

void ServiceTests::moveTasksToTodayIsTransactional()
{
    TaskManager* manager = TaskManager::instance();
    const QDate yesterday = logicalToday().addDays(-1);
    const int first = insertTaskRow(QStringLiteral("结转一"), yesterday);
    const int second = insertTaskRow(QStringLiteral("结转二"), yesterday);
    QVERIFY(first > 0);
    QVERIFY(second > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    QVERIFY(!manager->moveTasksToToday(QVariantList{first, 999999}));
    QCOMPARE(changedSpy.count(), 0);
    QCOMPARE(manager->getTasksByDate(yesterday).size(), 2);

    QVERIFY(manager->moveTasksToToday(QVariantList{first, second}));
    QCOMPARE(changedSpy.count(), 1);
    QCOMPARE(manager->getTasksByDate(yesterday).size(), 0);
    QCOMPARE(manager->getTodayTasks().size(), 2);
    QCOMPARE(manager->getOverdueUncompletedTasks().size(), 0);

    QVERIFY(manager->moveTasksToToday(QVariantList{}));
}

void ServiceTests::batchRescheduleSearchAndCopy()
{
    auto* manager = TaskManager::instance();
    const QDate source(2026, 6, 1);
    const QDate target(2026, 12, 25);
    QVERIFY(manager->addTask(QStringLiteral("复制原件"), source, -1, 45, QStringLiteral("第 20 页 50%")));
    const int first = manager->getTasksByDate(source).first().toMap().value(QStringLiteral("id")).toInt();
    const int second = insertTaskRow(QStringLiteral("普通任务"), source);
    QVERIFY(manager->setTaskCompleted(first, true));
    QVERIFY(insertFocusSessionRow(first, source, 300));
    QVERIFY(!manager->moveTasksToDate({first, 999999}, target));
    QCOMPARE(manager->getTasksByDate(source).size(), 2);
    QVERIFY(!manager->moveTasksToDate({first, first}, target));
    QCOMPARE(manager->getTasksByDate(target).size(), 0);
    QVERIFY(manager->moveTasksToDate({second, first}, target));
    const QVariantMap before = manager->getTask(first);
    QVERIFY(manager->moveTasksToDate({first}, target));
    QCOMPARE(manager->getTask(first).value(QStringLiteral("displayOrder")), before.value(QStringLiteral("displayOrder")));
    QCOMPARE(manager->searchTasks(QStringLiteral("50%"), -1, 200).size(), 1);
    QCOMPARE(manager->searchTasks(QStringLiteral("50_"), -1, 200).size(), 0);
    QCOMPARE(manager->searchTasks(QStringLiteral("第 20 页"), 0, 200).size(), 0);
    QVERIFY(manager->duplicateTask(first, source));
    const QVariantMap copy = manager->getTasksByDate(source).first().toMap();
    QVERIFY(!copy.value(QStringLiteral("completed")).toBool());
    QCOMPARE(copy.value(QStringLiteral("estimatedMinutes")).toInt(), 45);
    QCOMPARE(copy.value(QStringLiteral("notes")).toString(), QStringLiteral("第 20 页 50%"));
    QCOMPARE(copy.value(QStringLiteral("focusedMinutes")).toInt(), 0);
    QVERIFY(copy.value(QStringLiteral("id")).toInt() != first);
}

void ServiceTests::exportFocusSessionsUsesLogicalDayRange()
{
    AppSettings::instance()->setDayStartHour(4);
    const QDate day(2026, 7, 8);
    const int taskId = insertTaskRow(QStringLiteral("导出边界"), day, QStringLiteral("政治"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("01:00:00"),
                                    QStringLiteral("01:30:00"), 1800));

    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    const QString hitPath = dir.filePath(QStringLiteral("hit.csv"));
    QVERIFY(ExportService::instance()->exportFocusSessions(day.addDays(-1),
                                                           day.addDays(-1),
                                                           hitPath));
    QFile hitFile(hitPath);
    QVERIFY(hitFile.open(QIODevice::ReadOnly | QIODevice::Text));
    QVERIFY(QString::fromUtf8(hitFile.readAll()).contains(QStringLiteral("导出边界")));

    const QString missPath = dir.filePath(QStringLiteral("miss.csv"));
    QVERIFY(ExportService::instance()->exportFocusSessions(day, day, missPath));
    QFile missFile(missPath);
    QVERIFY(missFile.open(QIODevice::ReadOnly | QIODevice::Text));
    QVERIFY(!QString::fromUtf8(missFile.readAll()).contains(QStringLiteral("导出边界")));
}

void ServiceTests::exportTasksWritesUtf8CsvWithEscapingAndCategoryFallbacks()
{
    const QDate startDate(2026, 6, 10);
    const QDate endDate(2026, 6, 11);
    const int mathCategoryId = CategoryManager::instance()->addCategory(QStringLiteral("离散数学"), QStringLiteral("#123abc"));
    QVERIFY(mathCategoryId > 0);

    const int joinedTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("复习,总结,归纳"),
        startDate,
        mathCategoryId,
        QStringLiteral("旧科目不应导出"),
        true,
        QStringLiteral("2026-06-09T08:30:00"));
    const int legacyTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("学习\"关键点\""),
        endDate,
        -1,
        QStringLiteral("英语"),
        false,
        QStringLiteral("2026-06-09T09:00:00"));
    const int uncategorizedTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("换行\n标题"),
        endDate,
        -1,
        QString(),
        false,
        QStringLiteral("2026-06-09T10:00:00"));
    QVERIFY(joinedTaskId > 0);
    QVERIFY(legacyTaskId > 0);
    QVERIFY(uncategorizedTaskId > 0);

    QSignalSpy completedSpy(ExportService::instance(), &ExportService::exportCompleted);
    QSignalSpy progressSpy(ExportService::instance(), &ExportService::exportProgress);
    const QString filePath = m_tempDir->filePath(QStringLiteral("tasks.csv"));

    QVERIFY(ExportService::instance()->exportTasks(startDate, endDate, filePath));

    QCOMPARE(completedSpy.count(), 1);
    QCOMPARE(completedSpy.takeFirst().at(0).toBool(), true);
    // 进度按批发送（每 200 行一次 + 末尾补一次准确值），不再逐行发：
    // 2 万行逐行发就是 2 万次跨线程排队投递，比写文件本身还贵。
    // 这里守的是"最终一定报到终点"，而不是发了几次。
    QVERIFY(progressSpy.count() >= 1);
    QCOMPARE(progressSpy.last().at(0).toInt(), 3);
    QCOMPARE(progressSpy.last().at(1).toInt(), 3);
    QCOMPARE(readUtf8File(filePath),
             QStringLiteral("ID,标题,科目,日期,完成状态,创建时间\n"
                            "%1,\"复习,总结,归纳\",离散数学,2026-06-10,已完成,2026-06-09 08:30:00\n"
                            "%2,\"学习\"\"关键点\"\"\",英语,2026-06-11,未完成,2026-06-09 09:00:00\n"
                            "%3,\"换行\n标题\",未分类,2026-06-11,未完成,2026-06-09 10:00:00\n")
                 .arg(joinedTaskId)
                 .arg(legacyTaskId)
                 .arg(uncategorizedTaskId));
}

void ServiceTests::exportFocusSessionsAndExportAllWriteExpectedCsvFiles()
{
    const QDate startDate(2026, 6, 10);
    const QDate endDate(2026, 6, 10);
    const int politicsCategoryId = CategoryManager::instance()->addCategory(QStringLiteral("政治理论"), QStringLiteral("#445566"));
    QVERIFY(politicsCategoryId > 0);
    const int taskId = insertTaskRowWithCategoryId(
        QStringLiteral("真题\"精讲\",第一套"),
        startDate,
        politicsCategoryId,
        QString(),
        false,
        QStringLiteral("2026-06-10T08:00:00"));
    const int emptyCategoryTaskId = insertTaskRowWithCategoryId(
        QStringLiteral("无科目任务"),
        startDate,
        -1,
        QString(),
        false,
        QStringLiteral("2026-06-10T08:10:00"));
    QVERIFY(taskId > 0);
    QVERIFY(emptyCategoryTaskId > 0);

    const int linkedSessionId = insertFocusSessionRowWithTimes(
        taskId,
        QStringLiteral("2026-06-10T09:00:00"),
        QStringLiteral("2026-06-10T10:30:00"),
        5400);
    const int uncategorizedSessionId = insertFocusSessionRowWithTimes(
        emptyCategoryTaskId,
        QStringLiteral("2026-06-10T11:00:00"),
        QStringLiteral("2026-06-10T11:30:00"),
        1800);
    const int unlinkedSessionId = insertFocusSessionRowWithTimes(
        -1,
        QStringLiteral("2026-06-10T12:00:00"),
        QStringLiteral("2026-06-10T12:20:00"),
        1200);
    QVERIFY(linkedSessionId > 0);
    QVERIFY(uncategorizedSessionId > 0);
    QVERIFY(unlinkedSessionId > 0);

    const QString sessionsPath = m_tempDir->filePath(QStringLiteral("sessions.csv"));
    QSignalSpy sessionProgressSpy(ExportService::instance(), &ExportService::exportProgress);
    QVERIFY(ExportService::instance()->exportFocusSessions(startDate, endDate, sessionsPath));
    QVERIFY(sessionProgressSpy.count() >= 1);
    QCOMPARE(sessionProgressSpy.last().at(0).toInt(), 3);
    QCOMPARE(sessionProgressSpy.last().at(1).toInt(), 3);
    QCOMPARE(readUtf8File(sessionsPath),
             QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n"
                            "%1,%2,\"真题\"\"精讲\"\",第一套\",政治理论,2026-06-10 09:00:00,2026-06-10 10:30:00,90\n"
                            "%3,%4,无科目任务,未分类,2026-06-10 11:00:00,2026-06-10 11:30:00,30\n"
                            "%5,-1,未关联任务,未分类,2026-06-10 12:00:00,2026-06-10 12:20:00,20\n")
                 .arg(linkedSessionId)
                 .arg(taskId)
                 .arg(uncategorizedSessionId)
                 .arg(emptyCategoryTaskId)
                 .arg(unlinkedSessionId));

    QSignalSpy allCompletedSpy(ExportService::instance(), &ExportService::exportCompleted);
    QVERIFY(ExportService::instance()->exportAll(startDate, endDate, m_tempDir->path()));
    QCOMPARE(allCompletedSpy.count(), 1);
    QCOMPARE(allCompletedSpy.takeFirst().at(0).toBool(), true);
    const QString tasksFileName = ExportService::instance()->generateFileName(QStringLiteral("tasks"), startDate, endDate);
    const QString sessionsFileName = ExportService::instance()->generateFileName(QStringLiteral("focus_sessions"), startDate, endDate);
    QCOMPARE(tasksFileName, QStringLiteral("tasks_20260610_20260610.csv"));
    QCOMPARE(sessionsFileName, QStringLiteral("focus_sessions_20260610_20260610.csv"));
    QVERIFY(QFile::exists(m_tempDir->filePath(tasksFileName)));
    QVERIFY(QFile::exists(m_tempDir->filePath(sessionsFileName)));
    QVERIFY(readUtf8File(m_tempDir->filePath(tasksFileName)).startsWith(QStringLiteral("ID,标题,科目,日期,完成状态,创建时间\n")));
    QVERIFY(readUtf8File(m_tempDir->filePath(sessionsFileName)).startsWith(QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n")));
}

void ServiceTests::exportAllUsesOneDatabaseSnapshot()
{
    const QDate day(2026, 6, 10);
    const QString databasePath = m_tempDir->filePath(QStringLiteral("test.sqlite"));
    ExportService* service = ExportService::instance();

    // WAL 只在这份临时测试库上开启：读事务持续时，第二连接仍能确定性提交。
    // 生产库仍保持 rollback journal，不在这个修复里改变备份架构。
    {
        QSqlQuery journalMode(DatabaseManager::instance()->database());
        QVERIFY2(journalMode.exec(QStringLiteral("PRAGMA journal_mode = WAL")),
                 qPrintable(journalMode.lastError().text()));
        QVERIFY(journalMode.next());
        QCOMPARE(journalMode.value(0).toString().toLower(), QStringLiteral("wal"));
        journalMode.finish();
    }

    const int taskId = insertTaskRow(QStringLiteral("快照内任务"), day, QStringLiteral("数学"));
    QVERIFY(taskId > 0);
    const int initialSessionId = insertFocusSessionRowWithTimes(
        taskId,
        QStringLiteral("2026-06-10T09:00:00"),
        QStringLiteral("2026-06-10T09:25:00"),
        25 * 60);
    QVERIFY(initialSessionId > 0);

    const QString writerConnectionName = QStringLiteral("ExportSnapshotWriterForTest");
    bool hookCommitted = false;
    int laterSessionId = -1;
    QString hookError;
    service->m_betweenExportFilesHookForTest = [&, databasePath]() {
        {
            QSqlDatabase writer = QSqlDatabase::addDatabase(
                QStringLiteral("QSQLITE"), writerConnectionName);
            writer.setDatabaseName(databasePath);
            if (!writer.open()) {
                hookError = writer.lastError().text();
            } else if (!writer.transaction()) {
                hookError = writer.lastError().text();
            } else {
                bool insertSucceeded = false;
                {
                    QSqlQuery insert(writer);
                    insert.prepare(QStringLiteral(
                        "INSERT INTO focus_sessions "
                        "(task_id, start_time, end_time, duration, pomodoro_completed) "
                        "VALUES (:taskId, :startTime, :endTime, :duration, 1)"));
                    insert.bindValue(QStringLiteral(":taskId"), taskId);
                    insert.bindValue(QStringLiteral(":startTime"),
                                     QStringLiteral("2026-06-10T15:00:00"));
                    insert.bindValue(QStringLiteral(":endTime"),
                                     QStringLiteral("2026-06-10T15:45:00"));
                    insert.bindValue(QStringLiteral(":duration"), 45 * 60);
                    insertSucceeded = insert.exec();
                    if (insertSucceeded) {
                        laterSessionId = insert.lastInsertId().toInt();
                    } else {
                        hookError = insert.lastError().text();
                    }
                    insert.finish();
                }

                if (insertSucceeded) {
                    hookCommitted = writer.commit();
                    if (!hookCommitted) {
                        hookError = writer.lastError().text();
                        writer.rollback();
                    }
                } else {
                    writer.rollback();
                }
            }
            writer.close();
        }
        // writer 和查询句柄都已离开作用域，此时才能安全移除命名连接。
        QSqlDatabase::removeDatabase(writerConnectionName);
    };

    QVERIFY(service->exportAll(day, day, m_tempDir->path()));
    QVERIFY2(hookCommitted, qPrintable(hookError));
    QVERIFY(laterSessionId > 0);
    QVERIFY(!service->m_betweenExportFilesHookForTest);

    QSqlQuery count(DatabaseManager::instance()->database());
    QVERIFY(count.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")));
    QVERIFY(count.next());
    QCOMPARE(count.value(0).toInt(), 2);
    count.finish();

    const QString tasksName = service->generateFileName(QStringLiteral("tasks"), day, day);
    const QString sessionsName = service->generateFileName(
        QStringLiteral("focus_sessions"), day, day);
    const QString tasksCsv = readUtf8File(m_tempDir->filePath(tasksName));
    const QString sessionsCsv = readUtf8File(m_tempDir->filePath(sessionsName));
    QVERIFY(tasksCsv.contains(QStringLiteral("快照内任务")));
    QVERIFY(sessionsCsv.contains(QStringLiteral("2026-06-10 09:00:00")));
    QVERIFY(!sessionsCsv.contains(QStringLiteral("2026-06-10 15:00:00")));
}

void ServiceTests::exportFocusSessionsIgnoresInvalidShortSessions()
{
    const QDate targetDate(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("导出有效记录"), targetDate, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(insertFocusSessionRowWithTimes(
                taskId,
                QStringLiteral("2026-06-10T08:00:00"),
                QStringLiteral("2026-06-10T08:02:59"),
                kTestMinimumValidDurationSeconds - 1) > 0);
    const int validSessionId = insertFocusSessionRowWithTimes(
        taskId,
        QStringLiteral("2026-06-10T08:10:00"),
        QStringLiteral("2026-06-10T08:13:00"),
        kTestMinimumValidDurationSeconds);
    QVERIFY(validSessionId > 0);

    const QString sessionsPath = m_tempDir->filePath(QStringLiteral("valid-sessions.csv"));
    QSignalSpy progressSpy(ExportService::instance(), &ExportService::exportProgress);

    QVERIFY(ExportService::instance()->exportFocusSessions(targetDate, targetDate, sessionsPath));

    QCOMPARE(progressSpy.count(), 1);
    QCOMPARE(progressSpy.last().at(0).toInt(), 1);
    QCOMPARE(progressSpy.last().at(1).toInt(), 1);
    QCOMPARE(readUtf8File(sessionsPath),
             QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n"
                            "%1,%2,导出有效记录,数学,2026-06-10 08:10:00,2026-06-10 08:13:00,3\n")
                 .arg(validSessionId)
                 .arg(taskId));
}

void ServiceTests::exportRejectsInvalidDateRangeAndUnwritablePath()
{
    QSignalSpy invalidDateSpy(ExportService::instance(), &ExportService::exportCompleted);
    const QString invalidDatePath = m_tempDir->filePath(QStringLiteral("invalid-date.csv"));

    QVERIFY(!ExportService::instance()->exportTasks(QDate(2026, 6, 11), QDate(2026, 6, 10), invalidDatePath));

    QCOMPARE(invalidDateSpy.count(), 1);
    QCOMPARE(invalidDateSpy.takeFirst().at(0).toBool(), false);
    QVERIFY(!QFile::exists(invalidDatePath));

    QSignalSpy unwritablePathSpy(ExportService::instance(), &ExportService::exportCompleted);
    const QString unwritablePath = m_tempDir->filePath(QStringLiteral("missing-dir/tasks.csv"));

    QVERIFY(!ExportService::instance()->exportTasks(QDate(2026, 6, 10), QDate(2026, 6, 10), unwritablePath));

    QCOMPARE(unwritablePathSpy.count(), 1);
    QCOMPARE(unwritablePathSpy.takeFirst().at(0).toBool(), false);
    QVERIFY(!QFile::exists(unwritablePath));
}

void ServiceTests::exportFailurePreservesExistingFile()
{
    const QString filePath = m_tempDir->filePath(QStringLiteral("existing.csv"));
    QFile original(filePath);
    QVERIFY(original.open(QIODevice::WriteOnly | QIODevice::Text));
    QCOMPARE(original.write("existing-content\n"), qint64(17));
    original.close();

    DatabaseManager::instance()->close();
    QVERIFY(!ExportService::instance()->exportTasks(
        QDate(2026, 6, 10), QDate(2026, 6, 10), filePath));

    QCOMPARE(readUtf8File(filePath), QStringLiteral("existing-content\n"));
}

void ServiceTests::exportAllRejectsInvalidDestinationBeforeReplacingFiles()
{
    const QDate day(2026, 6, 10);
    const QString tasksName = ExportService::instance()->generateFileName(
        QStringLiteral("tasks"), day, day);
    const QString sessionsName = ExportService::instance()->generateFileName(
        QStringLiteral("focus_sessions"), day, day);
    const QString tasksPath = m_tempDir->filePath(tasksName);
    const QString sessionsPath = m_tempDir->filePath(sessionsName);

    QFile original(tasksPath);
    QVERIFY(original.open(QIODevice::WriteOnly | QIODevice::Text));
    QCOMPARE(original.write("old-tasks\n"), qint64(10));
    original.close();
    QVERIFY(QDir().mkpath(sessionsPath));

    QVERIFY(!ExportService::instance()->exportAll(day, day, m_tempDir->path()));
    QCOMPARE(readUtf8File(tasksPath), QStringLiteral("old-tasks\n"));
    QVERIFY(QFileInfo(sessionsPath).isDir());
}

void ServiceTests::freeFocusCountsTowardDurationEstimate()
{
    // v10 之前：预估是「番茄个数」，自由计时不产生完整番茄，所以再久也不完成任务。
    // v10 之后：预估是「预计用时」，自由专注的时间同样是用时——满了就该完成，
    // 否则「预计用时 5 分钟」的标签是骗人的。这条用例锁的就是这次语义变更。
    const int taskId = insertPlannedTask(QStringLiteral("自由计时任务"), logicalToday(), -1, 5);
    QVERIFY(taskId > 0);

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("自由计时任务")));
    setFocusElapsedSeconds(FocusTimer::instance(), 300);

    bool timerWasActiveDuringTaskRefresh = true;
    const QMetaObject::Connection refreshConnection = connect(
        TaskManager::instance(), &TaskManager::tasksChanged, this, [&timerWasActiveDuringTaskRefresh]() {
            FocusTimer* timer = FocusTimer::instance();
            timerWasActiveDuringTaskRefresh = timer->hasActiveSession() || timer->phase() != FocusTimer::NoPhase;
        });
    QSignalSpy tasksChangedSpy(TaskManager::instance(), &TaskManager::tasksChanged);
    QVERIFY(FocusTimer::instance()->stopFocus());
    disconnect(refreshConnection);

    const QVariantMap task = taskMapById(TaskManager::instance()->getTodayTasks(), taskId);
    QCOMPARE(task.value(QStringLiteral("completed")).toBool(), true);
    // 自由计时仍然不产生「完整番茄」，那是另一套口径，不因这次变更而改变。
    QCOMPARE(task.value(QStringLiteral("actualPomodoros")).toInt(), 0);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 5);
    QVERIFY(tasksChangedSpy.count() >= 1);
    // 刷新时计时器必须已经收尾，否则页面会把最后一段时长重复计入。
    QCOMPARE(timerWasActiveDuringTaskRefresh, false);
}

void ServiceTests::discardFreeFocusRemovesLongSessionWithoutRecording()
{
    const int taskId = insertPlannedTask(QStringLiteral("忘记关闭的自由计时"), logicalToday(), -1, 1);
    QVERIFY(taskId > 0);

    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("忘记关闭的自由计时")));
    setFocusElapsedSeconds(timer, 8 * 60 * 60);
    QVERIFY(!timer->requiresFreeFocusStopConfirmation(8));
    setFocusElapsedSeconds(timer, 8 * 60 * 60 + 1);
    QVERIFY(timer->requiresFreeFocusStopConfirmation(8));
    setFocusElapsedSeconds(timer, 9 * 60 * 60);

    QSignalSpy focusCompletedSpy(timer, &FocusTimer::focusCompleted);
    QVERIFY(timer->discardFreeFocus());

    QCOMPARE(countFocusSessions(), 0);
    QCOMPARE(timer->hasActiveSession(), false);
    QCOMPARE(timer->isRunning(), false);
    QCOMPARE(focusCompletedSpy.count(), 0);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 0);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 0);
}

void ServiceTests::correctedFreeFocusDurationUsesUserConfirmedValue()
{
    const int taskId = insertTaskRow(QStringLiteral("需要修正的超长自由计时"), QDate::currentDate());
    QVERIFY(taskId > 0);
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("需要修正的超长自由计时")));
    setFocusElapsedSeconds(timer, 9 * 60 * 60);

    // 界面输入损坏或绕开前端校验时，服务层仍不能把无效短时长写成专注记录。
    QVERIFY(!timer->stopFreeFocusWithDuration(
        FocusSessionRules::kMinimumValidDurationSeconds - 1));
    QVERIFY(timer->hasActiveSession());

    QSignalSpy completedSpy(timer, &FocusTimer::focusCompleted);
    const int correctedSeconds = 2 * 60 * 60 + 15 * 60;
    QVERIFY(timer->stopFreeFocusWithDuration(correctedSeconds));
    QCOMPARE(completedSpy.count(), 1);
    QCOMPARE(completedSpy.first().at(0).toInt(), correctedSeconds);
    QCOMPARE(timer->hasActiveSession(), false);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT duration FROM focus_sessions WHERE end_time IS NOT NULL")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), correctedSeconds);
    QVERIFY(!query.next());
}

void ServiceTests::correctedFreeFocusDurationShrinksRecordedSpanAndFreesWindow()
{
    const int taskId = insertTaskRow(QStringLiteral("忘记停的自由计时"), QDate::currentDate());
    QVERIFY(taskId > 0);
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("忘记停的自由计时")));

    // 复现真实场景：会话确实从 9 小时前开始，用户忘了停。把库里的 start_time 往前挪，
    // 让墙钟跨度和单调计时都是 9 小时——只调 elapsed 的话两个时刻几乎重合，
    // 区间是否被修正就完全观察不到。
    const QDateTime realStart = QDateTime::currentDateTime().addSecs(-9 * 60 * 60);
    QSqlQuery backdate(DatabaseManager::instance()->database());
    backdate.prepare(QStringLiteral(
        "UPDATE focus_sessions SET start_time = :startTime WHERE end_time IS NULL"));
    backdate.bindValue(QStringLiteral(":startTime"), realStart.toString(Qt::ISODate));
    QVERIFY(backdate.exec());
    // 内存里的开始时刻必须跟着回拨：生产路径上两者恒等（startFocus 用同一个值写库和写内存，
    // 恢复时又从行里读回内存），只改库会造出一个真实运行中不存在的状态。
    timer->m_startTime = realStart;
    setFocusElapsedSeconds(timer, 9 * 60 * 60);

    const int correctedSeconds = 45 * 60;
    QVERIFY(timer->stopFreeFocusWithDuration(correctedSeconds));

    QSqlQuery row(DatabaseManager::instance()->database());
    QVERIFY(row.exec(QStringLiteral(
        "SELECT start_time, end_time, duration FROM focus_sessions WHERE end_time IS NOT NULL")));
    QVERIFY(row.next());
    const QDateTime savedStart = QDateTime::fromString(row.value(0).toString(), Qt::ISODate);
    const QDateTime savedEnd = QDateTime::fromString(row.value(1).toString(), Qt::ISODate);
    QCOMPARE(row.value(2).toInt(), correctedSeconds);
    // 区间必须跟着时长一起缩短，否则时间轴会显示成"9 小时跨度 / 45 分钟"。
    QCOMPARE(savedStart.secsTo(savedEnd), qint64(correctedSeconds));

    // 而且被让出来的那段时间要能重新补录——"忘了停、改完再补录"是这个功能的典型下一步。
    const int manualId = FocusHistoryService::instance()->addManualSession(
        taskId, realStart.addSecs(3 * 60 * 60), 30);
    QVERIFY2(manualId > 0,
             qPrintable(QStringLiteral("窗口内补录被拒绝：")
                        + FocusHistoryService::instance()->lastError()));
}

void ServiceTests::correctedFreeFocusDurationRejectsValueAboveElapsed()
{
    const int taskId = insertTaskRow(QStringLiteral("被放大的自由计时"), QDate::currentDate());
    QVERIFY(taskId > 0);
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("被放大的自由计时")));
    setFocusElapsedSeconds(timer, 9 * 60 * 60 + 60);

    // 界面把 09:01 手滑打成 90:01：这条时长会直接进统计和长期目标进度，服务层必须拒绝。
    QVERIFY(!timer->stopFreeFocusWithDuration(90 * 60 * 60 + 60));
    QVERIFY(timer->hasActiveSession());
    QCOMPARE(countFocusSessions(), 1);

    // 等于实际计时是允许的边界：用户可以确认"就是这么久"。
    QVERIFY(timer->stopFreeFocusWithDuration(9 * 60 * 60 + 60));
    QCOMPARE(timer->hasActiveSession(), false);
}

void ServiceTests::stopFocusUnderFiveMinutesKeepsTaskPending()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("未满五分钟任务"), logicalToday(), QString()));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value(QStringLiteral("id")).toInt();

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("未满五分钟任务")));
    setFocusElapsedSeconds(FocusTimer::instance(), 299);

    QVERIFY(FocusTimer::instance()->stopFocus());

    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("completed")).toBool(), false);
}

void ServiceTests::stopFocusUnderThreeMinutesDiscardsInvalidSession()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("无效短专注"), logicalToday(), QString()));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap().value(QStringLiteral("id")).toInt();

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("无效短专注")));
    setFocusElapsedSeconds(FocusTimer::instance(), kTestMinimumValidDurationSeconds - 1);

    QVERIFY(FocusTimer::instance()->stopFocus());

    QCOMPARE(countFocusSessions(), 0);
    const QVariantMap task = TaskManager::instance()->getTodayTasks().first().toMap();
    QCOMPARE(task.value(QStringLiteral("completed")).toBool(), false);
}

void ServiceTests::shortSessionEmitsSessionDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("短会话任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy discardSpy(timer, &FocusTimer::sessionDiscarded);

    QVERIFY(timer->startFocus(taskId, QStringLiteral("短会话任务")));
    setFocusElapsedSeconds(timer, 60);
    QVERIFY(timer->stopFocus());

    QCOMPARE(discardSpy.count(), 1);
    QCOMPARE(discardSpy.takeFirst().at(0).toInt(), 60);
}

void ServiceTests::validSessionDoesNotEmitSessionDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("有效会话任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy discardSpy(timer, &FocusTimer::sessionDiscarded);

    QVERIFY(timer->startFocus(taskId, QStringLiteral("有效会话任务")));
    setFocusElapsedSeconds(timer, 300);
    QVERIFY(timer->stopFocus());

    QCOMPARE(discardSpy.count(), 0);
}

void ServiceTests::focusTimerExposesMinimumValidDuration()
{
    FocusTimer* timer = FocusTimer::instance();
    QCOMPARE(timer->minimumValidMinutes(), 3);
}

void ServiceTests::pomodoroWorkCompletesOnlyWhenPlannedDurationReached()
{
    // 计划 15 分钟 = 三段 5 分钟的番茄；前两段不该完成，第三段跨过门槛才完成。
    const int taskId = insertPlannedTask(QStringLiteral("三颗番茄任务"), QDate::currentDate(), -1, 15);
    QVERIFY(taskId > 0);

    QSignalSpy phaseCompletedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);
    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("三颗番茄任务"), 300));
    QCOMPARE(FocusTimer::instance()->targetSeconds(), 300);
    setFocusElapsedSeconds(FocusTimer::instance(), 300);

    // 直接触发 timeout 信号，避免测试真实等待一秒；只验证状态机在边界秒的行为。
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 0);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);
    QCOMPARE(countFocusSessions(), 1);
    QCOMPARE(phaseCompletedSpy.count(), 1);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);
    QCOMPARE(taskCompletedById(taskId), false);

    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("三颗番茄任务"), 300));
    setFocusElapsedSeconds(FocusTimer::instance(), 300);
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(countFocusSessions(), 2);
    QCOMPARE(phaseCompletedSpy.count(), 2);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 2);
    QCOMPARE(taskCompletedById(taskId), false);

    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("三颗番茄任务"), 300));
    setFocusElapsedSeconds(FocusTimer::instance(), 300);
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(countFocusSessions(), 3);
    QCOMPARE(phaseCompletedSpy.count(), 3);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 3);
    QCOMPARE(taskCompletedById(taskId), true);

    QSqlQuery sessionQuery(DatabaseManager::instance()->database());
    QVERIFY(sessionQuery.exec(QStringLiteral(
        "SELECT COUNT(*), MIN(duration), MAX(duration), SUM(pomodoro_completed) FROM focus_sessions")));
    QVERIFY(sessionQuery.next());
    QCOMPARE(sessionQuery.value(0).toInt(), 3);
    QCOMPARE(sessionQuery.value(1).toInt(), 300);
    QCOMPARE(sessionQuery.value(2).toInt(), 300);
    QCOMPARE(sessionQuery.value(3).toInt(), 3);
}

void ServiceTests::pomodoroWorkRequiresPositiveExactPlan()
{
    const int noPlanTaskId = insertPlannedTask(QStringLiteral("未设计划任务"), logicalToday(), -1, 0);
    QVERIFY(noPlanTaskId > 0);
    QVERIFY(FocusTimer::instance()->startPomodoroWork(noPlanTaskId, QStringLiteral("未设计划任务"), 300));
    setFocusElapsedSeconds(FocusTimer::instance(), 300);
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(noPlanTaskId), 1);
    QCOMPARE(taskCompletedById(noPlanTaskId), false);

    const int overTargetTaskId = insertPlannedTask(QStringLiteral("已超额任务"), logicalToday(), -1, 1);
    QVERIFY(overTargetTaskId > 0);
    QVERIFY(insertFocusSessionRowWithMode(overTargetTaskId, logicalToday(), 300, 1));
    QVERIFY(FocusTimer::instance()->startPomodoroWork(overTargetTaskId, QStringLiteral("已超额任务"), 300));
    setFocusElapsedSeconds(FocusTimer::instance(), 300);
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(overTargetTaskId), 2);
    QCOMPARE(taskCompletedById(overTargetTaskId), false);
}

void ServiceTests::pomodoroTargetCompletionFailureKeepsSession()
{
    const int taskId = insertPlannedTask(QStringLiteral("自动完成失败任务"), logicalToday(), -1, 1);
    QVERIFY(taskId > 0);

    QSqlQuery trigger(DatabaseManager::instance()->database());
    QVERIFY(trigger.exec(QStringLiteral(R"SQL(
        CREATE TRIGGER fail_task_auto_completion
        BEFORE UPDATE OF completed ON tasks
        WHEN NEW.id = %1 AND NEW.completed = 1
        BEGIN
            SELECT RAISE(ABORT, 'forced auto completion failure');
        END
    )SQL").arg(taskId)));

    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy failureSpy(timer, &FocusTimer::taskAutoCompleteFailed);
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("自动完成失败任务"), 300));
    setFocusElapsedSeconds(timer, 300);
    QVERIFY(QMetaObject::invokeMethod(&timer->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);
    QCOMPARE(taskCompletedById(taskId), false);
    QCOMPARE(countFocusSessions(), 1);
}

void ServiceTests::manuallyStoppedPomodoroDoesNotCountAsCompleted()
{
    const int taskId = insertTaskRow(QStringLiteral("手动停止番茄"), logicalToday());
    QVERIFY(taskId > 0);

    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("手动停止番茄"), 25 * 60));
    setFocusElapsedSeconds(timer, 10 * 60);
    QVERIFY(timer->stopFocus());

    // 时长仍然是有效专注，但没有自然到点，不得计入完整番茄。
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 10);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 0);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT duration, pomodoro_completed FROM focus_sessions")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 10 * 60);
    QCOMPARE(query.value(1).toInt(), 0);
}

void ServiceTests::pomodoroBreakWritesNoSessionAndCompletes()
{
    QSignalSpy phaseCompletedSpy(FocusTimer::instance(), &FocusTimer::phaseCompleted);

    QVERIFY(FocusTimer::instance()->startBreak(5));
    QCOMPARE(FocusTimer::instance()->hasActiveSession(), false);
    QCOMPARE(FocusTimer::instance()->targetSeconds(), 5);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 5);
    FocusTimer::instance()->pauseFocus();
    QCOMPARE(FocusTimer::instance()->isRunning(), false);
    QVERIFY(FocusTimer::instance()->resumeFocus());
    QCOMPARE(FocusTimer::instance()->isRunning(), true);
    setFocusElapsedSeconds(FocusTimer::instance(), 5);

    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 0);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);
    QCOMPARE(countFocusSessions(), 0);
    QCOMPARE(phaseCompletedSpy.count(), 1);
}

void ServiceTests::pomodoroBreakRestoresTaskContextAndCount()
{
    FocusTimer* timer = FocusTimer::instance();
    const int taskId = insertTaskRow(QStringLiteral("跨启动任务"), QDate::currentDate());
    QVERIFY(taskId > 0);
    timer->m_completedPomodoros = 3;
    QVERIFY(timer->startBreakForTask(600, taskId, QStringLiteral("跨启动任务")));
    setFocusElapsedSeconds(timer, 120);
    timer->prepareForShutdown();

    // 模拟进程重建后的初始内存，恢复结果只能来自 active_focus_state。
    timer->resetSession();
    timer->m_completedPomodoros = 0;
    QVERIFY(timer->restoreInterruptedSession());

    QCOMPARE(timer->phase(), int(FocusTimer::BreakPhase));
    QCOMPARE(timer->isRunning(), false);
    QCOMPARE(timer->currentTaskId(), taskId);
    QCOMPARE(timer->currentTaskTitle(), QStringLiteral("跨启动任务"));
    QCOMPARE(timer->completedPomodoros(), 3);
    QCOMPARE(timer->elapsedSeconds(), 120);
    QVERIFY(timer->stopFocus());
}

void ServiceTests::manualRestDoesNotCreateFocusSessionOrFinishAutomatically()
{
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy focusCompletedSpy(timer, &FocusTimer::focusCompleted);
    QSignalSpy phaseCompletedSpy(timer, &FocusTimer::phaseCompleted);

    QVERIFY(timer->startManualRest());
    QCOMPARE(timer->mode(), int(FocusTimer::ManualRestMode));
    QCOMPARE(timer->phase(), int(FocusTimer::ManualRestPhase));
    QVERIFY(!timer->hasActiveSession());
    QCOMPARE(timer->currentTaskId(), -1);
    QCOMPARE(timer->currentTaskTitle(), QString());
    QCOMPARE(countFocusSessions(), 0);

    // 主动休息没有目标时长；即使刷新计时器，也不能触发番茄完成或写入专注记录。
    setFocusElapsedSeconds(timer, 45);
    QVERIFY(QMetaObject::invokeMethod(&timer->m_timer, "timeout", Qt::DirectConnection));
    QCOMPARE(timer->elapsedSeconds(), 45);
    QCOMPARE(phaseCompletedSpy.count(), 0);
    QCOMPARE(focusCompletedSpy.count(), 0);
    QCOMPARE(countFocusSessions(), 0);

    timer->pauseFocus();
    QVERIFY(!timer->isRunning());
    QVERIFY(timer->resumeFocus());
    QVERIFY(timer->isRunning());
    QVERIFY(timer->stopFocus());
    QCOMPARE(timer->phase(), int(FocusTimer::NoPhase));
    QCOMPARE(countFocusSessions(), 0);
}

void ServiceTests::manualRestRestoresPausedWithoutCountingAsFocus()
{
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startManualRest());
    const QDateTime originalStart = QDateTime::currentDateTime().addSecs(-600);
    timer->m_startTime = originalStart;
    setFocusElapsedSeconds(timer, 185);
    timer->prepareForShutdown();
    timer->resetSession();

    QVERIFY(timer->restoreInterruptedSession());
    QVERIFY(!timer->hasActiveSession());
    QVERIFY(!timer->isRunning());
    QCOMPARE(timer->mode(), int(FocusTimer::ManualRestMode));
    QCOMPARE(timer->phase(), int(FocusTimer::ManualRestPhase));
    QCOMPARE(timer->elapsedSeconds(), 185);
    QCOMPARE(timer->m_startTime.toMSecsSinceEpoch(), originalStart.toMSecsSinceEpoch());
    QCOMPARE(timer->currentTaskId(), -1);
    QCOMPARE(timer->currentTaskTitle(), QString());

    QVERIFY(timer->resumeFocus());
    QVERIFY(timer->stopFocus());
    QCOMPARE(countFocusSessions(), 0);
}

void ServiceTests::restHistorySaveIsAtomicAndUsesLogicalDay()
{
    FocusTimer* timer = FocusTimer::instance();
    FocusHistoryService* history = FocusHistoryService::instance();
    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    QSignalSpy restSpy(timer, &FocusTimer::restCompleted);
    AppSettings::instance()->setDayStartHour(4);

    QVERIFY(timer->startManualRest());
    // 固定在凌晨，验证记录仍归属上一逻辑日；注入计时避免真实等待。
    timer->m_startTime = QDateTime(QDate(2026, 9, 7), QTime(3, 30));
    setFocusElapsedSeconds(timer, 45);
    timer->pauseFocus();
    // 在清除快照时制造失败，确认前面的历史写入也被回滚。
    QVERIFY(query.exec(QStringLiteral(
        "CREATE TRIGGER reject_rest_stop BEFORE DELETE ON active_focus_state "
        "BEGIN SELECT RAISE(ABORT, 'test failure'); END")));
    QVERIFY(!timer->stopFocus());
    QCOMPARE(timer->phase(), int(FocusTimer::ManualRestPhase));
    QCOMPARE(restSpy.count(), 0);
    QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM rest_sessions")) && query.next());
    QCOMPARE(query.value(0).toInt(), 0);
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER reject_rest_stop")));
    QVERIFY(timer->stopFocus());
    QCOMPARE(restSpy.count(), 1);

    const QDate day(2026, 9, 6);
    const auto rows = history->getDayTimeline(day);
    QCOMPARE(rows.size(), 1);
    QVERIFY(rows.first().toMap().value(QStringLiteral("isRest")).toBool());
    QCOMPARE(rows.first().toMap().value(QStringLiteral("durationSeconds")).toInt(), 45);
    QVERIFY(history->getDayTimeline(day.addDays(1)).isEmpty());
    QVERIFY(history->getDaySessions(day).isEmpty());
    QCOMPARE(history->getDayTotalDuration(day), 0);
    QCOMPARE(countFocusSessions(), 0);
    QVERIFY(!timer->stopFocus());
    QCOMPARE(history->getDayTimeline(day).size(), 1);

    // 番茄休息自然到点也生成独立记录，超过目标的计时刷新延迟不能增加休息秒数。
    QVERIFY(timer->startBreak(60));
    timer->m_startTime = QDateTime(day, QTime(12, 0));
    setFocusElapsedSeconds(timer, 70);
    QVERIFY(QMetaObject::invokeMethod(&timer->m_timer, "timeout", Qt::DirectConnection));
    const auto mixed = history->getDayTimeline(day);
    QCOMPARE(mixed.size(), 2);
    QCOMPARE(mixed.first().toMap().value(QStringLiteral("taskTitle")).toString(), QStringLiteral("番茄休息"));
    QCOMPARE(mixed.first().toMap().value(QStringLiteral("durationSeconds")).toInt(), 60);
    QCOMPARE(history->getDayTotalDuration(day), 0);

    QVERIFY(timer->startManualRest());
    timer->pauseFocus();
    QVERIFY(timer->stopFocus());
    QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM rest_sessions")) && query.next());
    QCOMPARE(query.value(0).toInt(), 2);
}

void ServiceTests::deletingActiveTaskDetachesTimerAndSuppressesAutoCompleteFailure()
{
    const int taskId = insertTaskRow(QStringLiteral("删除中的活动任务"), QDate::currentDate());
    QVERIFY(taskId > 0);
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("删除中的活动任务")));

    QSignalSpy currentTaskChangedSpy(timer, &FocusTimer::currentTaskChanged);
    QSignalSpy failureSpy(timer, &FocusTimer::taskAutoCompleteFailed);
    QVERIFY(TaskManager::instance()->deleteTask(taskId));

    // TaskManager 的提交后删除信号必须立刻解绑内存 ID，但会话标题是历史快照，不能丢失。
    QCOMPARE(timer->currentTaskId(), -1);
    QCOMPARE(timer->currentTaskTitle(), QStringLiteral("删除中的活动任务"));
    QCOMPARE(currentTaskChangedSpy.count(), 1);

    QSqlQuery activeStateQuery(DatabaseManager::instance()->database());
    QVERIFY(activeStateQuery.exec(QStringLiteral(
        "SELECT task_id, task_title FROM active_focus_state WHERE singleton_id = 1")));
    QVERIFY(activeStateQuery.next());
    QVERIFY(activeStateQuery.value(0).isNull());
    QCOMPARE(activeStateQuery.value(1).toString(), QStringLiteral("删除中的活动任务"));

    setFocusElapsedSeconds(timer, 300);
    QVERIFY(timer->stopFocus());

    // 删除后的会话仍应保存，但因已解绑任务，结束时不能尝试自动完成一个不存在的任务。
    QCOMPARE(failureSpy.count(), 0);
    QCOMPARE(timer->hasActiveSession(), false);
}

void ServiceTests::pomodoroWorkStoppedUnderMinimumIsDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("番茄短专注"), QDate::currentDate());
    QVERIFY(taskId > 0);

    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("番茄短专注"), 300));
    setFocusElapsedSeconds(FocusTimer::instance(), kTestMinimumValidDurationSeconds - 1);

    QVERIFY(FocusTimer::instance()->stopFocus());

    QCOMPARE(countFocusSessions(), 0);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);
    QCOMPARE(taskCompletedById(taskId), false);
}

void ServiceTests::freeFocusStillCountsUpUnchanged()
{
    const int taskId = insertTaskRow(QStringLiteral("自由计时任务"), QDate::currentDate());
    QVERIFY(taskId > 0);

    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("自由计时任务")));
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);

    setFocusElapsedSeconds(FocusTimer::instance(), 1);
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));
    setFocusElapsedSeconds(FocusTimer::instance(), 2);
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(FocusTimer::instance()->elapsedSeconds(), 2);
    QCOMPARE(FocusTimer::instance()->remainingSeconds(), 0);

    setFocusElapsedSeconds(FocusTimer::instance(), kTestMinimumValidDurationSeconds);
    QVERIFY(FocusTimer::instance()->stopFocus());
    QCOMPARE(countFocusSessions(), 1);
}

void ServiceTests::focusTimerUsesMonotonicElapsedTimeAfterBlockedEventLoop()
{
    const int taskId = insertTaskRow(QStringLiteral("阻塞计时任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("阻塞计时任务")));

    // 模拟 GUI 线程两秒没有处理事件；恢复后只触发一次 timeout，计时仍必须反映真实经过时间。
    QTest::qSleep(2100);
    QVERIFY(QMetaObject::invokeMethod(&timer->m_timer, "timeout", Qt::DirectConnection));
    QVERIFY(timer->elapsedSeconds() >= 2);

    setFocusElapsedSeconds(timer, kTestMinimumValidDurationSeconds);
    QVERIFY(timer->stopFocus());
}

void ServiceTests::interruptedFocusRestoresPausedAndKeepsProgress()
{
    const int taskId = insertTaskRow(QStringLiteral("中断恢复任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("中断恢复任务")));
    setFocusElapsedSeconds(timer, 185);

    timer->prepareForShutdown();
    timer->resetSession();

    QVERIFY(timer->restoreInterruptedSession());
    QCOMPARE(timer->hasActiveSession(), true);
    QCOMPARE(timer->isRunning(), false);
    QCOMPARE(timer->currentTaskId(), taskId);
    QCOMPARE(timer->currentTaskTitle(), QStringLiteral("中断恢复任务"));
    QCOMPARE(timer->elapsedSeconds(), 185);

    QVERIFY(timer->resumeFocus());
    QVERIFY(timer->stopFocus());

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT duration FROM focus_sessions")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 185);
    QVERIFY(!query.next());
}

void ServiceTests::restoreWithoutActiveStateResetsPomodoroCount()
{
    FocusTimer* timer = FocusTimer::instance();
    QSqlQuery stateQuery(DatabaseManager::instance()->database());
    QVERIFY(stateQuery.exec(QStringLiteral(
        "SELECT COUNT(*) FROM active_focus_state WHERE singleton_id = 1")));
    QVERIFY(stateQuery.next());
    QCOMPARE(stateQuery.value(0).toInt(), 0);

    // 模拟换库后遗留在单例内存中的上一轮计数；新库无活动状态时不能把它带过去。
    timer->m_completedPomodoros = 3;
    QSignalSpy pomodoroCountSpy(timer, &FocusTimer::completedPomodorosChanged);

    QVERIFY(timer->restoreInterruptedSession());
    QCOMPARE(timer->completedPomodoros(), 0);
    QCOMPARE(pomodoroCountSpy.count(), 1);

    // 计数已经为零时再次恢复不应制造无意义的属性变更通知。
    QVERIFY(timer->restoreInterruptedSession());
    QCOMPARE(pomodoroCountSpy.count(), 1);
}

void ServiceTests::restoreKeepsSessionWhenTaskWasDeleted()
{
    const int taskId = insertTaskRow(QStringLiteral("会被删除的任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("会被删除的任务")));
    setFocusElapsedSeconds(timer, 240);
    timer->prepareForShutdown();

    // 删除任务：外键把 active_focus_state.task_id 和 focus_sessions.task_id 置空，
    // 但活动状态里的标题快照仍在。已计入的进行中会话必须照常恢复。
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    timer->resetSession();

    QVERIFY(timer->restoreInterruptedSession());
    QCOMPARE(timer->hasActiveSession(), true);
    QCOMPARE(timer->currentTaskId(), -1);
    QCOMPARE(timer->currentTaskTitle(), QStringLiteral("会被删除的任务"));
    QCOMPARE(timer->elapsedSeconds(), 240);

    // 完成后正常落库；没有可完成的任务时不应发出自动完成失败的告警。
    QSignalSpy autoCompleteFailSpy(timer, &FocusTimer::taskAutoCompleteFailed);
    setFocusElapsedSeconds(timer, 360);
    QVERIFY(timer->stopFocus());
    QCOMPARE(autoCompleteFailSpy.count(), 0);

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT duration FROM focus_sessions WHERE end_time IS NOT NULL")));
    QVERIFY(query.next());
    QCOMPARE(query.value(0).toInt(), 360);
}

void ServiceTests::discardedShortPomodoroDoesNotAdvanceLongBreakCount()
{
    // 长休息的连续计数必须与「写入时算不算有效番茄」同一口径。此前它只看
    // 「刚结束的是工作阶段」：一个到点却因时长不足被整条丢弃的会话，会话没进数据库，
    // 计数却 +1，于是长休息节奏被一条无效记录推着走。
    //
    // 此前不出错只依赖一个外部事实——UI 把专注时长下限锁在 5 分钟。
    // 但 startPomodoroWork 是 Q_INVOKABLE，边界并不在 UI 上。
    FocusTimer* timer = FocusTimer::instance();
    const int taskId = insertTaskRow(QStringLiteral("超短番茄"), QDate::currentDate());
    QVERIFY(taskId > 0);
    QCOMPARE(timer->completedPomodoros(), 0);

    QSignalSpy discardedSpy(timer, &FocusTimer::sessionDiscarded);
    // 1 秒目标：到点时时长必然低于有效门槛，会话应被丢弃。
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("超短番茄"), 1));
    QTRY_COMPARE_WITH_TIMEOUT(discardedSpy.count(), 1, 5000);

    // 会话被丢弃 → 数据库里没有记录 → 连续番茄数也不该动。
    QCOMPARE(countFocusSessions(), 0);
    QCOMPARE(timer->completedPomodoros(), 0);
}

void ServiceTests::completionSaveFailureNotifiesOnceAndKeepsRetrying()
{
    const int taskId = insertTaskRow(QStringLiteral("保存失败重试任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("保存失败重试任务"), 1));

    // 到点前关库：完成保存必然失败，计时器应继续运行并每秒重试，但只提示一次。
    QSignalSpy failureSpy(timer, &FocusTimer::operationFailed);
    DatabaseManager::instance()->close();

    QTRY_COMPARE_WITH_TIMEOUT(failureSpy.count(), 1, 5000);
    // 再等两个 tick，确认重试不会把提示刷成第二条。
    QTest::qWait(2200);
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(timer->isRunning(), true);
}

void ServiceTests::startupCleanupRemovesLegacyOrphanedSession()
{
    const int taskId = insertTaskRow(QStringLiteral("旧版脏会话任务"), QDate::currentDate());
    QVERIFY(insertUnfinishedFocusSessionRow(taskId, QDate::currentDate(), 120));
    QCOMPARE(countFocusSessions(), 1);

    QVERIFY(FocusTimer::instance()->restoreInterruptedSession());
    QCOMPARE(countFocusSessions(), 0);
}

void ServiceTests::queryServicesReportDatabaseFailureInsteadOfSilentEmptyData()
{
    QSignalSpy taskFailureSpy(TaskManager::instance(), &TaskManager::operationFailed);
    QSignalSpy statisticsFailureSpy(StatisticsService::instance(), &StatisticsService::operationFailed);
    QSignalSpy categoryFailureSpy(CategoryManager::instance(), &CategoryManager::operationFailed);
    QSignalSpy routineFailureSpy(RoutineManager::instance(), &RoutineManager::operationFailed);

    DatabaseManager::instance()->close();

    QVERIFY(TaskManager::instance()->getTodayTasks().isEmpty());
    const QVariantMap stats = StatisticsService::instance()->getDayStats(QDate::currentDate());
    QCOMPARE(stats.value(QStringLiteral("totalDuration")).toInt(), 0);
    QVERIFY(CategoryManager::instance()->getAllCategories().isEmpty());
    QVERIFY(RoutineManager::instance()->getRoutines().isEmpty());

    QVERIFY(taskFailureSpy.count() >= 1);
    QVERIFY(statisticsFailureSpy.count() >= 1);
    QVERIFY(categoryFailureSpy.count() >= 1);
    QVERIFY(routineFailureSpy.count() >= 1);
}

void ServiceTests::estimatedMinutesDefaultsToZeroAfterMigration()
{
    // 旧库升级后必须补出 estimated_pomodoros 列且默认 0，原有任务与专注记录一条不丢。
    DatabaseManager::instance()->close();
    const QString legacyPath = m_tempDir->filePath(QStringLiteral("legacy-estimate.sqlite"));
    QVERIFY(createLegacyVersion1Database(legacyPath));
    QVERIFY(DatabaseManager::instance()->initialize(legacyPath));

    // 新列存在性用直接 SELECT 验证：列缺失时查询会失败。
    QSqlQuery modeProbe(DatabaseManager::instance()->database());
    QVERIFY(modeProbe.exec(QStringLiteral("SELECT mode FROM focus_sessions LIMIT 1")));

    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "SELECT COUNT(*), MIN(estimated_minutes), MAX(estimated_minutes) FROM tasks")));
    QVERIFY(query.next());
    // 三条旧任务全部保留，且预估默认 0。
    QCOMPARE(query.value(0).toInt(), 3);
    QCOMPARE(query.value(1).toInt(), 0);
    QCOMPARE(query.value(2).toInt(), 0);
}

void ServiceTests::addTaskPersistsEstimatedPomodoros()
{
    // 四参新增重载写入预估值，越界一律夹紧到 [0, 99]，绝不因预估值导致任务保存失败。
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("四番茄任务"), logicalToday(), -1, 4));
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("越界任务"), logicalToday(), -1, 5000));

    const QVariantList tasks = TaskManager::instance()->getTodayTasks();
    QVariantMap normal;
    QVariantMap clamped;
    for (const QVariant& taskValue : tasks) {
        const QVariantMap map = taskValue.toMap();
        if (map.value(QStringLiteral("title")).toString() == QStringLiteral("四番茄任务")) {
            normal = map;
        } else if (map.value(QStringLiteral("title")).toString() == QStringLiteral("越界任务")) {
            clamped = map;
        }
    }
    QCOMPARE(normal.value(QStringLiteral("estimatedMinutes")).toInt(), 4);
    QCOMPARE(clamped.value(QStringLiteral("estimatedMinutes")).toInt(),
             TaskManager::kMaxEstimatedMinutes);
}

void ServiceTests::updateTaskChangesEstimateAndRenamePreservesIt()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("待改预估"), logicalToday(), -1, 2));
    const int taskId = TaskManager::instance()->getTodayTasks().first().toMap()
        .value(QStringLiteral("id")).toInt();

    // 五参重载显式改预估。
    QVERIFY(TaskManager::instance()->updateTask(
        taskId, QStringLiteral("待改预估"), -1, logicalToday(), 6));
    QCOMPARE(taskMapById(TaskManager::instance()->getTodayTasks(), taskId)
                 .value(QStringLiteral("estimatedMinutes")).toInt(), 6);

    // 四参重载（重命名）不得清零已有预估。
    QVERIFY(TaskManager::instance()->updateTask(
        taskId, QStringLiteral("改了标题"), -1, logicalToday()));
    const QVariantMap renamed = taskMapById(TaskManager::instance()->getTodayTasks(), taskId);
    QCOMPARE(renamed.value(QStringLiteral("title")).toString(), QStringLiteral("改了标题"));
    QCOMPARE(renamed.value(QStringLiteral("estimatedMinutes")).toInt(), 6);
}

void ServiceTests::taskAggregatesActualPomodorosFromValidWorkSessions()
{
    const int taskId = insertTaskRow(QStringLiteral("聚合任务"), logicalToday());
    QVERIFY(taskId > 0);

    // 两段有效番茄工作（默认 mode=1），各 25 分钟。
    QVERIFY(insertFocusSessionRow(taskId, logicalToday(), 25 * 60));
    QVERIFY(insertFocusSessionRow(taskId, logicalToday(), 25 * 60));
    // 一段未达有效门槛（<3 分钟）：不计番茄，也不计专注分钟。
    QVERIFY(insertFocusSessionRow(taskId, logicalToday(), kTestMinimumValidDurationSeconds - 1));

    const QVariantMap task = taskMapById(TaskManager::instance()->getTasksByDate(logicalToday()), taskId);
    QCOMPARE(task.value(QStringLiteral("actualPomodoros")).toInt(), 2);
    QCOMPARE(task.value(QStringLiteral("focusedMinutes")).toInt(), 50);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 2);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 50);
}

void ServiceTests::freeFocusCountsMinutesButNotPomodoros()
{
    const int taskId = insertTaskRow(QStringLiteral("自由计时任务"), logicalToday());
    QVERIFY(taskId > 0);

    // 自由计时段 mode=0：只累计专注分钟，不折算为番茄。
    QVERIFY(insertFocusSessionRowWithMode(taskId, logicalToday(), 30 * 60, 0));
    // 再叠加一段有效番茄段，验证两种模式各归各的口径。
    QVERIFY(insertFocusSessionRowWithMode(taskId, logicalToday(), 25 * 60, 1));

    const QVariantMap task = taskMapById(TaskManager::instance()->getTasksByDate(logicalToday()), taskId);
    QCOMPARE(task.value(QStringLiteral("actualPomodoros")).toInt(), 1);
    QCOMPARE(task.value(QStringLiteral("focusedMinutes")).toInt(), 55);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);
}

void ServiceTests::pomodoroAggregationDoesNotCrossTasksOrLeakUnbound()
{
    const int taskA = insertTaskRow(QStringLiteral("任务A"), logicalToday());
    const int taskB = insertTaskRow(QStringLiteral("任务B"), logicalToday());
    QVERIFY(taskA > 0 && taskB > 0);

    QVERIFY(insertFocusSessionRow(taskA, logicalToday(), 25 * 60));
    QVERIFY(insertFocusSessionRow(taskA, logicalToday(), 25 * 60));
    QVERIFY(insertFocusSessionRow(taskB, logicalToday(), 25 * 60));
    // 未绑定任务的专注（task_id 为空）不得污染任何任务的番茄数。
    QVERIFY(insertFocusSessionRow(-1, logicalToday(), 25 * 60));

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(taskMapById(tasks, taskA).value(QStringLiteral("actualPomodoros")).toInt(), 2);
    QCOMPARE(taskMapById(tasks, taskB).value(QStringLiteral("actualPomodoros")).toInt(), 1);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskA), 2);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskB), 1);
}

void ServiceTests::recoveredPomodoroStillCountsForOriginalTask()
{
    const int taskId = insertTaskRow(QStringLiteral("崩溃恢复任务"), logicalToday());
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("崩溃恢复任务"), 25 * 60));
    setFocusElapsedSeconds(timer, 180);

    // 模拟异常退出后重建进程并从 active_focus_state 恢复。
    timer->prepareForShutdown();
    timer->resetSession();
    QVERIFY(timer->restoreInterruptedSession());
    QCOMPARE(timer->currentTaskId(), taskId);

    // 恢复后继续跑到目标秒，必须走自然到点分支才能计一个番茄。
    QVERIFY(timer->resumeFocus());
    setFocusElapsedSeconds(timer, 25 * 60);
    QVERIFY(QMetaObject::invokeMethod(&timer->m_timer, "timeout", Qt::DirectConnection));

    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);
    const QVariantMap task = taskMapById(TaskManager::instance()->getTasksByDate(logicalToday()), taskId);
    QCOMPARE(task.value(QStringLiteral("actualPomodoros")).toInt(), 1);
}

void ServiceTests::deletingTaskDetachesButKeepsPomodoroHistory()
{
    const int taskId = insertTaskRow(QStringLiteral("将删除任务"), logicalToday());
    QVERIFY(insertFocusSessionRow(taskId, logicalToday(), 25 * 60));
    QCOMPARE(countFocusSessions(), 1);

    QVERIFY(TaskManager::instance()->deleteTask(taskId));

    // 删除任务只解除关联，历史专注记录整条保留（task_id 置空）。
    QCOMPARE(countFocusSessions(), 1);
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("SELECT task_id, mode, duration FROM focus_sessions")));
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());
    QCOMPARE(query.value(2).toInt(), 25 * 60);
}

void ServiceTests::deletingTaskKeepsCategorySnapshotForStatistics()
{
    AppSettings::instance()->setDayStartHour(0);
    QSqlQuery categoryQuery(DatabaseManager::instance()->database());
    QVERIFY(categoryQuery.exec(QStringLiteral(
        "INSERT INTO categories (name, color) VALUES ('历史快照科目', '#123456')")));
    const int categoryId = categoryQuery.lastInsertId().toInt();
    QVERIFY(categoryId > 0);

    const int taskId = insertTaskRowWithCategoryId(
        QStringLiteral("会被删除的快照任务"), logicalToday(), categoryId,
        QString(), false, QDateTime::currentDateTime().toString(Qt::ISODate));
    QVERIFY(taskId > 0);

    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("会被删除的快照任务"), 300));
    setFocusElapsedSeconds(timer, 300);
    QVERIFY(QMetaObject::invokeMethod(&timer->m_timer, "timeout", Qt::DirectConnection));

    QVERIFY(TaskManager::instance()->deleteTask(taskId));

    QSqlQuery snapshotQuery(DatabaseManager::instance()->database());
    QVERIFY(snapshotQuery.exec(QStringLiteral(
        "SELECT task_id, category_id_snapshot, category_name_snapshot, "
        "category_color_snapshot FROM focus_sessions")));
    QVERIFY(snapshotQuery.next());
    QVERIFY(snapshotQuery.value(0).isNull());
    QCOMPARE(snapshotQuery.value(1).toInt(), categoryId);
    QCOMPARE(snapshotQuery.value(2).toString(), QStringLiteral("历史快照科目"));
    QCOMPARE(snapshotQuery.value(3).toString(), QStringLiteral("#123456"));

    const QVariantMap stats = StatisticsService::instance()->getCategoryStats(
        logicalToday(), logicalToday());
    const QVariantList categories = stats.value(QStringLiteral("categories")).toList();
    QCOMPARE(categories.size(), 1);
    QCOMPARE(categories.first().toMap().value(QStringLiteral("name")).toString(),
             QStringLiteral("历史快照科目"));
    QCOMPARE(categories.first().toMap().value(QStringLiteral("duration")).toInt(), 300);
}

void ServiceTests::isRoutineGeneratedTaskDistinguishesInstances()
{
    const int normalId = insertTaskRow(QStringLiteral("普通任务"), logicalToday());
    QVERIFY(normalId > 0);
    QVERIFY(!TaskManager::instance()->isRoutineGeneratedTask(normalId));

    // 直接插入一条例行生成实例（routine_generated=1）。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, routine_generated) VALUES (:t, :d, 0, 1)"));
    query.bindValue(QStringLiteral(":t"), QStringLiteral("例行实例"));
    query.bindValue(QStringLiteral(":d"), logicalToday().toString(Qt::ISODate));
    QVERIFY(query.exec());
    const int routineId = query.lastInsertId().toInt();
    QVERIFY(TaskManager::instance()->isRoutineGeneratedTask(routineId));

    // 不存在的 id 返回 false，不崩溃。
    QVERIFY(!TaskManager::instance()->isRoutineGeneratedTask(999999));
}

void ServiceTests::completeUndoRestoresPriorStateWithoutTouchingFields()
{
    QVERIFY(TaskManager::instance()->addTask(QStringLiteral("可撤销完成"), logicalToday(), -1, 3));
    const QVariantMap before = TaskManager::instance()->getTodayTasks().first().toMap();
    const int taskId = before.value(QStringLiteral("id")).toInt();
    QCOMPARE(before.value(QStringLiteral("completed")).toBool(), false);

    // 完成立即写库。
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QCOMPARE(taskCompletedById(taskId), true);

    // 撤销完成：仅翻回 completed；id、标题、预估番茄数等其它字段保持不变。
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, false));
    const QVariantMap after = taskMapById(TaskManager::instance()->getTodayTasks(), taskId);
    QCOMPARE(after.value(QStringLiteral("id")).toInt(), taskId);
    QCOMPARE(after.value(QStringLiteral("completed")).toBool(), false);
    QCOMPARE(after.value(QStringLiteral("title")).toString(), QStringLiteral("可撤销完成"));
    QCOMPARE(after.value(QStringLiteral("estimatedMinutes")).toInt(), 3);
}

void ServiceTests::weeklyReviewPeriodStateUsesLogicalTodayAsGiven()
{
    const QDate weekStart(2026, 7, 13);
    StatisticsService* stats = StatisticsService::instance();

    // 进入下周一逻辑日后，本周才算结束。
    QCOMPARE(stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-19"))
                 .value(QStringLiteral("periodState")).toString(),
             QStringLiteral("current"));
    QCOMPARE(stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"))
                 .value(QStringLiteral("periodState")).toString(),
             QStringLiteral("ended"));
    const QVariantMap future = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-12"));
    QCOMPARE(future.value(QStringLiteral("periodState")).toString(), QStringLiteral("future"));
    QCOMPARE(future.value(QStringLiteral("loadState")).toString(), QStringLiteral("ready"));
    QCOMPARE(future.value(QStringLiteral("hasDisplayContent")).toBool(), false);

    // 传进来的已经是逻辑日期：换日界不能让服务对它再换算一次。
    AppSettings::instance()->setDayStartHour(0);
    QCOMPARE(stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-19"))
                 .value(QStringLiteral("periodState")).toString(),
             QStringLiteral("current"));
    QCOMPARE(stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"))
                 .value(QStringLiteral("periodState")).toString(),
             QStringLiteral("ended"));
    AppSettings::instance()->setDayStartHour(4);

    // 参数错误返回 error，不能混作空周或未来周隐藏掉。
    const QVariantMap badToday = stats->getWeeklyReview(weekStart, QStringLiteral("2026-7-20"));
    QCOMPARE(badToday.value(QStringLiteral("loadState")).toString(), QStringLiteral("error"));
    QVERIFY(!badToday.value(QStringLiteral("errorMessage")).toString().isEmpty());
    QCOMPARE(badToday.value(QStringLiteral("hasDisplayContent")).toBool(), false);
    QCOMPARE(stats->getWeeklyReview(weekStart.addDays(2), QStringLiteral("2026-07-20"))
                 .value(QStringLiteral("loadState")).toString(),
             QStringLiteral("error"));
    QCOMPARE(stats->getWeeklyReview(QDate(), QStringLiteral("2026-07-20"))
                 .value(QStringLiteral("loadState")).toString(),
             QStringLiteral("error"));

    // 周比较收到同一个逻辑今天：当前周三项指标都不给涨跌；已结束周与整周比较一致。
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(-7), 30 * 60));
    QVERIFY(insertFocusSessionRow(-1, weekStart.addDays(1), 45 * 60));
    const QVariantMap currentComparison =
        stats->getWeekComparison(weekStart, QStringLiteral("2026-07-15"));
    QCOMPARE(currentComparison.value(QStringLiteral("periodState")).toString(), QStringLiteral("current"));
    for (const QString& metric : {QStringLiteral("duration"), QStringLiteral("effectiveDays"),
                                  QStringLiteral("sessionCount")}) {
        QVERIFY2(!currentComparison.value(metric).toMap().value(QStringLiteral("hasData")).toBool(),
                 qPrintable(metric));
    }
    const QVariantMap endedComparison = stats->getWeekComparison(weekStart, QStringLiteral("2026-07-20"));
    QCOMPARE(endedComparison.value(QStringLiteral("periodState")).toString(), QStringLiteral("ended"));
    const QVariantMap duration = endedComparison.value(QStringLiteral("duration")).toMap();
    QVERIFY(duration.value(QStringLiteral("hasData")).toBool());
    QCOMPARE(duration.value(QStringLiteral("currentValue")).toInt(), 45 * 60);
    QCOMPARE(duration.value(QStringLiteral("previousValue")).toInt(), 30 * 60);
    QCOMPARE(stats->getWeekComparison(weekStart, QStringLiteral("2026-7-20"))
                 .value(QStringLiteral("hasData")).toBool(),
             false);
}

void ServiceTests::weeklyReviewAssignsSessionsByDayStartHour()
{
    StatisticsService* stats = StatisticsService::instance();
    AppSettings* settings = AppSettings::instance();

    // 周一 03:30 开始的会话：日界 04:00 下属于上周日，日界 00:00 下属于本周一。
    QVERIFY(insertFocusSessionRowAt(-1, QDate(2026, 7, 20), QStringLiteral("03:30:00"),
                                    QStringLiteral("04:30:00"), 60 * 60));
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-19"), 60));
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-20"), 60));

    auto goalDay = [](const QVariantMap& review) {
        const QVariantList days =
            review.value(QStringLiteral("goal")).toMap().value(QStringLiteral("days")).toList();
        return days.size() == 1 ? days.first().toMap() : QVariantMap();
    };

    QVariantMap sunday = goalDay(stats->getWeeklyReview(QDate(2026, 7, 13), QStringLiteral("2026-07-22")));
    QCOMPARE(sunday.value(QStringLiteral("date")).toString(), QStringLiteral("2026-07-19"));
    QCOMPARE(sunday.value(QStringLiteral("actualSeconds")).toInt(), 60 * 60);
    QCOMPARE(sunday.value(QStringLiteral("met")).toBool(), true);
    QVariantMap monday = goalDay(stats->getWeeklyReview(QDate(2026, 7, 20), QStringLiteral("2026-07-22")));
    QCOMPARE(monday.value(QStringLiteral("date")).toString(), QStringLiteral("2026-07-20"));
    QCOMPARE(monday.value(QStringLiteral("actualSeconds")).toInt(), 0);

    settings->setDayStartHour(0);
    sunday = goalDay(stats->getWeeklyReview(QDate(2026, 7, 13), QStringLiteral("2026-07-22")));
    QCOMPARE(sunday.value(QStringLiteral("actualSeconds")).toInt(), 0);
    monday = goalDay(stats->getWeeklyReview(QDate(2026, 7, 20), QStringLiteral("2026-07-22")));
    QCOMPARE(monday.value(QStringLiteral("actualSeconds")).toInt(), 60 * 60);
    QCOMPARE(monday.value(QStringLiteral("met")).toBool(), true);
    settings->setDayStartHour(4);

    // 跨年周按日期范围归属：2026-12-28（周一）～ 2027-01-03（周日）。
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2027, 1, 2), 40 * 60, 0));
    const QVariantMap crossYear = stats->getWeeklyReview(QDate(2026, 12, 28), QStringLiteral("2027-01-04"));
    QCOMPARE(crossYear.value(QStringLiteral("periodState")).toString(), QStringLiteral("ended"));
    const QVariantList subjects = crossYear.value(QStringLiteral("subjects")).toList();
    QCOMPARE(subjects.size(), 1);
    QCOMPARE(subjects.first().toMap().value(QStringLiteral("name")).toString(), QStringLiteral("未关联任务"));
    QCOMPARE(subjects.first().toMap().value(QStringLiteral("currentSeconds")).toInt(), 40 * 60);
    const QVariantMap nextWeek = stats->getWeeklyReview(QDate(2027, 1, 4), QStringLiteral("2027-01-05"));
    QVERIFY(nextWeek.value(QStringLiteral("subjects")).toList().isEmpty());
}

void ServiceTests::weeklyReviewGoalSummaryExcludesToday()
{
    const QDate weekStart(2026, 7, 13);
    StatisticsService* stats = StatisticsService::instance();
    AppSettings* settings = AppSettings::instance();
    const int task = insertPlannedTask(QStringLiteral("数学练习"), weekStart,
                                       categoryIdByName(QStringLiteral("数学")), 0);
    QVERIFY(task > 0);

    // 周一：纯自由计时、未关联任务，刚好达标（3600 秒 = 60 分钟）。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-13"), 60));
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 13), 60 * 60, 0));
    // 周二：差 1 秒——按原始秒数判断不达标，不按取整后的分钟。不足 3 分钟的会话不算有效投入。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-14"), 60));
    QVERIFY(insertFocusSessionRowWithMode(task, QDate(2026, 7, 14), 60 * 60 - 1, 1));
    QVERIFY(insertFocusSessionRowWithMode(task, QDate(2026, 7, 14), 179, 0));
    // 周三是今天：超过目标也不进 K、N 与两项合计，单独给进度。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-15"), 30));
    QVERIFY(insertFocusSessionRowWithMode(task, QDate(2026, 7, 15), 45 * 60, 0));
    // 周四是未来日期：有目标也不计入。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-16"), 90));

    QVariantMap review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    QCOMPARE(review.value(QStringLiteral("loadState")).toString(), QStringLiteral("ready"));
    QCOMPARE(review.value(QStringLiteral("periodState")).toString(), QStringLiteral("current"));
    QVariantMap goal = review.value(QStringLiteral("goal")).toMap();
    QCOMPARE(goal.value(QStringLiteral("goalDays")).toInt(), 2);
    QCOMPARE(goal.value(QStringLiteral("metDays")).toInt(), 1);
    QCOMPARE(goal.value(QStringLiteral("goalMinutesTotal")).toInt(), 120);
    QCOMPARE(goal.value(QStringLiteral("actualSecondsTotal")).toInt(), 2 * 60 * 60 - 1);
    QVariantMap todayGoal = review.value(QStringLiteral("todayGoal")).toMap();
    QCOMPARE(todayGoal.value(QStringLiteral("date")).toString(), QStringLiteral("2026-07-15"));
    QCOMPARE(todayGoal.value(QStringLiteral("goalMinutes")).toInt(), 30);
    QCOMPARE(todayGoal.value(QStringLiteral("actualSeconds")).toInt(), 45 * 60);
    QCOMPARE(todayGoal.value(QStringLiteral("progressPercent")).toDouble(), 150.0);
    // 当前周不产出事实。
    QVERIFY(review.value(QStringLiteral("facts")).toList().isEmpty());
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), true);

    // 今天刚好达标、未达标同样不进分母。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-15"), 45));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    goal = review.value(QStringLiteral("goal")).toMap();
    QCOMPARE(goal.value(QStringLiteral("goalDays")).toInt(), 2);
    QCOMPARE(goal.value(QStringLiteral("metDays")).toInt(), 1);
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-15"), 90));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    goal = review.value(QStringLiteral("goal")).toMap();
    QCOMPARE(goal.value(QStringLiteral("goalDays")).toInt(), 2);
    QCOMPARE(goal.value(QStringLiteral("metDays")).toInt(), 1);
    todayGoal = review.value(QStringLiteral("todayGoal")).toMap();
    QCOMPARE(todayGoal.value(QStringLiteral("progressPercent")).toDouble(), 50.0);

    // 同一周结束后，今天变成已结束的一天，才进入 K、N。
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    goal = review.value(QStringLiteral("goal")).toMap();
    QCOMPARE(goal.value(QStringLiteral("goalDays")).toInt(), 4);
    QVERIFY(review.value(QStringLiteral("todayGoal")).toMap().isEmpty());
}

void ServiceTests::weeklyReviewReconciliationUsesSameTaskSet()
{
    const QDate weekStart(2026, 7, 13);
    StatisticsService* stats = StatisticsService::instance();
    const int mathId = categoryIdByName(QStringLiteral("数学"));
    const int politicsId = categoryIdByName(QStringLiteral("政治"));
    const int englishId = categoryIdByName(QStringLiteral("英语"));
    QVERIFY(mathId > 0 && politicsId > 0 && englishId > 0);

    // 集合内：数学计划 100 分钟，周内投入 3000 秒；下周补做的 1200 秒不算这一周。
    const int mathTask = insertPlannedTask(QStringLiteral("数学计划"), QDate(2026, 7, 14), mathId, 100);
    QVERIFY(insertFocusSessionRowWithMode(mathTask, QDate(2026, 7, 14), 3000, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathTask, QDate(2026, 7, 21), 1200, 0));
    // 同科目、没填预计用时的任务：不进对账。
    const int mathFree = insertPlannedTask(QStringLiteral("数学自由"), QDate(2026, 7, 14), mathId, 0);
    QVERIFY(insertFocusSessionRowWithMode(mathFree, QDate(2026, 7, 14), 6000, 0));
    // 计划日期在上周的任务，本周做了也不进本周对账。
    const int lastWeekTask = insertPlannedTask(QStringLiteral("上周英语"), QDate(2026, 7, 8), englishId, 60);
    QVERIFY(insertFocusSessionRowWithMode(lastWeekTask, QDate(2026, 7, 15), 1800, 0));
    // 未关联任务的会话不进对账。
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 15), 2400, 0));
    // 任务当前科目是政治、会话快照记的是英语：对账按任务当前科目归组。
    const int politicsTask = insertPlannedTask(QStringLiteral("政治计划"), QDate(2026, 7, 16), politicsId, 50);
    QVERIFY(insertFocusSessionWithSnapshot(politicsTask, QDate(2026, 7, 16), QStringLiteral("12:00:00"),
                                           1500, QStringLiteral("英语"), QStringLiteral("#c9956e")));

    QVariantMap review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    QVariantMap planned = review.value(QStringLiteral("plannedTasks")).toMap();
    QVariantList rows = planned.value(QStringLiteral("rows")).toList();
    QCOMPARE(rows.size(), 2);
    // 计划多的在前。
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("subject")).toString(), QStringLiteral("数学"));
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("plannedMinutes")).toInt(), 100);
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("actualSeconds")).toInt(), 3000);
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("investmentRatioPercent")).toDouble(), 50.0);
    QCOMPARE(rows.at(1).toMap().value(QStringLiteral("subject")).toString(), QStringLiteral("政治"));
    QCOMPARE(rows.at(1).toMap().value(QStringLiteral("actualSeconds")).toInt(), 1500);
    QCOMPARE(planned.value(QStringLiteral("totalPlannedMinutes")).toInt(), 150);
    QCOMPARE(planned.value(QStringLiteral("totalActualSeconds")).toInt(), 4500);
    QCOMPARE(planned.value(QStringLiteral("totalInvestmentRatioPercent")).toDouble(), 50.0);
    QCOMPARE(planned.value(QStringLiteral("inProgress")).toBool(), false);

    // 集合外的投入再多，也不改变已有对账比例。
    QVERIFY(insertFocusSessionRowWithMode(mathFree, QDate(2026, 7, 17), 9000, 0));
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 17), 9000, 0));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    planned = review.value(QStringLiteral("plannedTasks")).toMap();
    QCOMPARE(planned.value(QStringLiteral("totalActualSeconds")).toInt(), 4500);
    QCOMPARE(planned.value(QStringLiteral("totalInvestmentRatioPercent")).toDouble(), 50.0);

    // 投入／计划比可以超过 100%。
    QVERIFY(insertFocusSessionRowWithMode(mathTask, QDate(2026, 7, 18), 6000, 0));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    rows = review.value(QStringLiteral("plannedTasks")).toMap().value(QStringLiteral("rows")).toList();
    QCOMPARE(rowBySubject(rows, QStringLiteral("数学")).value(QStringLiteral("investmentRatioPercent")).toDouble(),
             150.0);

    // 当前周：分母是整周计划，分子只算到逻辑今天为止已经产生的投入，并标为进行中。
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    planned = review.value(QStringLiteral("plannedTasks")).toMap();
    QCOMPARE(planned.value(QStringLiteral("inProgress")).toBool(), true);
    QCOMPARE(planned.value(QStringLiteral("totalPlannedMinutes")).toInt(), 150);
    QCOMPARE(rowBySubject(planned.value(QStringLiteral("rows")).toList(), QStringLiteral("数学"))
                 .value(QStringLiteral("actualSeconds")).toInt(),
             3000);

    // 没有计划任务的周：没有对账行，合计比例为空，不除零。
    const QVariantMap noPlan = stats->getWeeklyReview(QDate(2026, 6, 29), QStringLiteral("2026-07-20"));
    const QVariantMap noPlanTasks = noPlan.value(QStringLiteral("plannedTasks")).toMap();
    QVERIFY(noPlanTasks.value(QStringLiteral("rows")).toList().isEmpty());
    QVERIFY(noPlanTasks.value(QStringLiteral("totalInvestmentRatioPercent")).isNull());
}

void ServiceTests::weeklyReviewGoalShortfallFact()
{
    const QDate weekStart(2026, 7, 13);
    AppSettings* settings = AppSettings::instance();

    // 周一：刚好 60%（3600 / 6000 秒），严格小于才算差额。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-13"), 100));
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 13), 3600, 0));
    // 周二：59.98%，是候选。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-14"), 100));
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 14), 3599, 0));
    // 周三：50%，更低，入选。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-15"), 50));
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 15), 1500, 0));
    // 周四：同样 50%，并列保留较早的周三。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-16"), 50));
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 16), 1500, 0));
    // 周五：高于 60%，而且达标。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-17"), 10));
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 17), 3600, 0));

    QVariantMap review = StatisticsService::instance()->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    QVariantList facts = review.value(QStringLiteral("facts")).toList();
    QCOMPARE(facts.size(), 1);
    const QVariantMap fact = facts.first().toMap();
    QCOMPARE(fact.value(QStringLiteral("type")).toString(), QStringLiteral("goalShortfall"));
    QCOMPARE(fact.value(QStringLiteral("date")).toString(), QStringLiteral("2026-07-15"));
    QCOMPARE(fact.value(QStringLiteral("goalMinutes")).toInt(), 50);
    QCOMPARE(fact.value(QStringLiteral("actualSeconds")).toInt(), 1500);
    QCOMPARE(fact.value(QStringLiteral("ratioPercent")).toDouble(), 50.0);
    const QVariantMap goal = review.value(QStringLiteral("goal")).toMap();
    QCOMPARE(goal.value(QStringLiteral("goalDays")).toInt(), 5);
    QCOMPARE(goal.value(QStringLiteral("metDays")).toInt(), 1);

    // 把低于 60% 的几天目标调低到能达标后，就没有目标事实。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-14"), 1));
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-15"), 1));
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-16"), 1));
    review = StatisticsService::instance()->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    QVERIFY(factOfType(review.value(QStringLiteral("facts")).toList(), QStringLiteral("goalShortfall")).isEmpty());
}

void ServiceTests::weeklyReviewSubjectShareChangeFactGuards()
{
    const QDate weekStart(2026, 7, 13);
    const QDate previousDay(2026, 7, 7);
    const QDate currentDay(2026, 7, 14);
    StatisticsService* stats = StatisticsService::instance();
    const int mathTask = insertPlannedTask(QStringLiteral("数学"), currentDay,
                                           categoryIdByName(QStringLiteral("数学")), 0);
    const int englishTask = insertPlannedTask(QStringLiteral("英语"), currentDay,
                                              categoryIdByName(QStringLiteral("英语")), 0);
    const int uncategorizedTask = insertPlannedTask(QStringLiteral("无科目"), currentDay, -1, 0);
    QVERIFY(mathTask > 0 && englishTask > 0 && uncategorizedTask > 0);

    auto shareFact = [stats, weekStart]() {
        return factOfType(stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"))
                              .value(QStringLiteral("facts")).toList(),
                          QStringLiteral("subjectShareChange"));
    };

    // 数学 50% → 75%、英语 50% → 25%，变化同为 25 个百分点、3600 秒：并列按名称选数学。
    QVERIFY(insertFocusSessionRowWithMode(mathTask, previousDay, 7200, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, previousDay, 7200, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathTask, currentDay, 10800, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, currentDay, 3600, 0));
    QVariantMap fact = shareFact();
    QCOMPARE(fact.value(QStringLiteral("subject")).toString(), QStringLiteral("数学"));
    QCOMPARE(fact.value(QStringLiteral("currentSeconds")).toInt(), 10800);
    QCOMPARE(fact.value(QStringLiteral("previousSeconds")).toInt(), 7200);
    QCOMPARE(fact.value(QStringLiteral("currentSharePercent")).toDouble(), 75.0);
    QCOMPARE(fact.value(QStringLiteral("deltaPoints")).toDouble(), 25.0);
    // F2 的秒数与同周饼图（getCategoryStats）该科时长同源。
    const QVariantList categories = stats->getCategoryStats(QStringLiteral("2026-07-13"), QStringLiteral("2026-07-19"))
                                        .value(QStringLiteral("categories")).toList();
    QCOMPARE(subjectByName(categories, QStringLiteral("数学")).value(QStringLiteral("duration")).toInt(), 10800);

    // 边界刚好满足：+10 个百分点、+3600 秒。
    QVERIFY(clearFocusSessionsForTest());
    QVERIFY(insertFocusSessionRowWithMode(mathTask, previousDay, 18000, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, previousDay, 18000, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathTask, currentDay, 21600, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, currentDay, 14400, 0));
    fact = shareFact();
    QCOMPARE(fact.value(QStringLiteral("subject")).toString(), QStringLiteral("数学"));
    QCOMPARE(fact.value(QStringLiteral("deltaPoints")).toDouble(), 10.0);

    // 占比变化差一点不到 10 个百分点（投入变化足够）：不输出。
    QVERIFY(clearFocusSessionsForTest());
    QVERIFY(insertFocusSessionRowWithMode(mathTask, previousDay, 36000, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, previousDay, 36000, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathTask, currentDay, 43199, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, currentDay, 28801, 0));
    QVERIFY(shareFact().isEmpty());

    // 两周各 60 分钟，科目占比刚好变 10 个百分点，但只差 6 分钟：小样本不下结论。
    QVERIFY(clearFocusSessionsForTest());
    QVERIFY(insertFocusSessionRowWithMode(mathTask, previousDay, 1800, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, previousDay, 1800, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathTask, currentDay, 2160, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, currentDay, 1440, 0));
    QVERIFY(shareFact().isEmpty());

    // 前一周总投入不足 60 分钟：不比较。
    QVERIFY(clearFocusSessionsForTest());
    QVERIFY(insertFocusSessionRowWithMode(mathTask, previousDay, 1770, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, previousDay, 1770, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathTask, currentDay, 10800, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, currentDay, 3600, 0));
    QVERIFY(shareFact().isEmpty());

    // 前一周为零：不比较。
    QVERIFY(clearFocusSessionsForTest());
    QVERIFY(insertFocusSessionRowWithMode(mathTask, currentDay, 10800, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, currentDay, 3600, 0));
    QVERIFY(shareFact().isEmpty());

    // 只有「未关联任务」满足条件：它参与分母，但不是真实科目，不能被点名。
    QVERIFY(clearFocusSessionsForTest());
    QVERIFY(insertFocusSessionRowWithMode(mathTask, previousDay, 3600, 0));
    QVERIFY(insertFocusSessionRowWithMode(-1, previousDay, 3600, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathTask, currentDay, 3600, 0));
    QVERIFY(insertFocusSessionRowWithMode(-1, currentDay, 14400, 0));
    QVERIFY(shareFact().isEmpty());
    const QVariantList subjects = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"))
                                      .value(QStringLiteral("subjects")).toList();
    QCOMPARE(subjectByName(subjects, QStringLiteral("未关联任务")).value(QStringLiteral("pseudoSubject")).toBool(), true);
    QCOMPARE(subjectByName(subjects, QStringLiteral("数学")).value(QStringLiteral("previousSharePercent")).toDouble(), 50.0);

    // 「未分类」同理。
    QVERIFY(clearFocusSessionsForTest());
    QVERIFY(insertFocusSessionRowWithMode(englishTask, previousDay, 3600, 0));
    QVERIFY(insertFocusSessionRowWithMode(uncategorizedTask, previousDay, 3600, 0));
    QVERIFY(insertFocusSessionRowWithMode(englishTask, currentDay, 3600, 0));
    QVERIFY(insertFocusSessionRowWithMode(uncategorizedTask, currentDay, 14400, 0));
    QVERIFY(shareFact().isEmpty());
}

void ServiceTests::weeklyReviewEstimateFacts()
{
    const QDate weekStart(2026, 7, 13);
    const QDate day(2026, 7, 14);
    StatisticsService* stats = StatisticsService::instance();
    const int mathId = categoryIdByName(QStringLiteral("数学"));
    const int englishId = categoryIdByName(QStringLiteral("英语"));
    const int politicsId = categoryIdByName(QStringLiteral("政治"));

    auto facts = [stats, weekStart]() {
        return stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"))
            .value(QStringLiteral("facts")).toList();
    };

    // 数学 59.98%（短缺 2401 秒）、英语 58.33%（短缺 5000 秒）→ 取短缺最多的英语；
    // 政治计划只有 59 分钟，不够 60 分钟门槛，不参与。
    int math = insertPlannedTask(QStringLiteral("数学"), day, mathId, 100);
    int english = insertPlannedTask(QStringLiteral("英语"), day, englishId, 200);
    QVERIFY(insertPlannedTask(QStringLiteral("政治"), day, politicsId, 59) > 0);
    QVERIFY(insertFocusSessionRowWithMode(math, day, 3599, 0));
    QVERIFY(insertFocusSessionRowWithMode(english, day, 7000, 0));
    QVariantList list = facts();
    QVariantMap shortfall = factOfType(list, QStringLiteral("estimateShortfall"));
    QCOMPARE(shortfall.value(QStringLiteral("subject")).toString(), QStringLiteral("英语"));
    QCOMPARE(shortfall.value(QStringLiteral("plannedMinutes")).toInt(), 200);
    // 展示分钟在对账集合内分配：合计 10599 秒 → 176 分钟，余秒最多的数学补 1 分钟，英语仍是 116。
    QCOMPARE(shortfall.value(QStringLiteral("actualDisplayMinutes")).toInt(), 116);
    QCOMPARE(shortfall.value(QStringLiteral("shortfallDisplayMinutes")).toInt(), 84);
    QVERIFY(factOfType(list, QStringLiteral("estimateOnTrack")).isEmpty());

    // 短缺相同：按名称选数学。
    QVERIFY(clearTasksForTest());
    math = insertPlannedTask(QStringLiteral("数学"), day, mathId, 100);
    english = insertPlannedTask(QStringLiteral("英语"), day, englishId, 100);
    QVERIFY(insertFocusSessionRowWithMode(math, day, 3000, 0));
    QVERIFY(insertFocusSessionRowWithMode(english, day, 3000, 0));
    QCOMPARE(factOfType(facts(), QStringLiteral("estimateShortfall")).value(QStringLiteral("subject")).toString(),
             QStringLiteral("数学"));

    // 刚好 60%：严格小于才算短缺；总体 60% 也不在 85%～115%，没有事实。
    QVERIFY(clearTasksForTest());
    math = insertPlannedTask(QStringLiteral("数学"), day, mathId, 100);
    QVERIFY(insertFocusSessionRowWithMode(math, day, 3600, 0));
    QVERIFY(facts().isEmpty());

    // 85% 与 115% 两个端点算「接近计划」，区间外不算。
    const QList<QPair<int, bool>> onTrackCases = {
        {5100, true}, {6900, true}, {5099, false}, {6901, false}};
    for (const auto& onTrackCase : onTrackCases) {
        QVERIFY(clearTasksForTest());
        math = insertPlannedTask(QStringLiteral("数学"), day, mathId, 100);
        QVERIFY(insertFocusSessionRowWithMode(math, day, onTrackCase.first, 0));
        const QVariantMap onTrack = factOfType(facts(), QStringLiteral("estimateOnTrack"));
        QVERIFY2(onTrack.isEmpty() != onTrackCase.second,
                 qPrintable(QStringLiteral("实际 %1 秒").arg(onTrackCase.first)));
    }

    // 总体 180%、某科 150%：两科都超出自己的计划，不能说任何一科低于计划。
    QVERIFY(clearTasksForTest());
    math = insertPlannedTask(QStringLiteral("数学"), day, mathId, 100);
    english = insertPlannedTask(QStringLiteral("英语"), day, englishId, 100);
    QVERIFY(insertFocusSessionRowWithMode(math, day, 9000, 0));
    QVERIFY(insertFocusSessionRowWithMode(english, day, 12600, 0));
    QVERIFY(facts().isEmpty());

    // 有科目短缺时，即使总投入落在 85%～115%，也不再补一句「接近计划」。
    QVERIFY(clearTasksForTest());
    math = insertPlannedTask(QStringLiteral("数学"), day, mathId, 100);
    english = insertPlannedTask(QStringLiteral("英语"), day, englishId, 400);
    QVERIFY(insertFocusSessionRowWithMode(math, day, 3000, 0));
    QVERIFY(insertFocusSessionRowWithMode(english, day, 24600, 0));
    list = facts();
    QCOMPARE(list.size(), 1);
    QCOMPARE(list.first().toMap().value(QStringLiteral("type")).toString(), QStringLiteral("estimateShortfall"));
}

void ServiceTests::weeklyReviewFactsPriorityAndCurrentWeekSuppression()
{
    const QDate weekStart(2026, 7, 13);
    const QDate previousDay(2026, 7, 7);
    const QDate day(2026, 7, 14);
    StatisticsService* stats = StatisticsService::instance();
    const int mathId = categoryIdByName(QStringLiteral("数学"));
    const int englishId = categoryIdByName(QStringLiteral("英语"));

    // F1：周二目标 480 分钟，实际 240 分钟（50%）。
    QVERIFY(AppSettings::instance()->setDailyFocusGoal(QStringLiteral("2026-07-14"), 480));
    // F2：数学 50% → 75%，+3600 秒。
    const int mathFree = insertPlannedTask(QStringLiteral("数学"), day, mathId, 0);
    const int english = insertPlannedTask(QStringLiteral("英语"), day, englishId, 0);
    QVERIFY(insertFocusSessionRowWithMode(mathFree, previousDay, 7200, 0));
    QVERIFY(insertFocusSessionRowWithMode(english, previousDay, 7200, 0));
    QVERIFY(insertFocusSessionRowWithMode(mathFree, day, 7200, 0));
    QVERIFY(insertFocusSessionRowWithMode(english, day, 3600, 0));
    // F3：数学计划 300 分钟，集合内只投入 3600 秒（20%）。
    const int mathPlanned = insertPlannedTask(QStringLiteral("数学计划"), day, mathId, 300);
    QVERIFY(insertFocusSessionRowWithMode(mathPlanned, day, 3600, 0));

    QVariantMap review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    QVariantList facts = review.value(QStringLiteral("facts")).toList();
    // 三条都命中时按 F1 → F2 → F3 只取前两条。
    QCOMPARE(facts.size(), 2);
    QCOMPARE(facts.at(0).toMap().value(QStringLiteral("type")).toString(), QStringLiteral("goalShortfall"));
    QCOMPARE(facts.at(1).toMap().value(QStringLiteral("type")).toString(), QStringLiteral("subjectShareChange"));

    // 同样的数据，周还没结束：一条事实都不给。
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-16"));
    QVERIFY(review.value(QStringLiteral("facts")).toList().isEmpty());

    // 没有目标、没有计划的历史周，F2 仍可独立出现并撑起卡片。
    clearDailyGoalSettingsForTest();
    QSqlQuery unplan(DatabaseManager::instance()->database());
    QVERIFY(unplan.exec(QStringLiteral("UPDATE tasks SET estimated_minutes = 0")));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    facts = review.value(QStringLiteral("facts")).toList();
    QCOMPARE(facts.size(), 1);
    QCOMPARE(facts.first().toMap().value(QStringLiteral("type")).toString(), QStringLiteral("subjectShareChange"));
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), true);
    QCOMPARE(review.value(QStringLiteral("goal")).toMap().value(QStringLiteral("goalDays")).toInt(), 0);
    QVERIFY(review.value(QStringLiteral("plannedTasks")).toMap().value(QStringLiteral("rows")).toList().isEmpty());
}

void ServiceTests::weeklyReviewErrorsAreReturnedWithoutSignals()
{
    const QDate weekStart(2026, 7, 13);
    StatisticsService* stats = StatisticsService::instance();
    QSignalSpy failures(stats, &StatisticsService::operationFailed);

    // 计划任务查询只读 tasks，会先成功；删掉专注表后，紧接着的专注查询失败。
    // 结果必须整体作废，不能带着已经查到的计划去组装半份统计。
    QVERIFY(insertPlannedTask(QStringLiteral("计划任务"), QDate(2026, 7, 14),
                              categoryIdByName(QStringLiteral("数学")), 60) > 0);
    QVERIFY(AppSettings::instance()->setDailyFocusGoal(QStringLiteral("2026-07-14"), 60));
    QSqlQuery drop(DatabaseManager::instance()->database());
    QVERIFY(drop.exec(QStringLiteral("DROP TABLE focus_sessions")));

    const QVariantMap review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    QCOMPARE(review.value(QStringLiteral("loadState")).toString(), QStringLiteral("error"));
    QVERIFY(!review.value(QStringLiteral("errorMessage")).toString().isEmpty());
    QCOMPARE(review.value(QStringLiteral("periodState")).toString(), QStringLiteral("ended"));
    QCOMPARE(review.value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), false);
    QVERIFY(review.value(QStringLiteral("goal")).toMap().isEmpty());
    QVERIFY(review.value(QStringLiteral("todayGoal")).toMap().isEmpty());
    QVERIFY(review.value(QStringLiteral("plannedTasks")).toMap().isEmpty());
    QVERIFY(review.value(QStringLiteral("subjects")).toList().isEmpty());
    QVERIFY(review.value(QStringLiteral("facts")).toList().isEmpty());
    // 复盘专用查询只通过返回值报错，不发 operationFailed。
    QCOMPARE(failures.count(), 0);

    // 数据库未打开同样只通过返回值报告。
    DatabaseManager::instance()->close();
    const QVariantMap closed = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-20"));
    QCOMPARE(closed.value(QStringLiteral("loadState")).toString(), QStringLiteral("error"));
    QCOMPARE(closed.value(QStringLiteral("errorMessage")).toString(), QStringLiteral("数据库未打开"));
    QCOMPARE(failures.count(), 0);
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath(QStringLiteral("reopened.sqlite"))));
}

void ServiceTests::weeklyReviewContentFlags()
{
    const QDate weekStart(2026, 7, 13);
    StatisticsService* stats = StatisticsService::instance();
    AppSettings* settings = AppSettings::instance();

    // 空周：没有专注、目标、计划。
    QVariantMap review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    QCOMPARE(review.value(QStringLiteral("loadState")).toString(), QStringLiteral("ready"));
    QCOMPARE(review.value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), false);

    // 当前周只有专注记录：有数据，但卡片没有可展示的块。
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 13), 3600, 0));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    QCOMPARE(review.value(QStringLiteral("hasData")).toBool(), true);
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), false);

    // 目标只设在未来日期：不展示，也不撑起卡片。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-16"), 60));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), false);
    QCOMPARE(review.value(QStringLiteral("goal")).toMap().value(QStringLiteral("goalDays")).toInt(), 0);
    QVERIFY(review.value(QStringLiteral("todayGoal")).toMap().isEmpty());

    // 已结束的目标日即使实际为零，也有可展示内容。
    QVERIFY(settings->setDailyFocusGoal(QStringLiteral("2026-07-14"), 60));
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), true);
    QCOMPARE(review.value(QStringLiteral("goal")).toMap().value(QStringLiteral("goalDays")).toInt(), 1);
    QCOMPARE(review.value(QStringLiteral("goal")).toMap().value(QStringLiteral("actualSecondsTotal")).toInt(), 0);

    // 只有计划、实际为零：对账块照样出现。
    clearDailyGoalSettingsForTest();
    QVERIFY(insertPlannedTask(QStringLiteral("只有计划"), QDate(2026, 7, 17),
                              categoryIdByName(QStringLiteral("数学")), 45) > 0);
    review = stats->getWeeklyReview(weekStart, QStringLiteral("2026-07-15"));
    const QVariantList rows =
        review.value(QStringLiteral("plannedTasks")).toMap().value(QStringLiteral("rows")).toList();
    QCOMPARE(rows.size(), 1);
    QCOMPARE(rows.first().toMap().value(QStringLiteral("actualSeconds")).toInt(), 0);
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), true);

    // 已结束周只有专注记录、F2 不成立：卡片同样没有内容。
    QVERIFY(insertFocusSessionRowWithMode(-1, QDate(2026, 7, 7), 3600, 0));
    review = stats->getWeeklyReview(QDate(2026, 7, 6), QStringLiteral("2026-07-20"));
    QCOMPARE(review.value(QStringLiteral("hasData")).toBool(), true);
    QCOMPARE(review.value(QStringLiteral("hasDisplayContent")).toBool(), false);
}

QTEST_MAIN(ServiceTests)
#include "ServiceTests.moc"

void ServiceTests::manualSessionCountsTowardMinutesButNotPomodoros()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    // 这里验证的是补录统计，不是某个固定钟点。锚到当前时刻两小时前，保证全天运行时
    // 结束时间都已经过去；任务日期跟随实际开始时刻的逻辑日，避免跨 4 点边界后日期互相矛盾。
    const QDateTime start = QDateTime::currentDateTime().addSecs(-2 * 60 * 60);
    const QDate sessionDate = LogicalDay::dateOf(start, AppSettings::instance()->dayStartHour());
    const int taskId = insertTaskRow(QStringLiteral("忘了开计时的任务"), sessionDate,
                                     QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    const int sessionId = history->addManualSession(taskId, start, 60);
    QVERIFY2(sessionId > 0, qPrintable(history->lastError()));

    // 计入专注分钟：这正是补录要解决的问题——时间不该因为忘了按开始就消失。
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 60);
    // 但不伪装成番茄：它不是自然到点的番茄段，算进去会污染"有效番茄"口径。
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 0);
}

void ServiceTests::manualSessionRejectsOverlapWithExistingRecord()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    // 最晚一条记录会在基准开始后 90 分钟结束，因此基准放到当前时刻两小时前。
    const QDateTime start = QDateTime::currentDateTime().addSecs(-2 * 60 * 60);
    const QDate sessionDate = LogicalDay::dateOf(start, AppSettings::instance()->dayStartHour());
    const int taskId = insertTaskRow(QStringLiteral("重叠任务"), sessionDate,
                                     QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    QVERIFY(history->addManualSession(taskId, start, 60) > 0);

    // 与既有记录相交的一律拒绝：两条覆盖同一段时间会让统计凭空多出时长，
    // 而且事后无从察觉。
    QCOMPARE(history->addManualSession(taskId, start.addSecs(30 * 60), 60), -1);
    QVERIFY(history->lastError().contains(QStringLiteral("已有专注记录")));
    QCOMPARE(history->addManualSession(taskId, start.addSecs(-30 * 60), 60), -1);

    // 首尾相接不算重叠：第一条结束后立即开始下一条是合法的。
    QVERIFY(history->addManualSession(taskId, start.addSecs(60 * 60), 30) > 0);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 90);
}

void ServiceTests::manualSessionRejectsFutureAndTooShort()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("校验任务"), today, QStringLiteral("数学"));

    // 低于有效门槛（3 分钟）的记录本来就不计入统计，存进去只是噪音。
    QCOMPARE(history->addManualSession(taskId, QDateTime(today, QTime(8, 0)), 2), -1);
    QVERIFY(history->lastError().contains(QStringLiteral("至少")));

    // 结束时间落在未来：补录只能补已经发生的事。
    QCOMPARE(history->addManualSession(taskId, QDateTime::currentDateTime().addSecs(3600), 30), -1);
    QVERIFY(history->lastError().contains(QStringLiteral("不能晚于现在")));

    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 0);
}

void ServiceTests::updateSessionMovesItAndKeepsItsMode()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    const QDateTime now = QDateTime::currentDateTime();
    const QDateTime originalStart = now.addSecs(-3 * 60 * 60);
    const QDate sessionDate = LogicalDay::dateOf(
        originalStart, AppSettings::instance()->dayStartHour());
    const int taskId = insertTaskRow(QStringLiteral("待修改"), sessionDate,
                                     QStringLiteral("数学"));

    // 先造一条真正的番茄记录（番茄模式、自然到点）。这里直接写库而不用既有辅助，
    // 因为需要同时指定 mode 与具体时刻。
    {
        QSqlQuery insert(DatabaseManager::instance()->database());
        insert.prepare(QStringLiteral(
            "INSERT INTO focus_sessions "
            "(task_id, start_time, end_time, duration, mode, pomodoro_completed) "
            "VALUES (:taskId, :start, :end, :duration, 1, 1)"));
        insert.bindValue(QStringLiteral(":taskId"), taskId);
        insert.bindValue(QStringLiteral(":start"),
                         originalStart.toString(Qt::ISODate));
        insert.bindValue(QStringLiteral(":end"),
                         originalStart.addSecs(25 * 60).toString(Qt::ISODate));
        insert.bindValue(QStringLiteral(":duration"), 25 * 60);
        QVERIFY(insert.exec());
    }
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);

    const QVariantList sessions = history->getDaySessions(sessionDate);
    QCOMPARE(sessions.size(), 1);
    const int sessionId = sessions.first().toMap().value(QStringLiteral("id")).toInt();

    // 新结束时间固定落在当前时刻二十分钟前，既覆盖移动逻辑，也不依赖运行当天的钟点。
    QVERIFY2(history->updateSession(sessionId, now.addSecs(-60 * 60), 40),
             qPrintable(history->lastError()));
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 40);
    // 改时长不改性质：它仍然是那次自然到点的番茄，不该因为被编辑过就降级。
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);
}

void ServiceTests::deleteSessionRemovesItAndRollsStatsBack()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    const QDateTime start = QDateTime::currentDateTime().addSecs(-60 * 60);
    const QDate sessionDate = LogicalDay::dateOf(start, AppSettings::instance()->dayStartHour());
    const int taskId = insertTaskRow(QStringLiteral("待删除"), sessionDate,
                                     QStringLiteral("数学"));

    const int sessionId = history->addManualSession(taskId, start, 45);
    QVERIFY(sessionId > 0);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 45);

    QVERIFY2(history->deleteSession(sessionId), qPrintable(history->lastError()));
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 0);
    QCOMPARE(history->getDaySessions(sessionDate).size(), 0);

    // 重复删除要如实失败，不能假装成功。
    QVERIFY(!history->deleteSession(sessionId));
}

void ServiceTests::manualWriteRefusesToTouchRunningSession()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("进行中"), today, QStringLiteral("数学"));

    // 正在进行的会话：end_time 为 NULL。删掉或改掉它会让 FocusTimer 结束时
    // 找不到自己的行，当前这段计时直接丢失。
    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, mode) "
        "VALUES (:taskId, :start, 1)"));
    insert.bindValue(QStringLiteral(":taskId"), taskId);
    insert.bindValue(QStringLiteral(":start"),
                     QDateTime(today, QTime(9, 0)).toString(Qt::ISODate));
    QVERIFY(insert.exec());
    const int runningId = insert.lastInsertId().toInt();

    QVERIFY(!history->deleteSession(runningId));
    QVERIFY(!history->updateSession(runningId, QDateTime(today, QTime(9, 0)), 30));
}

void ServiceTests::notesRoundTripAndRenameDoesNotEraseThem()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();

    QVERIFY(tasks->addTask(QStringLiteral("第九讲复习"), today, -1, 60,
                           QStringLiteral("P.128–P.146，重点看例 3.7")));
    QVariantList rows = tasks->getTodayTasks();
    QCOMPARE(rows.size(), 1);
    const int taskId = rows.first().toMap().value(QStringLiteral("id")).toInt();
    QCOMPARE(rows.first().toMap().value(QStringLiteral("notes")).toString(),
             QStringLiteral("P.128–P.146，重点看例 3.7"));

    // 不带备注的重命名不能把备注抹掉：五参重载传的是 null QString，语义是"保持不变"。
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("第九讲复习（改）"), -1, today, -1));
    rows = tasks->getTodayTasks();
    QCOMPARE(rows.first().toMap().value(QStringLiteral("notes")).toString(),
             QStringLiteral("P.128–P.146，重点看例 3.7"));

    // 显式传空串才是清空。空串与 null 的区别就是"清空"与"不动"的区别。
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("第九讲复习（改）"), -1, today, -1,
                              QString(QLatin1String(""))));
    rows = tasks->getTodayTasks();
    QVERIFY(rows.first().toMap().value(QStringLiteral("notes")).toString().isEmpty());
}

void ServiceTests::overlongNotesAreRejectedInsteadOfTruncated()
{
    // 备注曾被 left(2000) 静默截断，新建和编辑都照常返回成功：用户看到「已保存」，
    // 重新打开才发现末尾没了。知识缺口在 81bdb74 已改成拒绝，任务备注没跟上。
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const QString atLimit(TaskManager::kMaxNotesLength, QLatin1Char('a'));
    const QString overLimit(TaskManager::kMaxNotesLength + 1, QLatin1Char('b'));
    QCOMPARE(tasks->property("maxNotesLength").toInt(), TaskManager::kMaxNotesLength);

    // 上限内存得下，一个字都不少。
    const int taskId = tasks->createTask(QStringLiteral("长备注"), today, -1, 0, atLimit);
    QVERIFY(taskId > 0);
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("notes")).toString(), atLimit);

    // 超一个字就拒绝，而且不能留下任何痕迹。
    QSignalSpy changed(tasks, &TaskManager::tasksChanged);
    QCOMPARE(tasks->createTask(QStringLiteral("超长备注"), today, -1, 0, overLimit), -1);
    QVERIFY(!tasks->addTask(QStringLiteral("超长备注"), today, -1, 0, overLimit));
    QCOMPARE(tasks->getTodayTasks().size(), 1);

    QVERIFY(!tasks->updateTask(taskId, QStringLiteral("改过的标题"), -1, today, 30, overLimit));
    const QVariantMap unchanged = tasks->getTask(taskId);
    QCOMPARE(unchanged.value(QStringLiteral("title")).toString(), QStringLiteral("长备注"));
    QCOMPARE(unchanged.value(QStringLiteral("notes")).toString(), atLimit);
    QCOMPARE(changed.count(), 0);
}

void ServiceTests::completeTaskWithNoteStoresNoteAndCompletesInOneWrite()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const int taskId = tasks->createTask(QStringLiteral("数据结构"), today, -1, 0,
                                         QStringLiteral("第三章习题"));
    QVERIFY(taskId > 0);

    QSignalSpy changed(tasks, &TaskManager::tasksChanged);
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("做完 1–15 题，递归还不熟")));
    QCOMPARE(changed.count(), 1);

    const QVariantMap row = tasks->getTask(taskId);
    QVERIFY(row.value(QStringLiteral("completed")).toBool());
    QCOMPARE(row.value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("做完 1–15 题，递归还不熟"));
    // 完成记录另起一列：做之前写的备注原样还在，两者不能互相覆盖。
    QCOMPARE(row.value(QStringLiteral("notes")).toString(), QStringLiteral("第三章习题"));

    // 今日页的数据源是列表查询，它同样要带出这一列，否则卡片上看不到刚写的记录。
    const QVariantList todayRows = tasks->getTodayTasks();
    QCOMPARE(todayRows.size(), 1);
    QCOMPARE(todayRows.first().toMap().value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("做完 1–15 题，递归还不熟"));

    // 不写记录也能完成。空串和 null QString 都是合法的「没写」，都不能撞上 NOT NULL 约束。
    const int emptyId = tasks->createTask(QStringLiteral("复习单词"), today, -1, 0, QString());
    QVERIFY(tasks->completeTaskWithNote(emptyId, QString(QLatin1String(""))));
    QVERIFY(tasks->getTask(emptyId).value(QStringLiteral("completed")).toBool());
    QVERIFY(tasks->getTask(emptyId).value(QStringLiteral("completionNote")).toString().isEmpty());

    const int nullId = tasks->createTask(QStringLiteral("高等数学"), today, -1, 0, QString());
    QVERIFY(tasks->completeTaskWithNote(nullId, QString()));
    QVERIFY(tasks->getTask(nullId).value(QStringLiteral("completed")).toBool());
    QVERIFY(tasks->getTask(nullId).value(QStringLiteral("completionNote")).toString().isEmpty());
}

void ServiceTests::completionNoteSurvivesUndoAndCanBeRewritten()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const int taskId = tasks->createTask(QStringLiteral("计算机网络"), today, -1, 0, QString());
    QVERIFY(taskId > 0);
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("看完 TCP 三次握手")));

    // 撤销条走的是 setTaskCompleted(false)：只翻回完成态，刚写的记录不能跟着丢。
    QVERIFY(tasks->setTaskCompleted(taskId, false));
    QVariantMap row = tasks->getTask(taskId);
    QVERIFY(!row.value(QStringLiteral("completed")).toBool());
    QCOMPARE(row.value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("看完 TCP 三次握手"));

    // 之后改用复选框快速完成，记录依旧在。
    QVERIFY(tasks->setTaskCompleted(taskId, true));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("看完 TCP 三次握手"));

    // 对已完成任务再次提交等于改写记录，完成态保持不变。
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("看完三次握手和四次挥手")));
    row = tasks->getTask(taskId);
    QVERIFY(row.value(QStringLiteral("completed")).toBool());
    QCOMPARE(row.value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("看完三次握手和四次挥手"));
}

void ServiceTests::overlongCompletionNoteIsRejectedWithoutSideEffects()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const QString atLimit(TaskManager::kMaxNotesLength, QLatin1Char('a'));
    const QString overLimit(TaskManager::kMaxNotesLength + 1, QLatin1Char('b'));

    // 上限内存得下，一个字都不少。
    const int limitId = tasks->createTask(QStringLiteral("上限内"), today, -1, 0, QString());
    QVERIFY(limitId > 0);
    QVERIFY(tasks->completeTaskWithNote(limitId, atLimit));
    QCOMPARE(tasks->getTask(limitId).value(QStringLiteral("completionNote")).toString(), atLimit);

    const int taskId = tasks->createTask(QStringLiteral("超一个字"), today, -1, 0, QString());
    QVERIFY(taskId > 0);
    QSignalSpy changed(tasks, &TaskManager::tasksChanged);

    // 超一个字就拒绝，而且不能留下任何痕迹：既没被标成完成，记录也没写进去。
    QVERIFY(!tasks->completeTaskWithNote(taskId, overLimit));
    const QVariantMap rejected = tasks->getTask(taskId);
    QVERIFY(!rejected.value(QStringLiteral("completed")).toBool());
    QVERIFY(rejected.value(QStringLiteral("completionNote")).toString().isEmpty());

    // 改写已完成任务的记录时超长，原记录同样原样保留。
    QVERIFY(!tasks->completeTaskWithNote(limitId, overLimit));
    QCOMPARE(tasks->getTask(limitId).value(QStringLiteral("completionNote")).toString(), atLimit);

    // 编号无效或任务不存在都返回失败。
    QVERIFY(!tasks->completeTaskWithNote(0, QStringLiteral("x")));
    QVERIFY(!tasks->completeTaskWithNote(-1, QStringLiteral("x")));
    QVERIFY(!tasks->completeTaskWithNote(taskId + 1000, QStringLiteral("x")));
    QCOMPARE(changed.count(), 0);
}

void ServiceTests::editingKeepsCompletionNoteUnlessExplicitlyGiven()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const int taskId = tasks->createTask(QStringLiteral("英语阅读"), today, -1, 30,
                                         QStringLiteral("真题 2019"));
    QVERIFY(taskId > 0);
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("做完 Text 1、2")));

    // 编辑弹窗原有的六参保存、重命名的四参路径都不认识完成记录，不能把它抹掉。
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("英语阅读（改）"), -1, today, 45,
                              QStringLiteral("真题 2020")));
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("英语阅读（再改）"), -1, today));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("做完 Text 1、2"));

    // 外部 AI 接入走 updateTaskFields 的默认参数，同样不碰完成记录。
    QVERIFY(tasks->updateTaskFields(taskId, QString(), -1, today, -1,
                                    QStringLiteral("外部改的备注"), true, true));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("做完 Text 1、2"));

    // 七参重载：QML 传 undefined（无效 QVariant）或 null 都表示保持不变。
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("英语阅读"), -1, today, 45,
                              QStringLiteral("真题 2020"), QVariant()));
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("英语阅读"), -1, today, 45,
                              QStringLiteral("真题 2020"), QVariant::fromValue(nullptr)));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("做完 Text 1、2"));

    // 传了字符串才改写。
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("英语阅读"), -1, today, 45,
                              QStringLiteral("真题 2020"), QVariant(QStringLiteral("做完 Text 1–4"))));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString(),
             QStringLiteral("做完 Text 1–4"));

    // 超长记录让整次保存失败：标题等其它字段也不能落库。
    const QString overLimit(TaskManager::kMaxNotesLength + 1, QLatin1Char('c'));
    QSignalSpy changed(tasks, &TaskManager::tasksChanged);
    QVERIFY(!tasks->updateTask(taskId, QStringLiteral("不该生效的标题"), -1, today, 45,
                               QStringLiteral("真题 2020"), QVariant(overLimit)));
    QCOMPARE(changed.count(), 0);
    QVariantMap row = tasks->getTask(taskId);
    QCOMPARE(row.value(QStringLiteral("title")).toString(), QStringLiteral("英语阅读"));
    QCOMPARE(row.value(QStringLiteral("completionNote")).toString(), QStringLiteral("做完 Text 1–4"));

    // 空串是明确的「清空」。QML 的空串到 C++ 可能是 null QString，两种都必须清空而不是报错。
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("英语阅读"), -1, today, 45,
                              QStringLiteral("真题 2020"), QVariant(QString())));
    row = tasks->getTask(taskId);
    QVERIFY(row.value(QStringLiteral("completionNote")).toString().isEmpty());
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("临时记录")));
    QVERIFY(tasks->updateTask(taskId, QStringLiteral("英语阅读"), -1, today, 45,
                              QStringLiteral("真题 2020"), QVariant(QString(QLatin1String("")))));
    row = tasks->getTask(taskId);
    QVERIFY(row.value(QStringLiteral("completionNote")).toString().isEmpty());
    // 改记录不改完成态。
    QVERIFY(row.value(QStringLiteral("completed")).toBool());
}

void ServiceTests::scriptCallPathKeepsOrWritesCompletionNote()
{
    // 编辑弹窗从 QML 调七参 updateTask：未完成任务传 undefined（保持不变），已完成任务传字符串。
    // 「保持不变」成不成立，取决于脚本引擎怎么在四个 updateTask 重载里挑、怎么把
    // undefined / null / 空串转成 QVariant——上面那条用例直接从 C++ 构造 QVariant，测不到这一层。
    // QJSEngine 调 Q_INVOKABLE 与界面走的是同一套方法调用机制。
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const int taskId = tasks->createTask(QStringLiteral("线性代数"), today, -1, 0, QString());
    QVERIFY(taskId > 0);
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("做完行列式")));

    QJSEngine engine;
    // TaskManager 是进程单例，不能让脚本引擎在析构时顺手把它回收掉。
    QJSEngine::setObjectOwnership(tasks, QJSEngine::CppOwnership);
    engine.globalObject().setProperty(QStringLiteral("taskManager"), engine.newQObject(tasks));
    engine.globalObject().setProperty(QStringLiteral("taskId"), taskId);
    engine.globalObject().setProperty(QStringLiteral("isoDate"), today.toString(Qt::ISODate));

    const auto updateWith = [&engine](const QString& completionArgument, int minutes) {
        const QJSValue result = engine.evaluate(
            QStringLiteral("taskManager.updateTask(taskId, '线性代数', -1, isoDate, %1, '第二章', %2)")
                .arg(minutes)
                .arg(completionArgument));
        if (result.isError()) {
            qWarning() << "脚本调用失败:" << result.toString();
        }
        return result.toBool();
    };
    const auto completionNote = [tasks, taskId]() {
        return tasks->getTask(taskId).value(QStringLiteral("completionNote")).toString();
    };

    // undefined：编辑未完成任务时的真实传参。记录不动，其它字段照常写入。
    QVERIFY(updateWith(QStringLiteral("undefined"), 30));
    QCOMPARE(completionNote(), QStringLiteral("做完行列式"));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("estimatedMinutes")).toInt(), 30);
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("notes")).toString(), QStringLiteral("第二章"));

    QVERIFY(updateWith(QStringLiteral("null"), 35));
    QCOMPARE(completionNote(), QStringLiteral("做完行列式"));

    // 字符串才改写。若引擎挑中了六参重载，这一步会静默丢掉新记录。
    QVERIFY(updateWith(QStringLiteral("'做完行列式和矩阵'"), 40));
    QCOMPARE(completionNote(), QStringLiteral("做完行列式和矩阵"));
    QCOMPARE(tasks->getTask(taskId).value(QStringLiteral("estimatedMinutes")).toInt(), 40);

    // 空串是清空，不能被当成「没传」，也不能撞上 NOT NULL 约束。
    QVERIFY(updateWith(QStringLiteral("''"), 40));
    QVERIFY(completionNote().isEmpty());

    // 完成弹窗入口：脚本传空串同样合法。
    QVERIFY(tasks->setTaskCompleted(taskId, false));
    const QJSValue completed = engine.evaluate(QStringLiteral("taskManager.completeTaskWithNote(taskId, '')"));
    QVERIFY2(!completed.isError(), qPrintable(completed.toString()));
    QVERIFY(completed.toBool());
    QVERIFY(tasks->getTask(taskId).value(QStringLiteral("completed")).toBool());
}

void ServiceTests::duplicateTaskDoesNotInheritCompletionNote()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const int taskId = tasks->createTask(QStringLiteral("政治选择题"), today, -1, 0,
                                         QStringLiteral("1000 题第一章"));
    QVERIFY(taskId > 0);
    QVERIFY(tasks->completeTaskWithNote(taskId, QStringLiteral("做完马原前 40 题")));

    QVERIFY(tasks->duplicateTask(taskId, today.addDays(1)));
    const QVariantList copies = tasks->getTasksByDate(today.addDays(1));
    QCOMPARE(copies.size(), 1);
    const QVariantMap copy = copies.first().toMap();
    // 复制的是「要做什么」，不是「做完了什么」：新任务未完成，也不带完成记录。
    QVERIFY(!copy.value(QStringLiteral("completed")).toBool());
    QVERIFY(copy.value(QStringLiteral("completionNote")).toString().isEmpty());
    QCOMPARE(copy.value(QStringLiteral("notes")).toString(), QStringLiteral("1000 题第一章"));
}

void ServiceTests::mixedLegacyOrdersKeepNewTasksAtEnd()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();

    QVERIFY(insertTaskRow(QStringLiteral("旧任务甲"), today) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("旧任务乙"), today) > 0);
    QVERIFY(tasks->addTask(QStringLiteral("新任务"), today, -1, 0));

    QCOMPARE(taskTitles(tasks->getTasksByDate(today)),
             QStringList({QStringLiteral("旧任务甲"),
                          QStringLiteral("旧任务乙"),
                          QStringLiteral("新任务")}));
}

void ServiceTests::allTaskDateWritesAppendAfterLegacyRows()
{
    TaskManager* tasks = TaskManager::instance();
    RoutineManager* routines = RoutineManager::instance();
    const QDate today = logicalToday();

    QVERIFY(insertTaskRow(QStringLiteral("目标旧任务甲"), today) > 0);
    QVERIFY(insertTaskRow(QStringLiteral("目标旧任务乙"), today) > 0);
    QVERIFY(tasks->addTask(QStringLiteral("文本科目新增"), today, QStringLiteral("数学")));
    QVERIFY(tasks->addTask(QStringLiteral("编号科目新增"), today, -1, 0));
    QVERIFY(routines->addRoutine(QStringLiteral("例行新增"), -1));
    QCOMPARE(routines->materializeToday(), 1);
    const int editedId = insertTaskRow(QStringLiteral("编辑改期"), today.addDays(-3));
    const int movedId = insertTaskRow(QStringLiteral("单项改期"), today.addDays(-2));
    const int rolledId = insertTaskRow(QStringLiteral("批量结转"), today.addDays(-1));
    QVERIFY(editedId > 0);
    QVERIFY(movedId > 0);
    QVERIFY(rolledId > 0);

    QVERIFY(tasks->updateTask(editedId, QStringLiteral("编辑改期"), -1, today));
    QVERIFY(tasks->moveTaskToDate(movedId, today));
    QVERIFY(tasks->moveTasksToToday(QVariantList{rolledId}));

    const QVariantList rows = tasks->getTasksByDate(today);
    QCOMPARE(taskTitles(rows),
             QStringList({QStringLiteral("目标旧任务甲"),
                          QStringLiteral("目标旧任务乙"),
                          QStringLiteral("文本科目新增"),
                          QStringLiteral("编号科目新增"),
                          QStringLiteral("例行新增"),
                          QStringLiteral("编辑改期"),
                          QStringLiteral("单项改期"),
                          QStringLiteral("批量结转")}));

    QSet<int> positiveOrders;
    for (const QVariant& rowValue : rows) {
        const QVariantMap row = rowValue.toMap();
        if (row.value(QStringLiteral("title")).toString().startsWith(QStringLiteral("目标旧任务"))) {
            continue;
        }
        const int order = row.value(QStringLiteral("displayOrder")).toInt();
        QVERIFY(order > 0);
        QVERIFY(!positiveOrders.contains(order));
        positiveOrders.insert(order);
    }
    QCOMPARE(positiveOrders.size(), 6);
}

void ServiceTests::reorderTasksPutsManualOrderFirstAndKeepsUnsortedByCreation()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();

    QVERIFY(tasks->addTask(QStringLiteral("甲"), today, -1, 0));
    QVERIFY(tasks->addTask(QStringLiteral("乙"), today, -1, 0));
    QVERIFY(tasks->addTask(QStringLiteral("丙"), today, -1, 0));

    QVariantList rows = tasks->getTodayTasks();
    QCOMPARE(rows.size(), 3);
    // 新任务按创建顺序落在末尾，与改版前一致。
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("甲"));
    QCOMPARE(rows.at(2).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("丙"));

    const int first = rows.at(0).toMap().value(QStringLiteral("id")).toInt();
    const int second = rows.at(1).toMap().value(QStringLiteral("id")).toInt();
    const int third = rows.at(2).toMap().value(QStringLiteral("id")).toInt();

    // 把丙拖到最前。
    QVERIFY(tasks->reorderTasks(today, QVariantList{ third, first, second }));
    rows = tasks->getTodayTasks();
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("丙"));
    QCOMPARE(rows.at(1).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("甲"));
    QCOMPARE(rows.at(2).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("乙"));

    // 排过序之后再建的任务落到末尾，不会插进已排好的序列中间。
    QVERIFY(tasks->addTask(QStringLiteral("丁"), today, -1, 0));
    rows = tasks->getTodayTasks();
    QCOMPARE(rows.at(3).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("丁"));
}

void ServiceTests::reorderTasksRejectsInvalidSetsAtomically()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate date = logicalToday();
    QVERIFY(tasks->addTask(QStringLiteral("甲"), date, -1, 0));
    QVERIFY(tasks->addTask(QStringLiteral("乙"), date, -1, 0));
    QVERIFY(tasks->addTask(QStringLiteral("丙"), date, -1, 0));
    QVERIFY(tasks->addTask(QStringLiteral("跨日"), date.addDays(1), -1, 0));

    const QVariantList todayRows = tasks->getTasksByDate(date);
    const int first = todayRows.at(0).toMap().value(QStringLiteral("id")).toInt();
    const int second = todayRows.at(1).toMap().value(QStringLiteral("id")).toInt();
    const int third = todayRows.at(2).toMap().value(QStringLiteral("id")).toInt();
    const int otherDateId = tasks->getTasksByDate(date.addDays(1)).first().toMap()
                                .value(QStringLiteral("id")).toInt();

    auto readAllOrders = [&]() {
        QList<QPair<int, int>> rows;
        QSqlQuery query(DatabaseManager::instance()->database());
        if (!query.exec(QStringLiteral(
                "SELECT id, display_order FROM tasks ORDER BY id ASC"))) {
            return rows;
        }
        while (query.next()) {
            rows.append({query.value(0).toInt(), query.value(1).toInt()});
        }
        return rows;
    };

    const QList<QPair<int, int>> original = readAllOrders();
    QSignalSpy changedSpy(tasks, &TaskManager::tasksChanged);
    const QList<QVariantList> rejectedOrders{
        QVariantList{first, first, third},
        QVariantList{first, second},
        QVariantList{first, second, third, 999999},
        QVariantList{first, second, third, otherDateId}
    };
    for (const QVariantList& order : rejectedOrders) {
        QVERIFY(!tasks->reorderTasks(date, order));
        QCOMPARE(readAllOrders(), original);
        QCOMPARE(changedSpy.count(), 0);
    }
}

void ServiceTests::moveTaskToDateLandsAtTheEndOfTheTargetDay()
{
    TaskManager* tasks = TaskManager::instance();
    const QDate today = logicalToday();
    const QDate tomorrow = today.addDays(1);

    QVERIFY(tasks->addTask(QStringLiteral("明天甲"), tomorrow, -1, 0));
    QVERIFY(tasks->addTask(QStringLiteral("明天乙"), tomorrow, -1, 0));
    QVERIFY(tasks->addTask(QStringLiteral("今天要挪走的"), today, -1, 0));

    const int movingId = tasks->getTodayTasks().first().toMap()
                              .value(QStringLiteral("id")).toInt();
    QVERIFY(tasks->moveTaskToDate(movingId, tomorrow));

    QCOMPARE(tasks->getTodayTasks().size(), 0);
    const QVariantList moved = tasks->getTasksByDate(tomorrow);
    QCOMPARE(moved.size(), 3);
    // 落在目标日期末尾：插到中间会打乱那天已经排好的顺序。
    QCOMPARE(moved.at(2).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("今天要挪走的"));
    // 而且要拿到一个真实的序号，不能是 0。0 表示"没排过"，虽然同样排在末尾，
    // 但之后新建的任务会拿到 max+1 并插到它前面——挪进来的任务会莫名其妙往上跳。
    QVERIFY(moved.at(2).toMap().value(QStringLiteral("displayOrder")).toInt() > 0);

    QVERIFY(tasks->addTask(QStringLiteral("挪完之后新建的"), tomorrow, -1, 0));
    const QVariantList afterAdd = tasks->getTasksByDate(tomorrow);
    QCOMPARE(afterAdd.at(2).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("今天要挪走的"));
    QCOMPARE(afterAdd.at(3).toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("挪完之后新建的"));

    // 不存在的任务要如实失败。
    QVERIFY(!tasks->moveTaskToDate(999999, tomorrow));
}

void ServiceTests::manualSessionRejectsOverlapWithRunningSession()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("进行中重叠"), today, QStringLiteral("数学"));

    // 一段正在进行的会话：end_time 为 NULL，它占用的是 [start, 现在]。
    QSqlQuery insert(DatabaseManager::instance()->database());
    insert.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, mode) VALUES (:taskId, :start, 1)"));
    insert.bindValue(QStringLiteral(":taskId"), taskId);
    insert.bindValue(QStringLiteral(":start"),
                     QDateTime::currentDateTime().addSecs(-3600).toString(Qt::ISODate));
    QVERIFY(insert.exec());

    // 在这段时间里补录必须被拒。放过去的话，等这次专注结束写入 end_time，
    // 库里就有两条覆盖同一段时间的记录——正是重叠守卫要防的事，只是延后发生。
    QCOMPARE(history->addManualSession(taskId,
                                       QDateTime::currentDateTime().addSecs(-1800), 20), -1);
    QVERIFY2(history->lastError().contains(QStringLiteral("已有专注记录")),
             qPrintable(history->lastError()));

    // 正在进行的那段**之前**不受影响，照常可以补。
    QVERIFY(history->addManualSession(taskId,
                                      QDateTime::currentDateTime().addSecs(-7200), 30) > 0);
}

void ServiceTests::everySettingTheAppWritesPassesTheOwnershipFilter()
{
    // 自维护守卫：把应用真实写得出来的设置全写一遍，再逐个问过滤器。
    // 新增一个分组却忘了加进 ownedSettingGroups()，这条会当场转红——
    // 否则那个分组的设置会在恢复备份时被静默丢掉，而用户只会发现"某项没回来"。
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString iniPath = dir.filePath(QStringLiteral("ownership.ini"));

    {
        AppSettings settings(iniPath);
        settings.setLastMode(1);
        settings.setWorkMinutes(30);
        settings.setBreakMinutes(7);
        settings.setFreeTimerWarningHours(3);
        settings.setSoundEnabled(false);
        settings.setReduceMotion(true);
        settings.setSlimClockFont(true);
        settings.setBackgroundTheme(QStringLiteral("starry"));
        settings.setDayStartHour(5);
        settings.setNickname(QStringLiteral("同学"));
        settings.setSidebarVisible(false);
        settings.setDashboardTimerVisible(false);
        settings.setReduceTransparency(true);
        settings.setRaiseOnPhaseComplete(false);
        settings.setCloseToTray(true);
        settings.setCloseToTrayHintShown(true);
        settings.setNaturalCompletionNoticeShown(true);
        settings.setAutoStartBreak(true);
        settings.setAutoStartNextPomodoro(true);
        settings.setLongBreakEnabled(false);
        settings.setLongBreakMinutes(20);
        settings.setLongBreakInterval(3);
        settings.setRolloverIgnoredDate(QStringLiteral("2026-08-11"));
        settings.setDailyFocusGoal(QStringLiteral("2026-08-11"), 180);
        // 动态键：每个动作一条，正是扁平白名单会漏掉的那类。
        settings.setShortcutOverride(QStringLiteral("focus.start"), QStringLiteral("Ctrl+Return"));
    }

    QSettings written(iniPath, QSettings::IniFormat);
    const QStringList keys = written.allKeys();
    QVERIFY2(keys.size() >= 25, qPrintable(QStringLiteral("只写出了 %1 个键，用例没覆盖到足够设置")
                                               .arg(keys.size())));
    for (const QString& key : keys) {
        QVERIFY2(AppSettings::isOwnedSettingKey(key),
                 qPrintable(QStringLiteral("键 %1 不被 ownedSettingGroups() 认领，"
                                           "恢复备份时会被丢掉").arg(key)));
    }
}

void ServiceTests::ownershipFilterRejectsForeignKeysAndKeepsShortcutOverrides()
{
    // 陌生键一律不认。
    QVERIFY(!AppSettings::isOwnedSettingKey(QStringLiteral("evil/payload")));
    QVERIFY(!AppSettings::isOwnedSettingKey(QStringLiteral("NSGlobalDomain")));
    QVERIFY(!AppSettings::isOwnedSettingKey(QString()));
    // 没有分组的裸键同样不认——本应用所有键都带分组。
    QVERIFY(!AppSettings::isOwnedSettingKey(QStringLiteral("nickname")));

    // 快捷键覆盖必须通过：它是动态键，扁平白名单会把用户改过的键位全丢掉，
    // 那比不过滤更糟。
    QVERIFY(AppSettings::isOwnedSettingKey(QStringLiteral("shortcuts/focus.start")));
    QVERIFY(AppSettings::isOwnedSettingKey(QStringLiteral("shortcuts/任意未来动作")));
}

void ServiceTests::asyncExportRunsOffTheCallingThreadAndReportsCompletion()
{
    // 同步导出会把 GUI 线程占住：实测 2 万行专注记录约 190ms，掉十来帧，
    // 而且那段时间进度条根本渲染不出来。异步版必须真的不在调用线程上跑完。
    const QDate day(2026, 6, 10);
    const int taskId = insertTaskRow(QStringLiteral("导出任务"), day, QStringLiteral("数学"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRow(taskId, day, 25 * 60));

    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString filePath = dir.filePath(QStringLiteral("async.csv"));

    ExportService* service = ExportService::instance();
    QSignalSpy completed(service, &ExportService::exportCompleted);
    QVERIFY(completed.isValid());

    // Qt 要求 removeDatabase 前销毁该连接的全部句柄。把这条运行时警告升级为测试失败，
    // 避免异步导出表面成功、实际留下悬空连接或让尚未销毁的查询失效。
    QTest::failOnWarning(QRegularExpression(
        QStringLiteral(".*QSqlDatabasePrivate::removeDatabase: connection .* is still in use.*")));

    service->requestExportFocusSessions(day, day, filePath);
    // 请求返回时活儿还没干完——这正是"没有占住调用线程"的证据。
    QCOMPARE(completed.count(), 0);
    QVERIFY(service->busy());

    QVERIFY2(completed.wait(10000), "异步导出没有在超时内完成");
    QCOMPARE(completed.count(), 1);
    QCOMPARE(completed.first().at(0).toBool(), true);
    QVERIFY(QFileInfo::exists(filePath));
    // busy 必须放回去，否则下一次导出会被自己挡住。
    QTRY_VERIFY(!service->busy());

    // 文件内容与同步版一致：换线程不该改变输出。
    const QString content = readUtf8File(filePath);
    QVERIFY(content.startsWith(QStringLiteral("ID,任务ID,任务标题,科目")));
    QVERIFY(content.count(QLatin1Char('\n')) >= 2);
}

void ServiceTests::partialSessionEditPreservesPrecisionAndPause()
{
    auto* history = FocusHistoryService::instance();
    const QDateTime start = QDateTime::currentDateTime().addDays(-2);
    const int id = history->addManualSession(-1, start, 60);
    QVERIFY(id > 0);
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("UPDATE focus_sessions SET start_time = :start, end_time = :end, duration = 1859 WHERE id = :id"));
    query.bindValue(":start", start.toString(Qt::ISODateWithMs));
    query.bindValue(":end", start.addSecs(4000).toString(Qt::ISODateWithMs));
    query.bindValue(":id", id);
    QVERIFY(query.exec());
    QVERIFY(history->updateSessionFields(id, {}));
    QVERIFY(history->updateSessionFields(id, {{QStringLiteral("startTime"), start.addSecs(3600)}}));
    query.prepare(QStringLiteral("SELECT start_time, end_time, duration FROM focus_sessions WHERE id = :id"));
    query.bindValue(":id", id);
    QVERIFY(query.exec() && query.next());
    QCOMPARE(QDateTime::fromString(query.value(0).toString(), Qt::ISODate), start.addSecs(3600));
    QCOMPARE(QDateTime::fromString(query.value(1).toString(), Qt::ISODate), start.addSecs(7600));
    QCOMPARE(query.value(2).toInt(), 1859);
    // 同一秒内的最后 1 毫秒也属于原记录；恰好相邻才允许新增，落库不能截掉毫秒。
    const QDateTime boundary = start.addSecs(7600);
    QCOMPARE(history->addManualSession(-1, boundary.addMSecs(-1), 3), -1);
    const int adjacent = history->addManualSession(-1, boundary, 3);
    QVERIFY(adjacent > 0);
    query.prepare(QStringLiteral("SELECT start_time FROM focus_sessions WHERE id = :id"));
    query.bindValue(":id", adjacent);
    QVERIFY(query.exec() && query.next());
    QCOMPARE(QDateTime::fromString(query.value(0).toString(), Qt::ISODate), boundary);
    QVERIFY(!history->updateSessionFields(id, {{QStringLiteral("durationSeconds"), 100}}));
    QVERIFY(!history->updateSessionFields(id, {{QStringLiteral("startTime"), QDateTime::currentDateTime().addDays(1)}}));
}

void ServiceTests::timelineRecordCorrectionKeepsIdentityAndRollsBack()
{
    auto* history = FocusHistoryService::instance();
    const QDateTime start = QDateTime::currentDateTime().addDays(-3);
    const int firstTask = insertTaskRow(QStringLiteral("原任务"), start.date(), QStringLiteral("数学"));
    const int secondTask = insertTaskRow(QStringLiteral("新任务"), start.date(), QStringLiteral("英语"));
    const int id = history->addManualSession(firstTask, start, 30);
    QVERIFY(id > 0);
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral("UPDATE focus_sessions SET mode = 1, pomodoro_completed = 1")));
    QVERIFY(history->updateSessionFields(id, {{QStringLiteral("taskId"), secondTask}}));
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(secondTask), 1);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(firstTask), 0);
    // 转换在删除原记录时失败，新增休息也必须回滚。
    QVERIFY(query.exec(QStringLiteral("CREATE TRIGGER reject_conversion BEFORE DELETE ON focus_sessions BEGIN SELECT RAISE(ABORT, 'test'); END")));
    QVERIFY(!history->updateSessionFields(id, {{QStringLiteral("isRest"), true}}));
    QVERIFY(query.exec(QStringLiteral("SELECT COUNT(*) FROM rest_sessions")) && query.next());
    QCOMPARE(query.value(0).toInt(), 0);
    QVERIFY(query.exec(QStringLiteral("DROP TRIGGER reject_conversion")));
    QVERIFY(history->updateSessionFields(id, {{QStringLiteral("isRest"), true}}));
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(secondTask), 0);
    QCOMPARE(history->addManualSession(firstTask, start, 30), -1);
    QVERIFY(history->lastError().contains(QStringLiteral("休息")));
    QVERIFY(query.exec(QStringLiteral("SELECT id FROM rest_sessions")) && query.next());
    const int restId = query.value(0).toInt();
    QVERIFY(history->updateRestSessionFields(restId, {{QStringLiteral("isRest"), false}, {QStringLiteral("taskId"), firstTask}}));
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(firstTask), 30);
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(firstTask), 0);
}

void ServiceTests::restOccupiesOnlyItsMeasuredDuration()
{
    auto* history = FocusHistoryService::instance();
    QSqlQuery query(DatabaseManager::instance()->database());
    const QDateTime restStart = QDateTime::currentDateTime().addDays(-1).addSecs(-6 * 3600);
    // 暂停后忘了结束：区间横跨 6 小时，真正休息只有 5 分钟。
    query.prepare(QStringLiteral(
        "INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
        "VALUES (:start, :end, 300, 1)"));
    query.bindValue(QStringLiteral(":start"), restStart.toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":end"), restStart.addSecs(6 * 3600).toString(Qt::ISODateWithMs));
    QVERIFY(query.exec());

    // 落在区间里、但在有效休息时长之后：这段时间用户其实在学习，必须允许补录。
    QVERIFY(history->addManualSession(-1, restStart.addSecs(3600), 30) > 0);
    // 真正压在休息上的补录仍要挡住。
    QCOMPARE(history->addManualSession(-1, restStart.addSecs(60), 30), -1);
    QVERIFY(history->lastError().contains(QStringLiteral("休息")));

    // 进行中的休息同样按已计秒数占用：暂停 5 小时不该锁死之后的整段时间。
    QVERIFY(query.exec(QStringLiteral("DELETE FROM rest_sessions")));
    const QDateTime activeStart = QDateTime::currentDateTime().addSecs(-5 * 3600);
    query.prepare(QStringLiteral(
        "INSERT INTO active_focus_state (singleton_id, elapsed_seconds, mode, phase, target_seconds, "
        "completed_pomodoros, updated_at, start_time) "
        "VALUES (1, 120, 2, 3, 0, 0, :updatedAt, :startTime)"));
    query.bindValue(QStringLiteral(":updatedAt"), QDateTime::currentDateTime().toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":startTime"), activeStart.toString(Qt::ISODateWithMs));
    QVERIFY(query.exec());
    QVERIFY(history->addManualSession(-1, activeStart.addSecs(3600), 30) > 0);
    QCOMPARE(history->addManualSession(-1, activeStart.addSecs(30), 30), -1);
    QVERIFY(history->lastError().contains(QStringLiteral("正在进行的休息")));
}

void ServiceTests::attributionOnlyEditSkipsOverlapCheck()
{
    auto* history = FocusHistoryService::instance();
    const QDate day = QDate::currentDate().addDays(-2);
    const int firstTask = insertTaskRow(QStringLiteral("原任务"), day, QStringLiteral("数学"));
    const int secondTask = insertTaskRow(QStringLiteral("新任务"), day, QStringLiteral("英语"));
    const QDateTime start = QDateTime(day, QTime(9, 0));
    const int id = history->addManualSession(firstTask, start, 30);
    QVERIFY(id > 0);

    // 绕过服务层插入一条重叠记录，模拟旧数据或系统改钟留下的历史重叠。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, pomodoro_completed) "
        "VALUES (NULL, :start, :end, 1800, 0, 0)"));
    query.bindValue(QStringLiteral(":start"), start.addSecs(600).toString(Qt::ISODateWithMs));
    query.bindValue(QStringLiteral(":end"), start.addSecs(2400).toString(Qt::ISODateWithMs));
    QVERIFY(query.exec());

    // 区间没动，只改归属：不能被历史遗留的重叠挡住，否则连纠正归属都做不到。
    QVERIFY(history->updateSessionFields(id, {{QStringLiteral("taskId"), secondTask}}));
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(secondTask), 30);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(firstTask), 0);

    // 一旦真的改动时间，重叠校验照常生效。
    QVERIFY(!history->updateSessionFields(id, {{QStringLiteral("startTime"), start.addSecs(300)}}));
    QVERIFY(history->lastError().contains(QStringLiteral("已有专注记录")));
}

void ServiceTests::taskOptionsPreferSelectedDateAndAreCapped()
{
    auto* history = FocusHistoryService::instance();
    const QDate target(2026, 6, 15);
    insertTaskRow(QStringLiteral("当天任务"), target);
    insertTaskRow(QStringLiteral("前一天任务"), target.addDays(-1));
    insertTaskRow(QStringLiteral("很久以后的任务"), target.addDays(200));

    const QVariantList options = history->getTaskOptions(target);
    QCOMPARE(options.size(), 3);
    QVERIFY(options.first().toMap().value(QStringLiteral("title")).toString()
                .startsWith(QStringLiteral("当天任务")));
    QVERIFY(options.last().toMap().value(QStringLiteral("title")).toString()
                .startsWith(QStringLiteral("很久以后的任务")));

    // 上限保护：任务攒了几年之后，下拉不能退化成整库任务。
    QSqlQuery query(DatabaseManager::instance()->database());
    QVERIFY(query.exec(QStringLiteral(
        "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 260) "
        "INSERT INTO tasks (title, date, completed, created_at) "
        "SELECT '批量' || n, date('2026-06-15', '-' || n || ' days'), 0, '2026-06-15T09:00:00' FROM seq")));
    QCOMPARE(history->getTaskOptions(target).size(), FocusHistoryService::kTaskOptionLimit);
    // 就近排序不因数量变化而失效：当天任务仍排在最前。
    QVERIFY(history->getTaskOptions(target).first().toMap().value(QStringLiteral("title")).toString()
                .startsWith(QStringLiteral("当天任务")));
}

void ServiceTests::exportNeutralizesFormulaPrefixesAndWritesBom()
{
    const QDate day(2026, 6, 10);
    for (const QString& title : {QStringLiteral("=1+1"), QStringLiteral(" +SUM(1)"),
                                 QStringLiteral("-1+2"), QStringLiteral("@SUM(1)"),
                                 QStringLiteral("\t=1+1")}) {
        QVERIFY(insertTaskRowWithCategoryId(title, day, -1, QStringLiteral("=2+2"), false,
                                           QStringLiteral("2026-06-10T08:00:00")) > 0);
    }
    const QString path = m_tempDir->filePath(QStringLiteral("safe-export.csv"));
    QVERIFY(ExportService::instance()->exportTasks(day, day, path));
    QFile file(path);
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QByteArray bytes = file.readAll();
    QVERIFY(bytes.startsWith(QByteArray::fromHex("efbbbf")));
    const QString csv = QString::fromUtf8(bytes);
    QVERIFY(csv.contains(QStringLiteral(",'=1+1,'=2+2,")));
    QVERIFY(csv.contains(QStringLiteral(",' +SUM(1),")));
    QVERIFY(csv.contains(QStringLiteral(",'-1+2,")));
    QVERIFY(csv.contains(QStringLiteral(",'@SUM(1),")));
    QVERIFY(csv.contains(QStringLiteral(",'\t=1+1,")));
}

void ServiceTests::weeklySubjectMinutesAddUpToTotal()
{
    // 分钟分配规则迁移到预计用时对账：各行展示分钟之和必须等于对账合计。
    const QDate monday(2026, 7, 13);
    const int mathTask = insertPlannedTask(QStringLiteral("数学余秒"), monday,
                                         categoryIdByName(QStringLiteral("数学")), 10);
    const int politicsTask = insertPlannedTask(QStringLiteral("政治余秒"), monday,
                                             categoryIdByName(QStringLiteral("政治")), 10);
    QVERIFY(mathTask > 0 && politicsTask > 0);
    QVERIFY(insertFocusSessionRowWithMode(mathTask, monday, 211, 0));
    QVERIFY(insertFocusSessionRowWithMode(politicsTask, monday, 230, 0));
    const QVariantMap review =
        StatisticsService::instance()->getWeeklyReview(monday, QStringLiteral("2026-07-20"));
    const QVariantMap planned = review.value(QStringLiteral("plannedTasks")).toMap();
    const QVariantList rows = planned.value(QStringLiteral("rows")).toList();
    int sum = 0;
    for (const QVariant& row : rows)
        sum += row.toMap().value(QStringLiteral("actualDisplayMinutes")).toInt();
    // 211 + 230 = 441 秒 → 合计 7 分钟；各行向下取整只有 3 + 3，余秒多的政治（50 秒）补 1 分钟。
    QCOMPARE(sum, 7);
    QCOMPARE(sum, planned.value(QStringLiteral("totalActualDisplayMinutes")).toInt());
    QCOMPARE(rowBySubject(rows, QStringLiteral("政治")).value(QStringLiteral("actualDisplayMinutes")).toInt(), 4);
    QCOMPARE(rowBySubject(rows, QStringLiteral("数学")).value(QStringLiteral("actualDisplayMinutes")).toInt(), 3);
    // 差额按展示分钟算（3 − 10），比例仍按原始秒数（211 / 600）。
    QCOMPARE(rowBySubject(rows, QStringLiteral("数学")).value(QStringLiteral("differenceDisplayMinutes")).toInt(), -7);
    QCOMPARE(rowBySubject(rows, QStringLiteral("数学")).value(QStringLiteral("investmentRatioPercent")).toDouble(),
             211.0 * 100.0 / 600.0);
    // 整体科目不做分配，保留原始秒数，与饼图逐项取整同源。
    QCOMPARE(subjectByName(review.value(QStringLiteral("subjects")).toList(), QStringLiteral("政治"))
                 .value(QStringLiteral("currentSeconds")).toInt(),
             230);
}
