#include "DatabaseManager.h"

#include <QDebug>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QStringList>

#include <iterator>

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

struct PresetCategory {
    const char* name;
    const char* color;
};

const PresetCategory kPresetCategories[] = {
    {"数学", "#d4a574"},
    {"英语", "#c9956e"},
    {"政治", "#be8568"},
    {"专业课", "#b37562"},
    {"其他", "#a8655c"}
};
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
        // Qt 要求 removeDatabase() 前清掉所有句柄，否则旧连接可能残留，
        // 使用临时数据库路径的测试会变得不稳定。
        m_db = QSqlDatabase();
        QSqlDatabase::removeDatabase(m_connectionName);
    }
    m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connectionName);

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
            category_id INTEGER REFERENCES categories(id),
            routine_id INTEGER REFERENCES routines(id) ON DELETE SET NULL,
            routine_generated INTEGER NOT NULL DEFAULT 0 CHECK(routine_generated IN (0, 1)),
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

    const QString createActiveFocusStateTable = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS active_focus_state (
            singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
            session_id INTEGER UNIQUE,
            task_id INTEGER,
            task_title TEXT NOT NULL DEFAULT '',
            elapsed_seconds INTEGER NOT NULL DEFAULT 0 CHECK(elapsed_seconds >= 0),
            mode INTEGER NOT NULL,
            phase INTEGER NOT NULL,
            target_seconds INTEGER NOT NULL DEFAULT 0 CHECK(target_seconds >= 0),
            updated_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES focus_sessions(id) ON DELETE CASCADE,
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
        )
    )SQL");
    // 历史表只保存已完成记录；活动状态独立存放，应用异常退出后才能恢复，而不是留下不可见的 NULL 占位行。
    if (!execSql(query, createActiveFocusStateTable, "Failed to create active_focus_state table:")) {
        return false;
    }

    // 版本 2 引入 categories/category_id，同时保留旧版文本科目。
    if (getDatabaseVersion() < 2
        || !tableExists(QStringLiteral("categories"))
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("category_id"))) {
        if (!migrateToVersion2()) {
            return false;
        }
    } else if (!createCategoriesTable() || !insertPresetCategories()) {
        return false;
    }

    // 版本 3 引入每日例行表 routines（纯新增，向后兼容）。
    if (getDatabaseVersion() < 3 || !tableExists(QStringLiteral("routines"))) {
        if (!migrateToVersion3()) {
            return false;
        }
    }

    // 版本 4 给 tasks 增加 routine_id 血缘列；列缺失时无论版本号都要补，防御半迁移状态。
    if (getDatabaseVersion() < 4
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("routine_id"))) {
        if (!migrateToVersion4()) {
            return false;
        }
    }

    if (getDatabaseVersion() < 5 || !routineForeignKeyUsesSetNull()) {
        if (!migrateToVersion5()) {
            return false;
        }
    }

    if (getDatabaseVersion() < 6
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("routine_generated"))) {
        if (!migrateToVersion6()) {
            return false;
        }
    }

    const QStringList indexes = {
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(date)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks(completed)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_category_id ON tasks(category_id)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_task ON focus_sessions(task_id)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_start ON focus_sessions(start_time)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_routines_active ON routines(active)")
    };

    for (const QString& indexSql : indexes) {
        if (!execSql(query, indexSql, "Failed to create database index:")) {
            return false;
        }
    }

    return true;
}

int DatabaseManager::getDatabaseVersion() const
{
    if (!m_db.isOpen()) {
        return 0;
    }

    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA user_version"))) {
        qWarning() << "Failed to read database version:" << query.lastError().text();
        return 0;
    }

    return query.next() ? query.value(0).toInt() : 0;
}

bool DatabaseManager::setDatabaseVersion(int version)
{
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA user_version = %1").arg(version))) {
        qWarning() << "Failed to set database version:" << query.lastError().text();
        return false;
    }

    return true;
}

bool DatabaseManager::migrateToVersion2()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    if (!backupDatabaseBeforeMigration()) {
        return false;
    }

    if (!m_db.transaction()) {
        qWarning() << "Failed to start database migration transaction:" << m_db.lastError().text();
        return false;
    }

    if (!createCategoriesTable() || !insertPresetCategories()) {
        m_db.rollback();
        return false;
    }

    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("category_id"))) {
        QSqlQuery alterQuery(m_db);
        if (!execSql(alterQuery,
                     QStringLiteral("ALTER TABLE tasks ADD COLUMN category_id INTEGER REFERENCES categories(id)"),
                     "Failed to add tasks.category_id column:")) {
            m_db.rollback();
            return false;
        }
    }

    QSqlQuery indexQuery(m_db);
    if (!execSql(indexQuery,
                 QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_category_id ON tasks(category_id)"),
                 "Failed to create category_id index:")) {
        m_db.rollback();
        return false;
    }

    if (!migrateTaskCategories() || !setDatabaseVersion(2)) {
        m_db.rollback();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit database migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 2";
    return true;
}

