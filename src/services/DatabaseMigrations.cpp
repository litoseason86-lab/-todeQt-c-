// 各 schema 版本的迁移与专用辅助；与运行时建表和结构校验分开，保留原事务与 SQL 文本。
#include "DatabaseManager.h"

#include "SnapshotRetention.h"
#include "FocusSessionRules.h"
#include "RoutineRules.h"
#include "SyncSchema.h"

#include <QDebug>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QStringList>
#include <QMap>

#include <iterator>

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

    // 这一步是整表重建，不是 ALTER：新表只会拿到下面写死的这些列，没列进来的
    // 一律连同数据被丢掉。因此每次给 tasks 新增列，都必须同步更新这份清单。
    //
    // 触发条件里有一条结构检查（外键动作不对就重建），所以这段代码会在**已经迁移到
    // 最新版本的库**上运行，而不只是在 v4 升 v5 时运行——这正是漏列会造成用户数据
    // 丢失的原因：v7 的 estimated_pomodoros（现为 estimated_minutes）曾经就不在清单里，重建后全部归零。
    const QStringList knownColumns = {
        QStringLiteral("id"),
        QStringLiteral("title"),
        QStringLiteral("category"),
        QStringLiteral("category_id"),
        QStringLiteral("routine_id"),
        QStringLiteral("routine_generated"),
        QStringLiteral("date"),
        QStringLiteral("completed"),
        QStringLiteral("created_at"),
        QStringLiteral("estimated_minutes"),
        QStringLiteral("notes"),
        QStringLiteral("display_order"),
        QStringLiteral("completion_note"),
        // v18 的同步身份。版本号被拨回、重跑 v5 时必须原样搬过去，否则同一条任务
        // 在另一台设备上会变成两条。
        QStringLiteral("sync_id"),
    };

    // 遇到不认识的列就拒绝重建。宁可让迁移失败并留下明确日志，
    // 也不能把一列用户数据静默抹掉——后者事后无法察觉，也无法还原。
    const QStringList currentColumns = tableColumns(QStringLiteral("tasks"));
    for (const QString& column : currentColumns) {
        if (!knownColumns.contains(column)) {
            qCritical() << "拒绝执行 v5 重建：tasks 存在重建清单未覆盖的列" << column
                        << "——请把它加进 migrateToVersion5 的 knownColumns 与建表语句";
            m_db.rollback();
            restoreForeignKeys();
            return false;
        }
    }

    // 从真正的 v4 库升级时后面这些列还不存在，用默认值兜底。
    const QString provenanceExpression =
        currentColumns.contains(QStringLiteral("routine_generated"))
        ? QStringLiteral("routine_generated") : QStringLiteral("0");
    const QString estimateExpression =
        currentColumns.contains(QStringLiteral("estimated_minutes"))
        ? QStringLiteral("estimated_minutes") : QStringLiteral("0");
    // v11 的两列同理：从更老的库升上来时它们还不存在，用默认值兜底。
    const QString notesExpression =
        currentColumns.contains(QStringLiteral("notes"))
        ? QStringLiteral("notes") : QStringLiteral("''");
    const QString orderExpression =
        currentColumns.contains(QStringLiteral("display_order"))
        ? QStringLiteral("display_order") : QStringLiteral("0");
    // v16 的完成记录同理：v16 之前的库没有这一列，按空记录落地。
    const QString completionNoteExpression =
        currentColumns.contains(QStringLiteral("completion_note"))
        ? QStringLiteral("completion_note") : QStringLiteral("''");
    // v18 之前的库还没有同步身份，落成 NULL，之后由 v18 迁移回填。
    const QString syncIdExpression =
        currentColumns.contains(QStringLiteral("sync_id"))
        ? QStringLiteral("sync_id") : QStringLiteral("NULL");

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
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                estimated_minutes INTEGER NOT NULL DEFAULT 0,
                notes TEXT NOT NULL DEFAULT '',
                display_order INTEGER NOT NULL DEFAULT 0,
                completion_note TEXT NOT NULL DEFAULT '',
                sync_id TEXT
            )
        )SQL"),
        // 整表重建会把 tasks 上的同步触发器和 sync_id 唯一索引一起删掉；
        // createTables 随后的 v18 检查发现索引缺失会重跑 v18，启动时也总会补齐触发器。
        QStringLiteral(
            "INSERT INTO tasks_v5 (id, title, category, category_id, routine_id, "
            "routine_generated, date, completed, created_at, estimated_minutes, "
            "notes, display_order, completion_note, sync_id) "
            "SELECT id, title, category, category_id, routine_id, %1, date, completed, "
            "created_at, %2, %3, %4, %5, %6 FROM tasks")
            .arg(provenanceExpression, estimateExpression, notesExpression, orderExpression,
                 completionNoteExpression, syncIdExpression),
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

    if (!setDatabaseVersion(5)) {
        m_db.rollback();
        restoreForeignKeys();
        return false;
    }

    // foreign_key_check 即使在 enforcement 关闭时也会扫描约束。必须在提交前验证，
    // 否则检测到损坏时事务已经不可回滚，只能留下半迁移数据库。
    QSqlQuery checkQuery(m_db);
    if (!checkQuery.exec(QStringLiteral("PRAGMA foreign_key_check"))) {
        qWarning() << "Failed to validate version 5 foreign keys:" << checkQuery.lastError().text();
        m_db.rollback();
        restoreForeignKeys();
        return false;
    }
    if (checkQuery.next()) {
        qWarning() << "Version 5 migration produced a foreign key violation"
                   << checkQuery.value(0).toString() << checkQuery.value(1).toInt();
        m_db.rollback();
        restoreForeignKeys();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit version 5 migration:" << m_db.lastError().text();
        m_db.rollback();
        restoreForeignKeys();
        return false;
    }

    if (!restoreForeignKeys()) {
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

bool DatabaseManager::migrateToVersion7()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 7 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("estimated_pomodoros"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE tasks ADD COLUMN estimated_pomodoros INTEGER NOT NULL DEFAULT 0"))) {
            qWarning() << "Failed to add tasks.estimated_pomodoros column:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    // 旧专注记录无法追溯当时是番茄还是自由计时；统一按番茄模式对待。多数历史记录来自番茄
    // 计时器，默认 1 让升级后既有任务的实际番茄数不至于凭空归零。此为已知取舍，见输出说明。
    if (!columnExists(QStringLiteral("focus_sessions"), QStringLiteral("mode"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE focus_sessions ADD COLUMN mode INTEGER NOT NULL DEFAULT 1"))) {
            qWarning() << "Failed to add focus_sessions.mode column:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    if (!setDatabaseVersion(7) || !m_db.commit()) {
        qWarning() << "Failed to commit version 7 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 7";
    return true;
}

bool DatabaseManager::migrateToVersion8()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 8 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    // 只有本次真正新增列时才能用启发式回填。列已存在时，其中的 0/1 是
    // 新版记录的真实“手动停止/自然到点”事实，重刷会造成不可恢复的篡改。
    const bool columnJustAdded = !columnExists(QStringLiteral("focus_sessions"),
                                                QStringLiteral("pomodoro_completed"));
    if (columnJustAdded) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE focus_sessions ADD COLUMN pomodoro_completed "
                "INTEGER NOT NULL DEFAULT 0 CHECK(pomodoro_completed IN (0, 1))"))) {
            qWarning() << "Failed to add focus_sessions.pomodoro_completed column:"
                       << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    if (columnJustAdded) {
        // 旧版没有保存“自然到点”事实，无法完美还原。为避免升级后历史番茄归零，
        // 只对升级前已完成、且达到有效门槛的番茄模式记录做一次兼容回填。
        // 模式与阈值取自唯一事实源，这里不复制第二套字面量。
        if (!query.exec(QStringLiteral(
                "UPDATE focus_sessions SET pomodoro_completed = "
                "CASE WHEN mode = %1 AND end_time IS NOT NULL AND duration >= %2 "
                "THEN 1 ELSE 0 END")
                            .arg(FocusSessionRules::kPomodoroMode)
                            .arg(FocusSessionRules::kMinimumValidDurationSeconds))) {
            qWarning() << "Failed to backfill completed pomodoros:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    if (!setDatabaseVersion(8) || !m_db.commit()) {
        qWarning() << "Failed to commit version 8 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 8";
    return true;
}

bool DatabaseManager::migrateToVersion9()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 9 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    const struct {
        QString name;
        QString definition;
    } snapshotColumns[] = {
        {QStringLiteral("category_id_snapshot"), QStringLiteral("INTEGER")},
        {QStringLiteral("category_name_snapshot"), QStringLiteral("TEXT NOT NULL DEFAULT ''")},
        {QStringLiteral("category_color_snapshot"), QStringLiteral("TEXT NOT NULL DEFAULT ''")}
    };

    for (const auto& column : snapshotColumns) {
        if (columnExists(QStringLiteral("focus_sessions"), column.name)) {
            continue;
        }
        if (!query.exec(QStringLiteral("ALTER TABLE focus_sessions ADD COLUMN %1 %2")
                            .arg(column.name, column.definition))) {
            qWarning() << "Failed to add focus session category snapshot column:"
                       << column.name << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    // 从尚未删除的任务回填历史归属。旧文本科目会先尝试匹配 categories，
    // 匹配不到也保留名称；快照列不设外键，否则删科目会再次擦除历史。
    if (!query.exec(QStringLiteral(R"SQL(
        UPDATE focus_sessions
        SET category_id_snapshot = (
                SELECT COALESCE(t.category_id, legacy_category.id)
                FROM tasks t
                LEFT JOIN categories legacy_category
                       ON t.category_id IS NULL AND legacy_category.name = t.category
                WHERE t.id = focus_sessions.task_id
            ),
            category_name_snapshot = COALESCE((
                SELECT COALESCE(current_category.name, legacy_category.name, t.category)
                FROM tasks t
                LEFT JOIN categories current_category ON t.category_id = current_category.id
                LEFT JOIN categories legacy_category
                       ON t.category_id IS NULL AND legacy_category.name = t.category
                WHERE t.id = focus_sessions.task_id
            ), ''),
            category_color_snapshot = COALESCE((
                SELECT COALESCE(current_category.color, legacy_category.color)
                FROM tasks t
                LEFT JOIN categories current_category ON t.category_id = current_category.id
                LEFT JOIN categories legacy_category
                       ON t.category_id IS NULL AND legacy_category.name = t.category
                WHERE t.id = focus_sessions.task_id
            ), '')
        WHERE task_id IS NOT NULL
          AND category_id_snapshot IS NULL
          AND category_name_snapshot = ''
          AND category_color_snapshot = ''
    )SQL"))) {
        qWarning() << "Failed to backfill focus session category snapshots:"
                   << query.lastError().text();
        m_db.rollback();
        return false;
    }

    if (!setDatabaseVersion(9) || !m_db.commit()) {
        qWarning() << "Failed to commit version 9 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 9";
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

bool DatabaseManager::migrateToVersion10()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 10 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("estimated_minutes"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE tasks ADD COLUMN estimated_minutes INTEGER NOT NULL DEFAULT 0"))) {
            qWarning() << "Failed to add tasks.estimated_minutes:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    // 回填：把旧的「预估番茄数」折算成分钟。
    //
    // **换算基准无法从旧数据还原**——旧库只存了番茄个数，没存用户当时的专注时长设置，
    // 而那个设置是可改的。这里用 25 分钟（应用出厂默认，也是番茄工作法的标准长度）折算，
    // 对把时长改成 50 分钟的用户会低估一半。之所以仍选它而不是读当前设置：
    // 当前设置反映的是"现在"，用它折算历史同样是猜，而且会让同一份旧数据在不同机器上
    // 得到不同结果；固定基准至少是可复现、可解释的。
    //
    // 只回填尚未设置过分钟数的行（守卫 estimated_minutes = 0），迁移重入不会二次放大。
    if (columnExists(QStringLiteral("tasks"), QStringLiteral("estimated_pomodoros"))) {
        if (!query.exec(QStringLiteral(
                "UPDATE tasks SET estimated_minutes = estimated_pomodoros * 25 "
                "WHERE estimated_minutes = 0 AND estimated_pomodoros > 0"))) {
            qWarning() << "Failed to backfill estimated_minutes:" << query.lastError().text();
            m_db.rollback();
            return false;
        }

        // 回填完成后删除旧列，不留一个没人读、却会让下一个读代码的人以为仍是事实源的死列。
        // SQLite 3.35+ 支持 DROP COLUMN；该列无索引、无视图与触发器引用。
        // 删除失败不算迁移失败：回填已经成功，新列可用；旧列留着只是整洁性问题。
        if (!query.exec(QStringLiteral("ALTER TABLE tasks DROP COLUMN estimated_pomodoros"))) {
            qWarning() << "旧列 estimated_pomodoros 删除失败（不影响功能）:"
                       << query.lastError().text();
        }
    }

    if (!setDatabaseVersion(10)) {
        m_db.rollback();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit version 10 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 10";
    return true;
}

bool DatabaseManager::migrateToVersion11()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 11 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);

    // ── 任务备注 ──
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("notes"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE tasks ADD COLUMN notes TEXT NOT NULL DEFAULT ''"))) {
            qWarning() << "Failed to add tasks.notes:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    // ── 任务手动排序 ──
    // 默认 0 而不是按 id 回填：0 表示"没排过"，列表在同序时回落到 id 升序，
    // 与迁移前的顺序一致。若在这里按 id 写死序号，用户第一次拖动后
    // 其余任务的相对位置反而会跟着变。
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("display_order"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE tasks ADD COLUMN display_order INTEGER NOT NULL DEFAULT 0"))) {
            qWarning() << "Failed to add tasks.display_order:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    if (!setDatabaseVersion(11)) {
        m_db.rollback();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit version 11 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 11";
    return true;
}

bool DatabaseManager::migrateToVersion12()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    if (!backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 12 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    // ROW_NUMBER 按 v11 查询真正展示给用户的顺序编号。先完成/未完成分组，再把 0 放到
    // 正序号后面；created_at 与 id 只负责稳定打破平局，因此迁移不会凭空改变可见顺序。
    if (!query.exec(QStringLiteral(R"SQL(
            WITH ranked_tasks AS (
                SELECT id,
                       ROW_NUMBER() OVER (
                           PARTITION BY date
                           ORDER BY completed ASC,
                                    CASE WHEN display_order = 0 THEN 1 ELSE 0 END ASC,
                                    display_order ASC,
                                    created_at ASC,
                                    id ASC
                       ) AS normalized_order
                FROM tasks
            )
            UPDATE tasks
            SET display_order = (
                SELECT normalized_order
                FROM ranked_tasks
                WHERE ranked_tasks.id = tasks.id
            )
        )SQL"))) {
        qWarning() << "Failed to normalize task display order:" << query.lastError().text();
        m_db.rollback();
        return false;
    }

    if (!setDatabaseVersion(12)) {
        m_db.rollback();
        return false;
    }
    if (!m_db.commit()) {
        qWarning() << "Failed to commit version 12 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 12";
    return true;
}

bool DatabaseManager::migrateToVersion13()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // v13 只新增课表两表，不读也不写任何既有表，因此与 v3 一样不建迁移快照。
    // 未来若课表迁移开始改动旧表（例如把某类任务转成课表项），必须重新评估备份策略。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start database migration transaction:" << m_db.lastError().text();
        return false;
    }

    // 建表与种默认节次放在同一个事务里：只建了空表却没有节次，
    // 会让「按节次」显示模式打开就是一张空网格，看起来像功能坏了。
    if (!createScheduleTables()
        || !insertDefaultSchedulePeriods()
        || !setDatabaseVersion(13)) {
        m_db.rollback();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit version 13 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 13";
    return true;
}

bool DatabaseManager::migrateToVersion14()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // v14 只新增知识缺口一张表，不读也不写任何既有表，因此与 v13 一样不建迁移快照。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start database migration transaction:" << m_db.lastError().text();
        return false;
    }

    if (!createKnowledgeGapTable() || !setDatabaseVersion(14)) {
        m_db.rollback();
        return false;
    }

    if (!m_db.commit()) {
        qWarning() << "Failed to commit version 14 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 14";
    return true;
}

bool DatabaseManager::migrateToVersion15()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // v15 只给 routines 追加一列，既有行一律取默认值「每天」，升级前后的生成行为完全一致；
    // 不读也不写任何其它表，因此与 v3/v13/v14 一样不建迁移快照。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start database migration transaction:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    // 列可能已经存在：全新库在 v3 建表时就带上了这一列，走到这里只需要把版本号推上去。
    if (!columnExists(QStringLiteral("routines"), QStringLiteral("weekdays"))) {
        const QString addColumn =
            QStringLiteral("ALTER TABLE routines ADD COLUMN weekdays INTEGER NOT NULL "
                           "DEFAULT %1 CHECK(weekdays BETWEEN %2 AND %3)")
                .arg(RoutineRules::kEveryDayMask)
                .arg(RoutineRules::kMinWeekdayMask)
                .arg(RoutineRules::kMaxWeekdayMask);
        if (!query.exec(addColumn)) {
            qWarning() << "Failed to add routines.weekdays column:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    if (!setDatabaseVersion(15) || !m_db.commit()) {
        qWarning() << "Failed to commit version 15 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 15";
    return true;
}

bool DatabaseManager::migrateToVersion16()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // v16 只给 tasks 追加一列，既有任务一律取默认值「没有完成记录」，不改写任何已有数据；
    // 与 v15 一样不建迁移快照。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start database migration transaction:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    // 列可能已经存在：全新库建表时就带上了这一列，v5 整表重建也会把它建出来，
    // 走到这里只需要把版本号推上去。
    if (!columnExists(QStringLiteral("tasks"), QStringLiteral("completion_note"))) {
        if (!query.exec(QStringLiteral(
                "ALTER TABLE tasks ADD COLUMN completion_note TEXT NOT NULL DEFAULT ''"))) {
            qWarning() << "Failed to add tasks.completion_note:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }

    if (!setDatabaseVersion(16) || !m_db.commit()) {
        qWarning() << "Failed to commit version 16 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 16";
    return true;
}

bool DatabaseManager::migrateToVersion17()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // 删表会丢掉用户写下的目标，所以表存在时先建迁移快照（整库副本留在数据目录，保留最近三份）。
    // 表不存在就只推版本号：为这个重建一份整库副本，会挤掉更早、更有用的那份快照。
    const bool hasGoalTable = tableExists(QStringLiteral("long_goals"));
    if (hasGoalTable && !backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 17 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    // 表上的索引 idx_long_goals_order 随表一起删除；没有别的表引用 long_goals。
    if (hasGoalTable && !query.exec(QStringLiteral("DROP TABLE IF EXISTS long_goals"))) {
        qWarning() << "Failed to drop long_goals:" << query.lastError().text();
        m_db.rollback();
        return false;
    }

    if (!setDatabaseVersion(17) || !m_db.commit()) {
        qWarning() << "Failed to commit version 17 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 17";
    return true;
}

// 预置科目的出厂值写成 SQL 的 (VALUES (位置, 名称, 颜色), ...)，v18 回填版本时据此判断预置科目改没改过。
QString DatabaseManager::presetDefaultsValuesSql()
{
    QStringList rows;
    for (int index = 0; index < int(std::size(kPresetCategories)); ++index) {
        rows.append(QStringLiteral("(%1, '%2', '%3')")
                        .arg(index + 1)
                        .arg(QString::fromUtf8(kPresetCategories[index].name),
                             QString::fromLatin1(kPresetCategories[index].color)));
    }
    return QStringLiteral("(VALUES %1)").arg(rows.join(QStringLiteral(", ")));
}

bool DatabaseManager::migrateToVersion18()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }

    // 升到 v18 之后，旧版本应用打不开这个库（createTables 开头拒绝未来版本），所以升级前留一份迁移快照。
    // 同步结构已经完整、只是版本号偏低（重跑、外部改过版本号）时不再建：这个库早就是 v18，
    // 没有新的不可回退；多建一份反而会把更早、更有用的快照挤掉（只保留最近三份）。
    if (!syncSchemaIsComplete() && !backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 18 migration:" << m_db.lastError().text();
        return false;
    }

    QSqlQuery query(m_db);
    const auto run = [this, &query](const QString& sql, const char* context) {
        if (query.exec(sql)) {
            return true;
        }
        qWarning() << context << query.lastError().text();
        m_db.rollback();
        return false;
    };

    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        if (!columnExists(table.name, QStringLiteral("sync_id"))
            && !run(QStringLiteral("ALTER TABLE %1 ADD COLUMN sync_id TEXT").arg(table.name),
                    "Failed to add sync_id column:")) {
            return false;
        }
    }
    for (const QString& sql : SyncSchema::tableStatements() + SyncSchema::seedStatements()) {
        if (!run(sql, "Failed to prepare sync tables:")) {
            return false;
        }
    }

    // 回填身份，只填还没有的。例行要先有 sync_id：例行实例的身份由它和日期算出来。
    const QString random = QStringLiteral("lower(hex(randomblob(16)))");
    const QString instanceId = SyncSchema::routineInstanceSyncIdSql(QStringLiteral("r.sync_id"),
                                                                    QStringLiteral("tasks.date"));
    const QStringList backfill = {
        QStringLiteral("UPDATE routines SET sync_id = %1 WHERE sync_id IS NULL OR sync_id = ''").arg(random),
        // 预置科目按位置取固定身份。同一位置有多行（外部改过库）时只给编号最小的那行，其余走随机。
        QStringLiteral(
            "UPDATE categories SET sync_id = 'preset-' || display_order "
            "WHERE is_preset = 1 AND (sync_id IS NULL OR sync_id = '') "
            "AND id = (SELECT MIN(c2.id) FROM categories c2 "
            "          WHERE c2.is_preset = 1 AND c2.display_order = categories.display_order) "
            "AND NOT EXISTS (SELECT 1 FROM categories c3 "
            "                WHERE c3.sync_id = 'preset-' || categories.display_order)"),
        QStringLiteral("UPDATE categories SET sync_id = %1 WHERE sync_id IS NULL OR sync_id = ''").arg(random),
        // 例行生成的实例：同一例行同一天只认编号最小的那条（正常情况下本来就只有一条）。
        QStringLiteral(
            "UPDATE tasks SET sync_id = (SELECT %1 FROM routines r WHERE r.id = tasks.routine_id) "
            "WHERE (sync_id IS NULL OR sync_id = '') AND routine_generated = 1 AND routine_id IS NOT NULL "
            "AND id = (SELECT MIN(t2.id) FROM tasks t2 WHERE t2.routine_generated = 1 "
            "          AND t2.routine_id = tasks.routine_id AND t2.date = tasks.date) "
            "AND NOT EXISTS (SELECT 1 FROM tasks t3 "
            "                WHERE t3.sync_id = (SELECT %1 FROM routines r WHERE r.id = tasks.routine_id))")
            .arg(instanceId),
        QStringLiteral("UPDATE tasks SET sync_id = %1 WHERE sync_id IS NULL OR sync_id = ''").arg(random),
    };
    // 其余的表（专注、休息，以及第二期的课表、知识缺口、倒计时）没有固定身份，一律随机。
    // 按表清单生成，以后再加同步表也不会漏掉回填；上面几张已经填过的，这里是空操作。
    QStringList randomBackfill;
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        randomBackfill.append(
            QStringLiteral("UPDATE %1 SET sync_id = %2 WHERE sync_id IS NULL OR sync_id = ''").arg(table.name, random));
    }
    for (const QString& sql : backfill + randomBackfill + SyncSchema::indexStatements()) {
        if (!run(sql, "Failed to backfill sync ids:")) {
            return false;
        }
    }

    // 已有记录的初始版本统一取本机此刻的逻辑时间，并放进待发送队列（首次全量发送）。
    // 只处理还没有任何版本的记录：重跑迁移（例如 v5 重建之后）不会把整库重新排一遍队，
    // 已有的版本也保持不动（ON CONFLICT DO NOTHING）。
    if (!run(SyncSchema::sqlAdvanceClock(), "Failed to advance sync clock:")) {
        return false;
    }
    const QString clock = SyncSchema::sqlCurrentClock();
    const QString device = SyncSchema::sqlDeviceId();
    const QString defaults = presetDefaultsValuesSql();
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        const QString published = SyncSchema::publishConditionFor(table, QStringLiteral("r"));
        // 入队要在写版本之前：判据「还没有版本」得在版本写进去之前取。
        const QString enqueue = QStringLiteral(
            "INSERT INTO sync_outbox (tbl, sync_id, change_time) "
            "SELECT '%1', r.sync_id, %2 FROM %1 r "
            "WHERE r.sync_id IS NOT NULL AND %3 "
            "AND NOT EXISTS (SELECT 1 FROM sync_field_versions v WHERE v.tbl = '%1' AND v.sync_id = r.sync_id) "
            "ON CONFLICT(tbl, sync_id) DO NOTHING")
            .arg(table.name, clock, published);
        // 预置科目的版本取最小值（输给任何一次真实修改）的情况：名称、颜色仍是出厂值，
        // 以及位置、预置标记、创建时间这些两台设备各自生成、谁的都行的列。改过的名称、颜色用真实版本，
        // 否则 iPad 上没改过的默认名会在同步时盖掉你在 Mac 上改的名字。
        const QString minimal = table.name == QLatin1String("categories")
            ? QStringLiteral(
                  "(r.is_preset = 1 AND r.sync_id = 'preset-' || r.display_order AND ("
                  "f.column1 NOT IN ('name', 'color') "
                  "OR (f.column1 = 'name' AND r.name = (SELECT d.column2 FROM %1 d WHERE d.column1 = r.display_order)) "
                  "OR (f.column1 = 'color' AND r.color = (SELECT d.column3 FROM %1 d WHERE d.column1 = r.display_order))))")
                  .arg(defaults)
            : QStringLiteral("0");
        // 阶段 1 已写下的备忘录首次加入同步时，内容版本取原来的更新时间。
        // 直接取迁移此刻会让另一台显示“刚刚更新”，两台时间也会不一致；解析失败才退回迁移时间。
        const QString initialClock = table.versionStamp.column.isEmpty() ? clock
            : QStringLiteral("COALESCE(CAST(ROUND((julianday(r.%1) - 2440587.5) * 86400000) AS INTEGER), %2)")
                  .arg(table.versionStamp.column, clock);
        const QString versions = QStringLiteral(
            "INSERT INTO sync_field_versions (tbl, sync_id, field, v_time, v_device, base_time, base_device, pending) "
            "SELECT '%1', r.sync_id, f.column1, CASE WHEN %2 THEN 0 ELSE %3 END, "
            "CASE WHEN %2 THEN '' ELSE %4 END, 0, '', 1 "
            "FROM %1 r, %5 f WHERE r.sync_id IS NOT NULL AND %6 "
            "ON CONFLICT(tbl, sync_id, field) DO NOTHING")
            .arg(table.name, minimal, initialClock, device, SyncSchema::fieldValuesSql(table), published);
        if (!run(enqueue, "Failed to queue existing records for sync:")
            || !run(versions, "Failed to backfill sync field versions:")) {
            return false;
        }
    }

    if (!ensureSyncTriggers() || !setDatabaseVersion(18)) {
        m_db.rollback();
        return false;
    }
    if (!m_db.commit()) {
        qWarning() << "Failed to commit version 18 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qInfo() << "Database migrated to version 18";
    return true;
}

bool DatabaseManager::migrateToVersion19()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot migrate database: database is not open";
        return false;
    }
    // 走到这里时第二期的三张表已经由 v18 那一步补齐了同步结构（加列、回填、入队、触发器），
    // 那一步开头也已经按「结构不完整」存过迁移快照；这里只推版本号，让 v18 的应用拒绝打开。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start version 19 migration:" << m_db.lastError().text();
        return false;
    }
    if (!setDatabaseVersion(19) || !m_db.commit()) {
        qWarning() << "Failed to commit version 19 migration:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }
    qInfo() << "Database migrated to version 19";
    return true;
}

bool DatabaseManager::migrateToVersion20()
{
    if (!m_db.transaction()) {
        qWarning() << "开始数据库 v20 迁移失败：" << m_db.lastError().text();
        return false;
    }
    // 建表、结构检查、同步基础设施全部成功后才标记版本，失败可在下次打开时继续补齐。
    if (!setDatabaseVersion(20) || !m_db.commit()) {
        m_db.rollback();
        return false;
    }
    qInfo() << "数据库已升级到 v20";
    return true;
}

bool DatabaseManager::migrateToVersion21()
{
    if (!m_db.transaction()) {
        qWarning() << "开始数据库 v21 迁移失败：" << m_db.lastError().text();
        return false;
    }
    // 建表与结构检查已在 createTables 里先完成，成功后才标记版本，失败可在下次打开时继续补齐。
    if (!setDatabaseVersion(21) || !m_db.commit()) {
        m_db.rollback();
        return false;
    }
    qInfo() << "数据库已升级到 v21";
    return true;
}

bool DatabaseManager::migrateToVersion22()
{
    // 迁移快照先于 DDL（表结构变更）；建表、继承活动期计数及版本推进必须一起提交。
    // 旧版空档已丢失的计数无法重建，不从历史总数推断用户上次结束循环的时间。
    // 防御性重跑可能只需推进版本；已有表不重建、不覆盖事实，也不额外消耗快照名额。
    if ((!tableExists(QStringLiteral("pomodoro_cycle_state")) && !backupDatabaseBeforeMigration())
        || !m_db.transaction()) return false;
    QSqlQuery query(m_db);
    bool ok = query.exec(pomodoroCycleStateTableSql())
        && query.exec(QStringLiteral("SELECT completed_pomodoros, typeof(completed_pomodoros) "
                                     "FROM active_focus_state WHERE singleton_id=1"));
    qint64 inheritedCount = 0;
    bool invalidLegacyCount = false;
    if (ok && query.next()) {
        // 旧活动行的无效计数不能阻止打开数据库；只接受 SQLite 实际存储的整数，
        // 不把文本或小数经 QVariant 转换后误当作正常计数。没有活动行则沿用从零开始的语义。
        invalidLegacyCount = query.value(1).toString() != QLatin1String("integer")
            || query.value(0).toLongLong() < 0 || query.value(0).toLongLong() > 2147483647;
        if (!invalidLegacyCount) inheritedCount = query.value(0).toLongLong();
    }
    ok = ok && !query.lastError().isValid();
    query.finish();
    if (ok) {
        query.prepare(QStringLiteral("INSERT INTO pomodoro_cycle_state SELECT 1, :count "
                                     "WHERE NOT EXISTS (SELECT 1 FROM pomodoro_cycle_state WHERE singleton_id=1)"));
        query.bindValue(QStringLiteral(":count"), inheritedCount);
        ok = query.exec() && setDatabaseVersion(22);
    }
    if (!ok || !m_db.commit()) {
        qWarning() << "番茄循环状态迁移失败" << query.lastError().text();
        m_db.rollback();
        return false;
    }
    if (invalidLegacyCount) {
        qWarning() << "旧活动番茄循环计数无效，迁移从 0 开始";
    }
    return true;
}
