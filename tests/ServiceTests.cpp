#include <QCoreApplication>
#include <QDate>
#include <QDir>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSignalSpy>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTimeZone>
#include <QTimer>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/LogicalDayService.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/ExportService.h"
#include "../src/services/FocusHistoryService.h"
// FocusTimer 声明了 friend class ServiceTests，测试可直接访问内部时钟状态。
#include "../src/services/FocusTimer.h"
#include "../src/services/GoalService.h"
#include "../src/services/MonotonicClock.h"
#include "../src/services/RoutineManager.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/TaskManager.h"

namespace {
constexpr int kTestMinimumValidDurationSeconds = 3 * 60;

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

QDate mondayOf(const QDate& anchor)
{
    return anchor.addDays(1 - anchor.dayOfWeek());
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
    void appSettingsSidebarVisibleRoundTrip();
    void appSettingsDashboardTimerVisibleRoundTrip();
    void appSettingsGoalViewModeNormalizesAndRoundTrips();
    void appSettingsBackgroundThemeDefaultAndRoundTrip();
    void appSettingsDayStartHourNormalizeAndPersist();
    void appSettingsDayStartHourRejectsCorruptIniValue();
    void appSettingsFocusDurationsNormalizeCorruptValues();
    void appSettingsFreeTimerWarningHoursDefaultsAndNormalizes();
    void appSettingsWriteFailureDoesNotEmitSuccess();
    void appSettingsCanRetryAfterWriteFailure();
    void appSettingsReduceTransparencyRoundTrip();
    void appSettingsRaiseOnPhaseCompleteDefaultsOnAndRoundTrips();
    void appSettingsCloseToTrayDefaultsOffAndRoundTrips();
    void appSettingsNaturalCompletionNoticeRoundTripsAndReloads();
    void appSettingsAutoStartDefaultsOffAndRoundTrips();
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
    void deleteSessionRemovesItAndRollsStatsBack();
    void manualWriteRefusesToTouchRunningSession();
    void notesRoundTripAndRenameDoesNotEraseThem();
    void reorderTasksPutsManualOrderFirstAndKeepsUnsortedByCreation();
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
    void getDayTaskStatsGroupsUnassignedFocus();
    void getDayTaskStatsPomodoroCountUsesValidRule();
    void getDayTaskStatsRespectsLogicalDayAndEmptyDate();
    void routinesTableExistsAfterInitialize();
    void databaseReinitializeEmitsRoutineChangeOnce();
    void version2MigrationAddsRoutinesSchemaAndIndex();
    void routinesCategoryForeignKeyClearsWhenCategoryDeleted();
    void routineCrudAddsGetsUpdatesDeletes();
    void deletingMaterializedRoutineDetachesExistingTask();
    void databaseCloseRemovesNamedConnection();
    void databaseOpenedExistingFlagTracksSuccessfulStartupOnly();
    void materializeTodayIsIdempotentAndDoesNotBackfill();
    void materializeTodayPreservesCategoryAndDoesNotEmitSignals();
    void materializeTodayStampsRoutineId();
    void materializeTodayRollsBackClaimWhenTaskInsertFails();
    void materializeTodayDoesNotResurrectDeletedTask();
    void materializeTodaySkipsInactiveRoutines();
    void freshDatabaseHasRoutineIdColumn();
    void migrationV4DoesNotGuessRoutineLineage();
    void migrationV6ClearsUntrustedRoutineLineage();
    void migrationV10ConvertsPomodoroEstimateToMinutes();
    void migrationV10IsIdempotentAndDoesNotLoop();
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
    void moveTasksToTodayIsTransactional();
    void exportFocusSessionsUsesLogicalDayRange();
    void exportTasksWritesUtf8CsvWithEscapingAndCategoryFallbacks();
    void exportFocusSessionsAndExportAllWriteExpectedCsvFiles();
    void exportFocusSessionsIgnoresInvalidShortSessions();
    void exportRejectsInvalidDateRangeAndUnwritablePath();
    void exportFailurePreservesExistingFile();
    void exportAllRejectsInvalidDestinationBeforeReplacingFiles();
    void freeFocusCountsTowardDurationEstimate();
    void discardFreeFocusRemovesLongSessionWithoutRecording();
    void stopFocusUnderFiveMinutesKeepsTaskPending();
    void stopFocusUnderThreeMinutesDiscardsInvalidSession();
    void shortSessionEmitsSessionDiscarded();
    void validSessionDoesNotEmitSessionDiscarded();
    void focusTimerExposesMinimumValidDuration();
    void pomodoroWorkCompletesOnlyWhenPlannedDurationReached();
    void pomodoroWorkRequiresPositiveExactPlan();
    void pomodoroTargetCompletionFailureKeepsSession();
    void manuallyStoppedPomodoroDoesNotCountAsCompleted();
    void realPomodoroSessionAdvancesLongGoalAndFiresMilestone();
    void pomodoroBreakWritesNoSessionAndCompletes();
    void pomodoroBreakRestoresTaskContextAndCount();
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
    void deletingTaskKeepsCategorySnapshotForStatisticsAndGoals();
    void isRoutineGeneratedTaskDistinguishesInstances();
    void completeUndoRestoresPriorStateWithoutTouchingFields();
    void weeklyReviewAggregatesPlannedActualAndSeparatesFreeTime();
    void weeklyReviewHandlesZeroPlanAndUnplannedSubjects();
    void weeklyReviewComparesPreviousWeekAndBoundaries();
    void weeklyReviewLowestSubjectRuleAndSingleSuggestion();
    void weeklyReviewBalancedPlanGivesSteadyConclusion();
    void weeklyReviewRejectsNonMonday();

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
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_tempDir->filePath("test.sqlite")));
}