bool DatabaseManager::createCategoriesTable()
{
    QSqlQuery query(m_db);
    const QString createCategories = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE CHECK(length(trim(name)) > 0),
            color TEXT NOT NULL,
            is_preset INTEGER NOT NULL DEFAULT 0,
            display_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    )SQL");

    if (!execSql(query, createCategories, "Failed to create categories table:")) {
        return false;
    }

    return execSql(query,
                   QStringLiteral("CREATE INDEX IF NOT EXISTS idx_categories_display_order ON categories(display_order, name)"),
                   "Failed to create categories display_order index:");
}

bool DatabaseManager::createRoutinesTable()
{
    QSqlQuery query(m_db);
    const QString createRoutines = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS routines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
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

    // v3 只新增 routines 表，不改写既有用户数据；因此不额外创建备份。
    // 未来如果 v3 迁移开始改动旧表，必须重新评估备份策略。
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

bool DatabaseManager::migrateToVersion4()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // v4 会改写既有 tasks 行；迁移前备份是为了避免回填中途失败造成不可恢复状态。
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
                "ALTER TABLE tasks ADD COLUMN routine_id INTEGER REFERENCES routines(id) ON DELETE SET NULL"))) {
            qWarning() << "Failed to add routine_id column:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    // 旧版本没有保存任务血缘，标题相同不能证明任务由例行规则生成。
    // 宁可让旧任务参与一次结转，也不能把用户手工任务永久误标成例行任务。

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

bool DatabaseManager::migrateToVersion5()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }

    // SQLite 不能直接修改外键动作，只能重建表。外键开关必须在事务外关闭，
    // 否则 DROP 旧表时会错误地触发引用表的级联动作。
    QSqlQuery pragmaQuery(m_db);
    if (!pragmaQuery.exec(QStringLiteral("PRAGMA foreign_keys = OFF"))) {
        qWarning() << "Failed to disable foreign keys for version 5 migration:"
                   << pragmaQuery.lastError().text();
        return false;
    }

    auto restoreForeignKeys = [this]() {
        QSqlQuery query(m_db);
        if (!query.exec(QStringLiteral("PRAGMA foreign_keys = ON"))) {
            qWarning() << "Failed to restore foreign key enforcement:" << query.lastError().text();
            return false;
        }
        return true;
    };

    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 5 migration:" << m_db.lastError().text();
        restoreForeignKeys();
        return false;
    }

    const QString provenanceExpression = columnExists(
        QStringLiteral("tasks"), QStringLiteral("routine_generated"))
        ? QStringLiteral("routine_generated") : QStringLiteral("0");

    QSqlQuery query(m_db);
    const QStringList statements = {
        QStringLiteral(R"SQL(
            CREATE TABLE tasks_v5 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                category TEXT,
                category_id INTEGER REFERENCES categories(id),
                routine_id INTEGER REFERENCES routines(id) ON DELETE SET NULL,
                routine_generated INTEGER NOT NULL DEFAULT 0 CHECK(routine_generated IN (0, 1)),
                date TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        )SQL"),
        QStringLiteral(
            "INSERT INTO tasks_v5 (id, title, category, category_id, routine_id, routine_generated, date, completed, created_at) "
            "SELECT id, title, category, category_id, routine_id, %1, date, completed, created_at FROM tasks")
            .arg(provenanceExpression),
        QStringLiteral("DROP TABLE tasks"),
        QStringLiteral("ALTER TABLE tasks_v5 RENAME TO tasks")
    };

    for (const QString& statement : statements) {
        if (!query.exec(statement)) {
            qWarning() << "Failed during version 5 migration:" << query.lastError().text();
            m_db.rollback();
            restoreForeignKeys();
            return false;
        }
    }

    // 只解除能被时间顺序证明为错误的旧回填：任务早于例行规则创建，不可能由该规则生成。
    if (!query.exec(QStringLiteral(R"SQL(
        UPDATE tasks
        SET routine_id = NULL
        WHERE routine_id IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM routines r
              WHERE r.id = tasks.routine_id
                AND datetime(tasks.created_at) < datetime(r.created_at)
          )
    )SQL"))) {
        qWarning() << "Failed to detach impossible routine lineage:" << query.lastError().text();
        m_db.rollback();
        restoreForeignKeys();
        return false;
    }

    if (!setDatabaseVersion(5) || !m_db.commit()) {
        qWarning() << "Failed to commit version 5 migration:" << m_db.lastError().text();
        m_db.rollback();
        restoreForeignKeys();
        return false;
    }

    if (!restoreForeignKeys()) {
        return false;
    }

    QSqlQuery checkQuery(m_db);
    if (!checkQuery.exec(QStringLiteral("PRAGMA foreign_key_check"))) {
        qWarning() << "Failed to validate version 5 foreign keys:" << checkQuery.lastError().text();
        return false;
    }
    if (checkQuery.next()) {
        qWarning() << "Version 5 migration produced a foreign key violation"
                   << checkQuery.value(0).toString() << checkQuery.value(1).toInt();
        return false;
    }

    qInfo() << "Database migrated to version 5";
    return true;
}

