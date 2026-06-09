#include "DatabaseManager.h"

#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QStringList>

namespace {
constexpr auto kConnectionName = "PomodoroTodoConnection";

bool execSql(QSqlQuery& query, const QString& sql, const char* context)
{
    if (!query.exec(sql)) {
        qWarning() << context << query.lastError().text();
        return false;
    }
    return true;
}
}

DatabaseManager::DatabaseManager(QObject* parent)
    : QObject(parent)
    , m_connectionName(QLatin1String(kConnectionName))
{
}

DatabaseManager::~DatabaseManager()
{
    if (m_db.isValid()) {
        m_db.close();
    }
}

DatabaseManager* DatabaseManager::instance()
{
    static DatabaseManager manager;
    return &manager;
}

bool DatabaseManager::initialize(const QString& dbPath)
{
    QString path = dbPath.trimmed();
    if (path.isEmpty()) {
        const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        if (dataDir.isEmpty() || !QDir().mkpath(dataDir)) {
            qWarning() << "Failed to prepare application data directory:" << dataDir;
            return false;
        }
        path = QDir(dataDir).filePath(QStringLiteral("pomodoro.db"));
    } else {
        const QFileInfo fileInfo(path);
        const QDir parentDir = fileInfo.absoluteDir();
        if (!parentDir.exists() && !QDir().mkpath(parentDir.absolutePath())) {
            qWarning() << "Failed to prepare database directory:" << parentDir.absolutePath();
            return false;
        }
    }

    if (m_db.isOpen() && m_db.databaseName() == path) {
        return createTables();
    }

    if (m_db.isValid()) {
        m_db.close();
    }

    if (QSqlDatabase::contains(m_connectionName)) {
        m_db = QSqlDatabase::database(m_connectionName);
    } else {
        m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connectionName);
    }

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

    return createTables();
}

bool DatabaseManager::createTables()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot create tables: database is not open";
        return false;
    }

    QSqlQuery query(m_db);

    const QString createTasksTable = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            category TEXT,
            date TEXT NOT NULL,
            completed INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    )SQL");
    if (!execSql(query, createTasksTable, "Failed to create tasks table:")) {
        return false;
    }

    const QString createSessionsTable = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS focus_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration INTEGER,
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
        )
    )SQL");
    if (!execSql(query, createSessionsTable, "Failed to create focus_sessions table:")) {
        return false;
    }

    const QStringList indexes = {
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(date)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks(completed)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_task ON focus_sessions(task_id)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_start ON focus_sessions(start_time)")
    };

    for (const QString& indexSql : indexes) {
        if (!execSql(query, indexSql, "Failed to create database index:")) {
            return false;
        }
    }

    return true;
}

QSqlDatabase DatabaseManager::database() const
{
    return m_db;
}

bool DatabaseManager::isOpen() const
{
    return m_db.isOpen();
}

void DatabaseManager::close()
{
    if (m_db.isValid()) {
        m_db.close();
    }
}