void ServiceTests::cleanup()
{
    // FocusTimer 是进程级单例；失败用例可能没走到 stopFocus，必须在关闭测试数据库前清掉活动阶段。
    FocusTimer::instance()->resetSession();
    FocusTimer::instance()->resetPomodoroCount();
    AppSettings::instance()->setDayStartHour(4);
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

void ServiceTests::appSettingsGoalViewModeNormalizesAndRoundTrips()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.goalViewMode(), QStringLiteral("list"));

        QSignalSpy spy(&settings, &AppSettings::goalViewModeChanged);
        settings.setGoalViewMode(QStringLiteral("grid"));
        QCOMPARE(settings.goalViewMode(), QStringLiteral("grid"));
        QCOMPARE(spy.count(), 1);

        settings.setGoalViewMode(QStringLiteral("masonry"));
        QCOMPARE(settings.goalViewMode(), QStringLiteral("list"));
        QCOMPARE(spy.count(), 2);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.goalViewMode(), QStringLiteral("list"));
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

        // 新逻辑日目标替换当前记录，24 小时整是合法上界。
        QVERIFY(settings.setDailyFocusGoal(QStringLiteral("2026-07-13"), 1440));
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-12")), 0);
        QCOMPARE(settings.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-13")), 1440);
        QCOMPARE(spy.count(), 2);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.dailyFocusGoalMinutesForDate(QStringLiteral("2026-07-13")), 1440);
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

    const QVariantMap comparison = StatisticsService::instance()->getWeekComparison(weekStart);
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

    const QVariantMap comparison = StatisticsService::instance()->getWeekComparison(weekStart);
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

    const QVariantMap invalidDate = StatisticsService::instance()->getWeekComparison(QDate());
    QCOMPARE(invalidDate.value(QStringLiteral("hasData")).toBool(), false);

    const QVariantMap invalidWeekStart = StatisticsService::instance()->getWeekComparison(weekStart.addDays(1));
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

void ServiceTests::deletingMaterializedRoutineDetachesExistingTask()
{
    RoutineManager* manager = RoutineManager::instance();
    QVERIFY(manager->addRoutine(QStringLiteral("删除后保留任务"), -1));
    const int routineId = manager->getRoutines().first().toMap().value(QStringLiteral("id")).toInt();
    QVERIFY(routineId > 0);
    QCOMPARE(manager->materializeToday(), 1);

    const QVariantList tasks = TaskManager::instance()->getTasksByDate(logicalToday());
    QCOMPARE(tasks.size(), 1);
    const int taskId = tasks.first().toMap().value(QStringLiteral("id")).toInt();

    QVERIFY(manager->deleteRoutine(routineId));

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT routine_id, routine_generated FROM tasks WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), taskId);
    QVERIFY(query.exec());
    QVERIFY(query.next());
    QVERIFY(query.value(0).isNull());
    QCOMPARE(query.value(1).toInt(), 0);
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