bool DatabaseManager::migrateToVersion6()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 6 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("routine_generated"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE tasks ADD COLUMN routine_generated INTEGER NOT NULL DEFAULT 0 "
                "CHECK(routine_generated IN (0, 1))"))) {
            qWarning() << "Failed to add routine provenance column:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    // v4 的 routine_id 可能只因标题相同而被回填。旧库没有足够证据区分真假，
    // 因此统一解除不可信关联；从 v6 起只有生成器写入 routine_generated=1。
    if (!query.exec(QStringLiteral(
            "UPDATE tasks SET routine_id = NULL WHERE routine_generated = 0 AND routine_id IS NOT NULL"))) {
        qWarning() << "Failed to clear untrusted routine lineage:" << query.lastError().text();
        m_db.rollback();
        return false;
    }

    if (!setDatabaseVersion(6) || !m_db.commit()) {
        qWarning() << "Failed to commit version 6 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 6";
    return true;
}

bool DatabaseManager::routineForeignKeyUsesSetNull() const
{
    if (!m_db.isOpen()) {
        return false;
    }

    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA foreign_key_list(tasks)"))) {
        return false;
    }

    while (query.next()) {
        const QString referencedTable = query.value(2).toString();
        const QString fromColumn = query.value(3).toString();
        const QString onDelete = query.value(6).toString();
        if (referencedTable == QStringLiteral("routines")
            && fromColumn == QStringLiteral("routine_id")) {
            return onDelete.compare(QStringLiteral("SET NULL"), Qt::CaseInsensitive) == 0;
        }
    }
    return false;
}

bool DatabaseManager::insertPresetCategories()
{
    QSqlQuery query(m_db);
    query.prepare(QStringLiteral(
        "INSERT OR IGNORE INTO categories (name, color, is_preset, display_order) "
        "VALUES (:name, :color, 1, :displayOrder)"));

    for (int index = 0; index < int(std::size(kPresetCategories)); ++index) {
        query.bindValue(QStringLiteral(":name"), QString::fromUtf8(kPresetCategories[index].name));
        query.bindValue(QStringLiteral(":color"), QString::fromLatin1(kPresetCategories[index].color));
        query.bindValue(QStringLiteral(":displayOrder"), index + 1);

        if (!query.exec()) {
            qWarning() << "Failed to insert preset category:" << query.lastError().text();
            return false;
        }
    }

    return true;
}

bool DatabaseManager::migrateTaskCategories()
{
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("category_id"))) {
        qWarning() << "Cannot migrate task categories: category_id column is missing";
        return false;
    }

    // 旧任务把科目存成自由文本；迁移时把去重后的名称转成科目行，
    // 同时保留原文本，兼容旧导出和 UI 回退显示。
    QSqlQuery distinctQuery(m_db);
    if (!distinctQuery.exec(QStringLiteral(
            "SELECT DISTINCT trim(category) "
            "FROM tasks "
            "WHERE category_id IS NULL AND category IS NOT NULL AND trim(category) != ''"))) {
        qWarning() << "Failed to read legacy task categories:" << distinctQuery.lastError().text();
        return false;
    }

    QStringList categoryNames;
    while (distinctQuery.next()) {
        categoryNames.append(distinctQuery.value(0).toString());
    }

    QSqlQuery selectCategory(m_db);
    QSqlQuery insertCategory(m_db);
    QSqlQuery updateTasks(m_db);

    for (int index = 0; index < categoryNames.size(); ++index) {
        const QString categoryName = categoryNames.at(index);
        int categoryId = -1;

        selectCategory.prepare(QStringLiteral("SELECT id FROM categories WHERE name = :name"));
        selectCategory.bindValue(QStringLiteral(":name"), categoryName);
        if (!selectCategory.exec()) {
            qWarning() << "Failed to look up category during migration:" << selectCategory.lastError().text();
            return false;
        }
        if (selectCategory.next()) {
            categoryId = selectCategory.value(0).toInt();
        }

        if (categoryId <= 0) {
            insertCategory.prepare(QStringLiteral(
                "INSERT INTO categories (name, color, is_preset, display_order) "
                "VALUES (:name, :color, 0, :displayOrder)"));
            insertCategory.bindValue(QStringLiteral(":name"), categoryName);
            insertCategory.bindValue(QStringLiteral(":color"), generateColorForCategory(index + int(std::size(kPresetCategories))));
            insertCategory.bindValue(QStringLiteral(":displayOrder"), 100 + index);

            if (!insertCategory.exec()) {
                qWarning() << "Failed to create migrated category:" << insertCategory.lastError().text();
                return false;
            }
            categoryId = insertCategory.lastInsertId().toInt();
        }

        updateTasks.prepare(QStringLiteral(
            "UPDATE tasks SET category_id = :categoryId "
            "WHERE category_id IS NULL AND trim(category) = :categoryName"));
        updateTasks.bindValue(QStringLiteral(":categoryId"), categoryId);
        updateTasks.bindValue(QStringLiteral(":categoryName"), categoryName);

        if (!updateTasks.exec()) {
            qWarning() << "Failed to assign migrated category to tasks:" << updateTasks.lastError().text();
            return false;
        }
    }

    return true;
}