void ServiceTests::moveTasksToTodayIsTransactional()
{
    TaskManager* manager = TaskManager::instance();
    const QDate yesterday = logicalToday().addDays(-1);
    const int first = insertTaskRow(QStringLiteral("结转一"), yesterday);
    const int second = insertTaskRow(QStringLiteral("结转二"), yesterday);
    QVERIFY(first > 0);
    QVERIFY(second > 0);

    QSignalSpy changedSpy(manager, &TaskManager::tasksChanged);
    QTest::ignoreMessage(QtWarningMsg, "Failed to move task 999999 : \"\"");
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
    QCOMPARE(progressSpy.count(), 3);
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
    QCOMPARE(sessionProgressSpy.count(), 3);
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

void ServiceTests::realPomodoroSessionAdvancesLongGoalAndFiresMilestone()
{
    // 端到端用例：GoalServiceTests 里的专注记录是手工 INSERT 的，若 FocusTimer 实际写入的
    // mode / duration / task_id 与那边的假设不一致，单测照样全绿而线上进度恒为 0。
    // 这里让 FocusTimer 真的跑完一个番茄，验证聚合口径在两端确实对得上。
    AppSettings::instance()->setDayStartHour(0);

    QSqlQuery categoryQuery(DatabaseManager::instance()->database());
    QVERIFY(categoryQuery.exec(QStringLiteral(
        "INSERT INTO categories (name, color) VALUES ('长期目标科目', '#d4a574')")));
    const int categoryId = categoryQuery.lastInsertId().toInt();
    QVERIFY(categoryId > 0);

    const int taskId = insertTaskRowWithCategoryId(QStringLiteral("目标推进任务"),
                                                   QDate::currentDate(),
                                                   categoryId,
                                                   QString(),
                                                   false,
                                                   QDateTime::currentDateTime().toString(Qt::ISODate));
    QVERIFY(taskId > 0);

    GoalService* goals = GoalService::instance();
    // 目标定成 1 个番茄，跑完一轮就直接跨到 100%，一次覆盖进度聚合与里程碑两条链路。
    // 目标 5 分钟：下面那次专注是 300 秒，刚好达成。v11 前这里是「1 个番茄」，
    // 换算基准变了但用例意图没变。
    QVERIFY(goals->addGoal(QStringLiteral("端到端目标"), categoryId, 5,
                           QDate::currentDate(), QVariant()));
    const QVariantList created = goals->getGoals();
    QCOMPARE(created.size(), 1);
    const int goalId = created.first().toMap().value(QStringLiteral("id")).toInt();
    QCOMPARE(goals->getGoal(goalId).value(QStringLiteral("doneMinutes")).toInt(), 0);

    QSignalSpy milestoneSpy(goals, &GoalService::milestoneReached);

    // 与 main.cpp 中的装配保持一致：专注结束后重算里程碑。
    QVERIFY(QObject::connect(FocusTimer::instance(), &FocusTimer::focusCompleted,
                             goals, &GoalService::refreshMilestones));

    QVERIFY(FocusTimer::instance()->startPomodoroWork(taskId, QStringLiteral("目标推进任务"), 300));
    setFocusElapsedSeconds(FocusTimer::instance(), 300);
    QVERIFY(QMetaObject::invokeMethod(&FocusTimer::instance()->m_timer, "timeout", Qt::DirectConnection));

    const QVariantMap goal = goals->getGoal(goalId);
    QCOMPARE(goal.value(QStringLiteral("doneMinutes")).toInt(), 5);
    QCOMPARE(goal.value(QStringLiteral("achieved")).toBool(), true);
    QCOMPARE(goal.value(QStringLiteral("percent")).toInt(), 100);

    QCOMPARE(milestoneSpy.count(), 1);
    QCOMPARE(milestoneSpy.first().at(0).toInt(), goalId);
    QCOMPARE(milestoneSpy.first().at(2).toInt(), 100);

    QObject::disconnect(FocusTimer::instance(), &FocusTimer::focusCompleted,
                        goals, &GoalService::refreshMilestones);
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

void ServiceTests::deletingTaskKeepsCategorySnapshotForStatisticsAndGoals()
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

    GoalService* goals = GoalService::instance();
    QVERIFY(goals->addGoal(QStringLiteral("快照目标"), categoryId, 5,
                           logicalToday(), QVariant()));
    const int goalId = goals->getGoals().first().toMap().value(QStringLiteral("id")).toInt();

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

    QCOMPARE(goals->getGoal(goalId).value(QStringLiteral("doneMinutes")).toInt(), 5);
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

void ServiceTests::weeklyReviewAggregatesPlannedActualAndSeparatesFreeTime()
{
    const QDate weekStart = mondayOf(QDate(2026, 7, 15));
    const QDate weekday = weekStart.addDays(1);
    const int mathId = categoryIdByName(QStringLiteral("数学"));
    const int polId = categoryIdByName(QStringLiteral("政治"));
    QVERIFY(mathId > 0 && polId > 0);

    // v10 起「计划」的单位是分钟：数学 100 分钟、政治 150 分钟，合计 250。
    const int mathTask = insertPlannedTask(QStringLiteral("数学任务"), weekday, mathId, 100);
    const int polTask = insertPlannedTask(QStringLiteral("政治任务"), weekday, polId, 150);
    QVERIFY(mathTask > 0 && polTask > 0);

    // 有效番茄工作段（mode 默认 1）：数学 3 个、政治 2 个。
    for (int i = 0; i < 3; ++i) QVERIFY(insertFocusSessionRow(mathTask, weekday, 25 * 60));
    for (int i = 0; i < 2; ++i) QVERIFY(insertFocusSessionRow(polTask, weekday, 25 * 60));
    // 自由计时段（mode 0）30 分钟：不折算番茄，但**计入专注时长**，
    // 而完成率现在就是按时长算的，所以它会进完成率——这正是 v10 的语义变化。
    QVERIFY(insertFocusSessionRowWithMode(mathTask, weekday, 30 * 60, 0));

    const QVariantMap review = StatisticsService::instance()->getWeeklyReview(weekStart);
    QCOMPARE(review.value(QStringLiteral("hasData")).toBool(), true);
    QCOMPARE(review.value(QStringLiteral("plannedMinutes")).toInt(), 250);
    // 完整番茄仍是独立口径，不因计划改成分钟而变。
    QCOMPARE(review.value(QStringLiteral("completedPomodoros")).toInt(), 5);
    // 专注时长含两种模式的有效会话：5×25 + 30 = 155 分钟。
    QCOMPARE(review.value(QStringLiteral("focusedMinutes")).toInt(), 155);
    // 完成率 = 实际专注分钟 / 计划分钟 = 155 / 250 = 62%。
    QCOMPARE(qRound(review.value(QStringLiteral("completionRate")).toDouble()), 62);

    const QVariantList subjects = review.value(QStringLiteral("subjects")).toList();
    QCOMPARE(subjectByName(subjects, QStringLiteral("数学")).value(QStringLiteral("actual")).toInt(), 3);
    QCOMPARE(subjectByName(subjects, QStringLiteral("数学")).value(QStringLiteral("planned")).toInt(), 100);
    // 数学：3×25 + 30 自由 = 105 分钟。
    QCOMPARE(subjectByName(subjects, QStringLiteral("数学")).value(QStringLiteral("focusedMinutes")).toInt(), 105);
    QCOMPARE(subjectByName(subjects, QStringLiteral("政治")).value(QStringLiteral("actual")).toInt(), 2);
}

void ServiceTests::weeklyReviewHandlesZeroPlanAndUnplannedSubjects()
{
    const QDate weekStart = mondayOf(QDate(2026, 7, 15));
    const QDate weekday = weekStart.addDays(1);
    const int mathId = categoryIdByName(QStringLiteral("数学"));

    // 完全没有预估，只有实际投入：完成率不除零，标记为“未计划投入”。
    const int task = insertPlannedTask(QStringLiteral("无预估任务"), weekday, mathId, 0);
    QVERIFY(insertFocusSessionRow(task, weekday, 25 * 60));
    QVERIFY(insertFocusSessionRow(task, weekday, 25 * 60));

    const QVariantMap review = StatisticsService::instance()->getWeeklyReview(weekStart);
    QCOMPARE(review.value(QStringLiteral("plannedMinutes")).toInt(), 0);
    QCOMPARE(review.value(QStringLiteral("completedPomodoros")).toInt(), 2);
    QCOMPARE(review.value(QStringLiteral("completionRate")).toDouble(), 0.0);
    QCOMPARE(review.value(QStringLiteral("hasData")).toBool(), true);

    const QVariantList subjects = review.value(QStringLiteral("subjects")).toList();
    QCOMPARE(subjectByName(subjects, QStringLiteral("数学")).value(QStringLiteral("unplanned")).toBool(), true);
    // 无计划但有实际时，建议引导设置预估。
    QVERIFY(review.value(QStringLiteral("suggestionText")).toString().contains(QStringLiteral("预计用时")));
}

void ServiceTests::weeklyReviewComparesPreviousWeekAndBoundaries()
{
    const QDate weekStart = mondayOf(QDate(2026, 7, 15));
    const int mathId = categoryIdByName(QStringLiteral("数学"));

    // 本周 2 个有效番茄。
    const int thisTask = insertPlannedTask(QStringLiteral("本周任务"), weekStart.addDays(1), mathId, 5);
    QVERIFY(insertFocusSessionRow(thisTask, weekStart.addDays(1), 25 * 60));
    QVERIFY(insertFocusSessionRow(thisTask, weekStart.addDays(1), 25 * 60));
    // 上周 1 个有效番茄。
    const int prevTask = insertPlannedTask(QStringLiteral("上周任务"), weekStart.addDays(-6), mathId, 5);
    QVERIFY(insertFocusSessionRow(prevTask, weekStart.addDays(-6), 25 * 60));
    // 逻辑日边界：周日之后一天 02:00 的会话（日界 4 点）应归入本周最后一天。
    const int boundaryTask = insertPlannedTask(QStringLiteral("边界任务"), weekStart.addDays(6), mathId, 0);
    QVERIFY(insertFocusSessionRowAt(boundaryTask, weekStart.addDays(7),
                                    QStringLiteral("02:00:00"), QStringLiteral("02:25:00"), 25 * 60));

    const QVariantMap review = StatisticsService::instance()->getWeeklyReview(weekStart);
    QCOMPARE(review.value(QStringLiteral("completedPomodoros")).toInt(), 3); // 2 本周 + 1 边界
    QCOMPARE(review.value(QStringLiteral("previousCompletedPomodoros")).toInt(), 1);

    // 更早、无任何数据的周：与上周对比为 0，空状态。
    const QVariantMap empty = StatisticsService::instance()->getWeeklyReview(weekStart.addDays(-28));
    QCOMPARE(empty.value(QStringLiteral("hasData")).toBool(), false);
    QCOMPARE(empty.value(QStringLiteral("previousCompletedPomodoros")).toInt(), 0);
}

void ServiceTests::weeklyReviewLowestSubjectRuleAndSingleSuggestion()
{
    const QDate weekStart = mondayOf(QDate(2026, 7, 15));
    const QDate weekday = weekStart.addDays(1);
    const int mathId = categoryIdByName(QStringLiteral("数学"));
    const int polId = categoryIdByName(QStringLiteral("政治"));
    const int engId = categoryIdByName(QStringLiteral("英语"));

    // 计划单位是分钟（v10）。数学 250 计划 / 200 实际 = 80%，
    // 政治 250 计划 / 25 实际 = 10%，英语 50 计划 / 0 实际（计划 < 60 分钟，不参与规则一）。
    // 总体 225/550≈41%；政治 10% 比总体低 31pp(≥20) 且计划≥60 → 被规则一点名。
    const int mathTask = insertPlannedTask(QStringLiteral("数学"), weekday, mathId, 250);
    for (int i = 0; i < 8; ++i) QVERIFY(insertFocusSessionRow(mathTask, weekday, 25 * 60));
    const int polTask = insertPlannedTask(QStringLiteral("政治"), weekday, polId, 250);
    QVERIFY(insertFocusSessionRow(polTask, weekday, 25 * 60));
    insertPlannedTask(QStringLiteral("英语"), weekday, engId, 50); // 有计划无实际，且低于规则一门槛

    const QVariantMap review = StatisticsService::instance()->getWeeklyReview(weekStart);
    // 规则一：偏差最大且计划≥3 的政治被点名。
    QVERIFY(review.value(QStringLiteral("factText")).toString().contains(QStringLiteral("政治")));
    // 总体 <60%：给出下调计划的单条建议。
    QVERIFY(review.value(QStringLiteral("suggestionText")).toString().contains(QStringLiteral("下调")));

    // 有计划无实际的科目完成率为 0。
    const QVariantList subjects = review.value(QStringLiteral("subjects")).toList();
    QCOMPARE(subjectByName(subjects, QStringLiteral("英语")).value(QStringLiteral("rate")).toDouble(), 0.0);
}

void ServiceTests::weeklyReviewBalancedPlanGivesSteadyConclusion()
{
    const QDate weekStart = mondayOf(QDate(2026, 7, 15));
    const QDate weekday = weekStart.addDays(1);
    const int mathId = categoryIdByName(QStringLiteral("数学"));

    // 计划 250 分钟、实际 225 分钟 → 90%，落在 85–115 区间：
    // 结论“基本一致”，不给下调/上调建议。
    const int task = insertPlannedTask(QStringLiteral("稳定任务"), weekday, mathId, 250);
    for (int i = 0; i < 9; ++i) QVERIFY(insertFocusSessionRow(task, weekday, 25 * 60));

    const QVariantMap review = StatisticsService::instance()->getWeeklyReview(weekStart);
    QCOMPARE(qRound(review.value(QStringLiteral("completionRate")).toDouble()), 90);
    QVERIFY(review.value(QStringLiteral("factText")).toString().contains(QStringLiteral("基本一致")));
    QCOMPARE(review.value(QStringLiteral("suggestionText")).toString(), QString());
}

void ServiceTests::weeklyReviewRejectsNonMonday()
{
    const QDate weekStart = mondayOf(QDate(2026, 7, 15));
    const QVariantMap review = StatisticsService::instance()->getWeeklyReview(weekStart.addDays(2));
    QCOMPARE(review.value(QStringLiteral("hasData")).toBool(), false);
}

QTEST_MAIN(ServiceTests)
#include "ServiceTests.moc"

void ServiceTests::manualSessionCountsTowardMinutesButNotPomodoros()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("忘了开计时的任务"), today,
                                     QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    // 补录一小时。开始时间取足够早的过去，避开"结束时间不能晚于现在"。
    const QDateTime start = QDateTime(today, QTime(8, 0));
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
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("重叠任务"), today, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    const QDateTime start = QDateTime(today, QTime(8, 0));
    QVERIFY(history->addManualSession(taskId, start, 60) > 0);

    // 与既有记录相交的一律拒绝：两条覆盖同一段时间会让统计凭空多出时长，
    // 而且事后无从察觉。
    QCOMPARE(history->addManualSession(taskId, start.addSecs(30 * 60), 60), -1);
    QVERIFY(history->lastError().contains(QStringLiteral("已有专注记录")));
    QCOMPARE(history->addManualSession(taskId, start.addSecs(-30 * 60), 60), -1);

    // 首尾相接不算重叠：8:00–9:00 之后紧接 9:00 开始是合法的。
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
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("待修改"), today, QStringLiteral("数学"));

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
                         QDateTime(today, QTime(8, 0)).toString(Qt::ISODate));
        insert.bindValue(QStringLiteral(":end"),
                         QDateTime(today, QTime(8, 25)).toString(Qt::ISODate));
        insert.bindValue(QStringLiteral(":duration"), 25 * 60);
        QVERIFY(insert.exec());
    }
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);

    const QVariantList sessions = history->getDaySessions(today);
    QCOMPARE(sessions.size(), 1);
    const int sessionId = sessions.first().toMap().value(QStringLiteral("id")).toInt();

    QVERIFY2(history->updateSession(sessionId, QDateTime(today, QTime(10, 0)), 40),
             qPrintable(history->lastError()));
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 40);
    // 改时长不改性质：它仍然是那次自然到点的番茄，不该因为被编辑过就降级。
    QCOMPARE(TaskManager::instance()->getCompletedPomodorosForTask(taskId), 1);
}

void ServiceTests::deleteSessionRemovesItAndRollsStatsBack()
{
    FocusHistoryService* history = FocusHistoryService::instance();
    const QDate today = logicalToday();
    const int taskId = insertTaskRow(QStringLiteral("待删除"), today, QStringLiteral("数学"));

    const int sessionId = history->addManualSession(taskId, QDateTime(today, QTime(8, 0)), 45);
    QVERIFY(sessionId > 0);
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 45);

    QVERIFY2(history->deleteSession(sessionId), qPrintable(history->lastError()));
    QCOMPARE(TaskManager::instance()->getFocusedMinutesForTask(taskId), 0);
    QCOMPARE(history->getDaySessions(today).size(), 0);

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