QString DatabaseManager::generateColorForCategory(int index) const
{
    // 颜色生成必须确定性，迁移结果才可复现、可测试。
    const QStringList colors = {
        QStringLiteral("#d4a574"),
        QStringLiteral("#c9956e"),
        QStringLiteral("#be8568"),
        QStringLiteral("#b37562"),
        QStringLiteral("#a8655c"),
        QStringLiteral("#9d7556"),
        QStringLiteral("#8b6550"),
        QStringLiteral("#7a5544"),
        QStringLiteral("#694538"),
        QStringLiteral("#58352c")
    };

    return colors.at(index % colors.size());
}

bool DatabaseManager::backupDatabaseBeforeMigration() const
{
    const QString databaseName = m_db.databaseName();
    if (databaseName.isEmpty() || databaseName == QStringLiteral(":memory:")) {
        return true;
    }

    const QFileInfo databaseInfo(databaseName);
    if (!databaseInfo.exists() || !databaseInfo.isFile()) {
        return true;
    }

    const QDir databaseDir = databaseInfo.absoluteDir();
    const QString timestamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss_zzz"));
    QString backupPath = databaseDir.filePath(QStringLiteral("pomodoro_backup_%1.db").arg(timestamp));
    int suffix = 1;
    while (QFileInfo::exists(backupPath)) {
        backupPath = databaseDir.filePath(QStringLiteral("pomodoro_backup_%1_%2.db").arg(timestamp).arg(suffix++));
    }

    if (!QFile::copy(databaseInfo.absoluteFilePath(), backupPath)) {
        qWarning() << "Failed to create database migration backup:" << backupPath;
        return false;
    }

    pruneOldBackups(databaseDir);
    return true;
}

void DatabaseManager::pruneOldBackups(const QDir& databaseDir) const
{
    // 只保留最近三个迁移备份，避免反复测试或启动应用时悄悄塞满数据目录。
    const QFileInfoList backups = databaseDir.entryInfoList(
        QStringList{QStringLiteral("pomodoro_backup_*.db")},
        QDir::Files,
        QDir::Time);

    for (int index = 3; index < backups.size(); ++index) {
        if (!QFile::remove(backups.at(index).absoluteFilePath())) {
            qWarning() << "Failed to remove old database backup:" << backups.at(index).absoluteFilePath();
        }
    }
}

bool DatabaseManager::tableExists(const QString& tableName) const
{
    if (!m_db.isOpen()) {
        return false;
    }

    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT name FROM sqlite_master WHERE type = 'table' AND name = :name"));
    query.bindValue(QStringLiteral(":name"), tableName);
    if (!query.exec()) {
        qWarning() << "Failed to inspect database table:" << query.lastError().text();
        return false;
    }

    return query.next();
}

bool DatabaseManager::columnExists(const QString& tableName, const QString& columnName) const
{
    if (!m_db.isOpen() || !tableExists(tableName)) {
        return false;
    }

    // PRAGMA table_info 是 SQLite 查看表结构的命令，不能绑定表名，
    // 所以调用方必须传入可信的内部表名。
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA table_info(%1)").arg(tableName))) {
        qWarning() << "Failed to inspect database columns:" << query.lastError().text();
        return false;
    }

    while (query.next()) {
        if (query.value(1).toString() == columnName) {
            return true;
        }
    }

    return false;
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
