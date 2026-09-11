#include "BackupOperations.h"

#include "AppSettings.h"
#include "DatabaseManager.h"

#include <QCoreApplication>
#include <QDataStream>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QSettings>
#include <QRegularExpression>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <QUuid>

#include <memory>

namespace BackupOperations {

// 未受信文件的解析上限。设置项都是标量或短字符串，这两个数留了几个数量级余量。
constexpr int kMaxSettingValueBytes = 64 * 1024;
constexpr int kMaxSettingEntries = 500;


namespace {
const auto kFormatVersion = QStringLiteral("1");
const QStringList kRequiredTables = {
    QStringLiteral("tasks"),
    QStringLiteral("focus_sessions"),
    QStringLiteral("categories")
};

QString uniqueConnectionName(const QString& prefix)
{
    return prefix + QUuid::createUuid().toString(QUuid::WithoutBraces);
}

QString escapedSqlString(QString value)
{
    return value.replace(QLatin1Char('\''), QStringLiteral("''"));
}

QString normalizedPath(const QString& path)
{
    const QFileInfo input(path);
    const QString absolutePath = QDir::cleanPath(input.absoluteFilePath());
    const QFileInfo absoluteInfo(absolutePath);
    const QString canonicalPath = absoluteInfo.canonicalFilePath();
    if (!canonicalPath.isEmpty()) {
        return QDir::cleanPath(canonicalPath);
    }

    // 目标文件尚不存在时 canonicalFilePath() 会返回空。向上找到已存在的父目录，
    // 先规范化其中的符号链接，再补回不存在的目录和文件名，避免别名绕过保护检查。
    QStringList missingDirectories;
    QString existingParent = absoluteInfo.absolutePath();
    while (!QFileInfo::exists(existingParent)) {
        const QFileInfo parentInfo(existingParent);
        const QString directoryName = parentInfo.fileName();
        const QString nextParent = parentInfo.absolutePath();
        if (directoryName.isEmpty() || nextParent == existingParent) {
            break;
        }
        missingDirectories.prepend(directoryName);
        existingParent = nextParent;
    }

    QString normalizedParent = QFileInfo(existingParent).canonicalFilePath();
    if (normalizedParent.isEmpty()) {
        normalizedParent = QDir::cleanPath(existingParent);
    }
    for (const QString& directoryName : missingDirectories) {
        normalizedParent = QDir(normalizedParent).filePath(directoryName);
    }
    return QDir::cleanPath(QDir(normalizedParent).filePath(absoluteInfo.fileName()));
}

bool pathsMatch(const QString& leftPath, const QString& rightPath)
{
    return !rightPath.isEmpty() && normalizedPath(leftPath) == normalizedPath(rightPath);
}

bool tableExists(const QSqlDatabase& database, const QString& tableName)
{
    QSqlQuery query(database);
    query.prepare(QStringLiteral(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = :name"));
    query.bindValue(QStringLiteral(":name"), tableName);
    return query.exec() && query.next();
}

QString normalizedCreateSql(QString sql)
{
    sql = sql.toLower();
    sql.remove(QRegularExpression(QStringLiteral("\\s+")));
    sql.remove(QLatin1Char('"'));
    sql.remove(QLatin1Char('`'));
    sql.remove(QLatin1Char('['));
    sql.remove(QLatin1Char(']'));
    return sql;
}

bool validateRequiredTableStructure(const QSqlDatabase& database,
                                    bool requireScheduleTables,
                                    bool requireKnowledgeGapTable,
                                    QString* reason)
{
    struct TableContract {
        QString name;
        QStringList columns;
        QStringList sqlFragments;
    };

    // 这里只校验所有历史版本都依赖、且迁移链无法补回的基础结构。
    // estimated_minutes、mode 等版本列由 DatabaseManager 的防御性迁移补齐；
    // title、start_time 这类基础列一旦缺失，CREATE TABLE IF NOT EXISTS 不会自愈。
    const QList<TableContract> contracts = {
        {QStringLiteral("tasks"),
         {QStringLiteral("id"),
          QStringLiteral("title"),
          QStringLiteral("category"),
          QStringLiteral("date"),
          QStringLiteral("completed"),
          QStringLiteral("created_at")}, {}},
        {QStringLiteral("focus_sessions"),
         {QStringLiteral("id"),
          QStringLiteral("task_id"),
          QStringLiteral("start_time"),
          QStringLiteral("end_time"),
          QStringLiteral("duration")}, {}},
        {QStringLiteral("categories"),
         {QStringLiteral("id"),
          QStringLiteral("name"),
          QStringLiteral("color"),
          QStringLiteral("is_preset"),
          QStringLiteral("display_order"),
          QStringLiteral("created_at")}, {}},
    };

    QList<TableContract> versionedContracts = contracts;
    if (requireScheduleTables) {
        // v13 以后课表已是正式业务数据。不能像老版备份那样容忍表缺失，
        // 否则恢复后迁移会创建一张空表，把“数据丢了”伪装成“恢复成功”。
        versionedContracts.append(
            {QStringLiteral("schedule_entries"),
             {QStringLiteral("id"), QStringLiteral("title"), QStringLiteral("location"),
              QStringLiteral("weekday"), QStringLiteral("start_minutes"),
              QStringLiteral("end_minutes"), QStringLiteral("week_start"),
              QStringLiteral("week_end"), QStringLiteral("week_parity"),
              QStringLiteral("category_id"), QStringLiteral("created_at")},
             {QStringLiteral("check(length(trim(title))>0)"),
              QStringLiteral("check(weekdaybetween1and7)"),
              QStringLiteral("check(start_minutesbetween0and1439)"),
              QStringLiteral("check(end_minutesbetween1and1440)"),
              QStringLiteral("check(week_start>=1)"),
              QStringLiteral("check(week_end>=1)"),
              QStringLiteral("check(week_parityin(0,1,2))"),
              QStringLiteral("check(end_minutes>start_minutes)"),
              QStringLiteral("check(week_end>=week_start)")}});
        versionedContracts.append(
            {QStringLiteral("schedule_periods"),
             {QStringLiteral("id"), QStringLiteral("period_index"),
              QStringLiteral("start_minutes"), QStringLiteral("end_minutes")},
             {QStringLiteral("period_indexintegernotnullunique"),
              QStringLiteral("check(period_index>=1)"),
              QStringLiteral("check(start_minutesbetween0and1439)"),
              QStringLiteral("check(end_minutesbetween1and1440)"),
              QStringLiteral("check(end_minutes>start_minutes)")}});
    }
    if (requireKnowledgeGapTable) {
        // v14 起知识缺口是正式业务数据，且内容全部是用户手写、丢了不可再生。
        // 和课表一样只对 v14 及以后的备份要求这张表：更早的备份本来就没有它，
        // 无条件要求会把全部历史备份判成损坏（业务规则明文禁止这么做）。
        versionedContracts.append(
            {QStringLiteral("knowledge_gaps"),
             {QStringLiteral("id"), QStringLiteral("title"), QStringLiteral("detail"),
              QStringLiteral("category_id"), QStringLiteral("source_task_id"),
              QStringLiteral("source_task_title"), QStringLiteral("priority"),
              QStringLiteral("status"), QStringLiteral("due_date"),
              QStringLiteral("resolution"), QStringLiteral("linked_task_id"),
              QStringLiteral("created_at"), QStringLiteral("updated_at"),
              QStringLiteral("resolved_at")},
             {QStringLiteral("check(length(trim(title))>0)"),
              QStringLiteral("check(priorityin(0,1,2))"),
              QStringLiteral("check(statusin(0,1,2))")}});
    }

    for (const TableContract& contract : versionedContracts) {
        if (!tableExists(database, contract.name)) {
            *reason = QStringLiteral("备份缺少必要的数据表：%1").arg(contract.name);
            return false;
        }
        if ((contract.name.startsWith(QStringLiteral("schedule_"))
             || contract.name == QStringLiteral("knowledge_gaps"))
            && !DatabaseManager::hasGeneratedIntegerId(database, contract.name)) {
            *reason = QStringLiteral("备份表主键不能自动生成整数编号：%1").arg(contract.name);
            return false;
        }
        QSqlQuery columns(database);
        if (!columns.exec(
                QStringLiteral("PRAGMA table_info(%1)").arg(contract.name))) {
            *reason = QStringLiteral("读取备份表结构失败：%1").arg(contract.name);
            return false;
        }

        QStringList names;
        bool idIsPrimaryKey = false;
        while (columns.next()) {
            const QString columnName = columns.value(1).toString();
            names.append(columnName);
            if (columnName == QStringLiteral("id") && columns.value(5).toInt() > 0) {
                idIsPrimaryKey = true;
            }
        }

        for (const QString& requiredColumn : contract.columns) {
            if (!names.contains(requiredColumn)) {
                *reason = QStringLiteral("备份表结构不完整，缺少 %1.%2")
                              .arg(contract.name, requiredColumn);
                return false;
            }
        }
        if (!idIsPrimaryKey) {
            *reason = QStringLiteral("备份表结构不完整，%1.id 不是主键")
                          .arg(contract.name);
            return false;
        }

        if (!contract.sqlFragments.isEmpty()) {
            QSqlQuery sqlQuery(database);
            sqlQuery.prepare(QStringLiteral(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = :name"));
            sqlQuery.bindValue(QStringLiteral(":name"), contract.name);
            if (!sqlQuery.exec() || !sqlQuery.next()) {
                *reason = QStringLiteral("读取备份表约束失败：%1").arg(contract.name);
                return false;
            }
            const QString createSql = normalizedCreateSql(sqlQuery.value(0).toString());
            for (const QString& fragment : contract.sqlFragments) {
                if (!createSql.contains(fragment)) {
                    *reason = QStringLiteral("备份表约束不完整：%1").arg(contract.name);
                    return false;
                }
            }
        }
    }

    if (requireScheduleTables) {
        QSqlQuery foreignKey(database);
        if (!foreignKey.exec(QStringLiteral("PRAGMA foreign_key_list(schedule_entries)"))) {
            *reason = QStringLiteral("读取课表外键失败");
            return false;
        }
        bool categoryForeignKeyFound = false;
        while (foreignKey.next()) {
            if (foreignKey.value(2).toString() == QStringLiteral("categories")
                && foreignKey.value(3).toString() == QStringLiteral("category_id")
                && foreignKey.value(4).toString() == QStringLiteral("id")
                && foreignKey.value(6).toString().compare(
                       QStringLiteral("SET NULL"), Qt::CaseInsensitive) == 0) {
                categoryForeignKeyFound = true;
                break;
            }
        }
        if (!categoryForeignKeyFound) {
            *reason = QStringLiteral("备份课表外键不完整");
            return false;
        }
    }

    // 与启动检查共用同一份外键契约。只看列和 CHECK 会放过 ON DELETE CASCADE 的表：
    // 恢复成功、启动正常，直到删掉一条任务时，关联它的知识缺口被无声地连带删除。
    if (requireKnowledgeGapTable && !DatabaseManager::knowledgeGapForeignKeysAreValid(database)) {
        *reason = QStringLiteral("备份知识缺口外键不完整");
        return false;
    }

    return true;
}

std::unique_ptr<QSettings> makeSettings(const QString& path)
{
    if (path.isEmpty()) {
        return std::make_unique<QSettings>();
    }
    return std::make_unique<QSettings>(path, QSettings::IniFormat);
}

OperationResult embedMetadataAndSettings(const QString& snapshotPath,
                                         const QString& settingsFilePath,
                                         const QString& kind,
                                         int schemaVersion)
{
    OperationResult result;
    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupMetadata_"));
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(snapshotPath);
        if (!database.open()) {
            result.error = QStringLiteral("无法写入备份元数据：") + database.lastError().text();
        } else {
            QSqlQuery query(database);
            auto exec = [&query, &result](const QString& sql, const QString& message) {
                if (query.exec(sql)) {
                    return true;
                }
                result.error = message + QStringLiteral("：") + query.lastError().text();
                return false;
            };

            bool ok = exec(QStringLiteral("PRAGMA user_version = %1").arg(schemaVersion),
                           QStringLiteral("写入数据库版本失败"))
                && exec(QStringLiteral(
                            "CREATE TABLE IF NOT EXISTS backup_meta "
                            "(key TEXT PRIMARY KEY, value TEXT NOT NULL)"),
                        QStringLiteral("创建备份元数据表失败"))
                && exec(QStringLiteral(
                            "CREATE TABLE IF NOT EXISTS backup_settings "
                            "(key TEXT PRIMARY KEY, value BLOB NOT NULL)"),
                        QStringLiteral("创建偏好备份表失败"));

            if (ok && !database.transaction()) {
                result.error = QStringLiteral("启动备份元数据事务失败：") + database.lastError().text();
                ok = false;
            }

            auto putMeta = [&database, &result](const QString& key, const QString& value) {
                QSqlQuery insert(database);
                insert.prepare(QStringLiteral(
                    "INSERT OR REPLACE INTO backup_meta (key, value) VALUES (:key, :value)"));
                insert.bindValue(QStringLiteral(":key"), key);
                insert.bindValue(QStringLiteral(":value"), value);
                if (insert.exec()) {
                    return true;
                }
                result.error = QStringLiteral("写入备份元数据失败：") + insert.lastError().text();
                return false;
            };

            if (ok) {
                const QString applicationVersion =
                    QCoreApplication::applicationVersion().isEmpty()
                    ? QStringLiteral("unknown")
                    : QCoreApplication::applicationVersion();
                ok = putMeta(QStringLiteral("format_version"), kFormatVersion)
                    && putMeta(QStringLiteral("created_at"),
                               QDateTime::currentDateTime().toString(Qt::ISODate))
                    && putMeta(QStringLiteral("app_version"), applicationVersion)
                    && putMeta(QStringLiteral("schema_version"), QString::number(schemaVersion))
                    && putMeta(QStringLiteral("platform"), QStringLiteral("macOS"))
                    && putMeta(QStringLiteral("kind"), kind);
            }

            std::unique_ptr<QSettings> settings;
            if (ok) {
                settings = makeSettings(settingsFilePath);
                settings->sync();
                if (settings->status() != QSettings::NoError) {
                    result.error = QStringLiteral("读取当前偏好失败");
                    ok = false;
                }
            }

            if (ok) {
                for (const QString& key : settings->allKeys()) {
                    QByteArray blob;
                    QDataStream stream(&blob, QIODevice::WriteOnly);
                    stream << settings->value(key);
                    if (stream.status() != QDataStream::Ok) {
                        result.error = QStringLiteral("序列化偏好失败：") + key;
                        ok = false;
                        break;
                    }

                    QSqlQuery insert(database);
                    insert.prepare(QStringLiteral(
                        "INSERT OR REPLACE INTO backup_settings (key, value) "
                        "VALUES (:key, :value)"));
                    insert.bindValue(QStringLiteral(":key"), key);
                    insert.bindValue(QStringLiteral(":value"), blob);
                    if (!insert.exec()) {
                        result.error = QStringLiteral("写入偏好备份失败：")
                            + insert.lastError().text();
                        ok = false;
                        break;
                    }
                }
            }

            if (ok) {
                if (!database.commit()) {
                    result.error = QStringLiteral("提交备份元数据失败：")
                        + database.lastError().text();
                    ok = false;
                    database.rollback();
                }
            } else if (database.isOpen()) {
                database.rollback();
            }

            result.success = ok;
            database.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);
    return result;
}

} // namespace

OperationResult atomicCopy(const QString& sourcePath, const QString& destinationPath)
{
    OperationResult result;
    QFile source(sourcePath);
    if (!source.open(QIODevice::ReadOnly)) {
        result.error = QStringLiteral("无法读取源文件：") + source.errorString();
        return result;
    }

    const QFileInfo destinationInfo(destinationPath);
    if (!QDir().mkpath(destinationInfo.absolutePath())) {
        result.error = QStringLiteral("无法创建目标目录");
        return result;
    }

    // QSaveFile 在同目录写临时文件并用原子替换提交。禁止直接写回退，确保失败时旧文件仍完整。
    QSaveFile destination(destinationPath);
    destination.setDirectWriteFallback(false);
    if (!destination.open(QIODevice::WriteOnly)) {
        result.error = QStringLiteral("无法创建目标文件：") + destination.errorString();
        return result;
    }

    constexpr qint64 kChunkSize = 1024 * 1024;
    while (!source.atEnd()) {
        const QByteArray chunk = source.read(kChunkSize);
        if (chunk.isEmpty() && source.error() != QFileDevice::NoError) {
            destination.cancelWriting();
            result.error = QStringLiteral("读取源文件失败：") + source.errorString();
            return result;
        }
        if (destination.write(chunk) != chunk.size()) {
            destination.cancelWriting();
            result.error = QStringLiteral("写入目标文件失败：") + destination.errorString();
            return result;
        }
    }

    if (!destination.commit()) {
        result.error = QStringLiteral("原子替换目标文件失败：") + destination.errorString();
        return result;
    }

    result.success = true;
    return result;
}

OperationResult createSnapshot(const QString& sourceDatabasePath,
                               const QString& settingsFilePath,
                               const QString& destinationPath,
                               const QString& kind,
                               int currentSchemaVersion)
{
    OperationResult result;
    if (sourceDatabasePath.isEmpty() || !QFileInfo::exists(sourceDatabasePath)) {
        result.error = QStringLiteral("数据库路径无效");
        return result;
    }
    if (destinationPath.trimmed().isEmpty()) {
        result.error = QStringLiteral("备份目标路径为空");
        return result;
    }

    if (pathsMatch(destinationPath, sourceDatabasePath)) {
        result.error = QStringLiteral("备份目标不能覆盖正在使用的数据库");
        return result;
    }

    // SQLite 的 WAL/SHM/journal 和 QSettings 锁文件都可能在运行时被写入；即使目标文件
    // 还不存在，也必须按规范化路径拒绝，避免快照的原子替换破坏当前进程的数据或偏好。
    const QString effectiveSettingsPath = makeSettings(settingsFilePath)->fileName();
    QStringList protectedRuntimeFiles = {
        sourceDatabasePath + QStringLiteral("-wal"),
        sourceDatabasePath + QStringLiteral("-shm"),
        sourceDatabasePath + QStringLiteral("-journal")
    };
    if (!effectiveSettingsPath.isEmpty()) {
        protectedRuntimeFiles.append(effectiveSettingsPath);
        protectedRuntimeFiles.append(effectiveSettingsPath + QStringLiteral(".lock"));
    }
    for (const QString& protectedPath : protectedRuntimeFiles) {
        if (pathsMatch(destinationPath, protectedPath)) {
            result.error = protectedPath == effectiveSettingsPath
                ? QStringLiteral("备份目标不能覆盖当前设置文件")
                : QStringLiteral("备份目标不能覆盖运行时受保护文件");
            return result;
        }
    }

    const QFileInfo destinationInfo(destinationPath);
    if (!QDir().mkpath(destinationInfo.absolutePath())) {
        result.error = QStringLiteral("无法创建备份目录");
        return result;
    }

    const QString temporaryPath = destinationPath + QStringLiteral(".tmp-")
        + QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupSnapshot_"));
    int schemaVersion = -1;
    {
        QSqlDatabase source = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        source.setDatabaseName(sourceDatabasePath);
        if (!source.open()) {
            result.error = QStringLiteral("无法打开数据库快照连接：") + source.lastError().text();
        } else {
            {
                QSqlQuery timeout(source);
                if (!timeout.exec(QStringLiteral("PRAGMA busy_timeout = 5000"))) {
                    result.error = QStringLiteral("设置数据库快照等待时间失败：")
                        + timeout.lastError().text();
                }
            }
            if (result.error.isEmpty()) {
                QSqlQuery version(source);
                if (!version.exec(QStringLiteral("PRAGMA user_version")) || !version.next()) {
                    result.error = QStringLiteral("读取数据库版本失败：")
                        + version.lastError().text();
                } else {
                    schemaVersion = version.value(0).toInt();
                }
            }

            if (result.error.isEmpty()
                && (schemaVersion < 0 || schemaVersion > currentSchemaVersion)) {
                result.error = QStringLiteral("当前数据库版本不受支持，无法备份");
            }

            if (result.error.isEmpty()) {
                QSqlQuery vacuum(source);
                const QString sql = QStringLiteral("VACUUM main INTO '%1'")
                    .arg(escapedSqlString(temporaryPath));
                if (!vacuum.exec(sql)) {
                    result.error = QStringLiteral("生成数据库快照失败：")
                        + vacuum.lastError().text();
                }
            }
            source.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);

    if (!result.error.isEmpty()) {
        QFile::remove(temporaryPath);
        return result;
    }

    result = embedMetadataAndSettings(
        temporaryPath, settingsFilePath, kind, schemaVersion);
    if (!result.success) {
        QFile::remove(temporaryPath);
        return result;
    }

    result = atomicCopy(temporaryPath, destinationPath);
    QFile::remove(temporaryPath);
    return result;
}

QVariantMap inspectBackup(const QString& sourcePath, int currentSchemaVersion)
{
    QVariantMap result;
    result.insert(QStringLiteral("valid"), false);

    const QFileInfo info(sourcePath);
    if (!info.exists() || !info.isFile() || !info.isReadable()) {
        result.insert(QStringLiteral("reason"), QStringLiteral("备份文件不存在或无法读取"));
        return result;
    }

    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupInspect_"));
    QString reason;
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(sourcePath);
        database.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        if (!database.open()) {
            reason = QStringLiteral("这不是有效的备份文件");
        } else {
            QSqlQuery integrity(database);
            if (!integrity.exec(QStringLiteral("PRAGMA integrity_check")) || !integrity.next()
                || integrity.value(0).toString() != QStringLiteral("ok")) {
                reason = QStringLiteral("备份文件已损坏，无法恢复");
            }

            if (reason.isEmpty()) {
                for (const QString& table : kRequiredTables) {
                    if (!tableExists(database, table)) {
                        reason = QStringLiteral("备份缺少必要的数据表，可能不是本应用的备份");
                        break;
                    }
                }
            }

            if (reason.isEmpty()
                && (!tableExists(database, QStringLiteral("backup_meta"))
                    || !tableExists(database, QStringLiteral("backup_settings")))) {
                reason = QStringLiteral("备份缺少格式信息或偏好数据");
            }

            QVariantMap metadata;
            if (reason.isEmpty()) {
                QSqlQuery meta(database);
                if (!meta.exec(QStringLiteral("SELECT key, value FROM backup_meta"))) {
                    reason = QStringLiteral("读取备份格式信息失败");
                } else {
                    while (meta.next()) {
                        metadata.insert(meta.value(0).toString(), meta.value(1).toString());
                    }
                }
            }

            if (reason.isEmpty()
                && metadata.value(QStringLiteral("format_version")).toString() != kFormatVersion) {
                reason = QStringLiteral("该备份格式不受当前版本支持");
            }

            bool metadataVersionValid = false;
            const int metadataVersion =
                metadata.value(QStringLiteral("schema_version")).toString()
                    .toInt(&metadataVersionValid);
            int pragmaVersion = -1;
            if (reason.isEmpty()) {
                QSqlQuery version(database);
                if (!version.exec(QStringLiteral("PRAGMA user_version")) || !version.next()) {
                    reason = QStringLiteral("读取备份数据库版本失败");
                } else {
                    pragmaVersion = version.value(0).toInt();
                }
            }

            if (reason.isEmpty()
                && (!metadataVersionValid || metadataVersion < 0
                    || metadataVersion != pragmaVersion)) {
                reason = QStringLiteral("备份版本信息不一致，无法安全恢复");
            }
            if (reason.isEmpty() && pragmaVersion > currentSchemaVersion) {
                reason = QStringLiteral("该备份由更高版本创建，当前版本无法恢复");
            }
            if (reason.isEmpty()) {
                validateRequiredTableStructure(database,
                                               pragmaVersion >= 13,
                                               pragmaVersion >= 14,
                                               &reason);
            }

            // 备份是数据，不是可信的数据库程序。
            //
            // 恢复把外部文件整个复制成主库，此前只校验完整性、必要表、版本和条数——
            // 一个 Trigger 就能随备份永久活进用户库里，之后每次增删改任务都静默执行，
            // 而恢复前快照根本发现不了这种延迟触发的破坏。View 与虚拟表同理
            // （虚拟表还能把模块名当作加载路径）。
            //
            // 本应用自己从不创建 Trigger / View / 虚拟表，所以判据可以很硬：
            // sqlite_master 里出现表和索引以外的任何对象，一律拒绝恢复。
            if (reason.isEmpty()) {
                QSqlQuery objects(database);
                if (!objects.exec(QStringLiteral(
                        "SELECT type, name FROM sqlite_master "
                        "WHERE type NOT IN ('table', 'index')"))) {
                    reason = QStringLiteral("读取备份结构失败");
                } else if (objects.next()) {
                    reason = QStringLiteral("备份包含本应用不会创建的数据库对象（%1 %2），"
                                            "出于安全考虑拒绝恢复")
                                 .arg(objects.value(0).toString(), objects.value(1).toString());
                }
            }
            // 虚拟表在 sqlite_master 里 type 也是 'table'，靠 SQL 文本识别。
            if (reason.isEmpty()) {
                QSqlQuery virtualTables(database);
                if (!virtualTables.exec(QStringLiteral(
                        "SELECT name FROM sqlite_master WHERE type = 'table' "
                        "AND sql LIKE 'CREATE VIRTUAL%'"))) {
                    reason = QStringLiteral("读取备份结构失败");
                } else if (virtualTables.next()) {
                    reason = QStringLiteral("备份包含虚拟表（%1），出于安全考虑拒绝恢复")
                                 .arg(virtualTables.value(0).toString());
                }
            }

            if (reason.isEmpty()) {
                for (auto it = metadata.constBegin(); it != metadata.constEnd(); ++it) {
                    result.insert(it.key(), it.value());
                }
                result.insert(QStringLiteral("schemaVersion"), pragmaVersion);

                QSqlQuery count(database);
                if (!count.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")) || !count.next()) {
                    reason = QStringLiteral("读取备份任务数量失败");
                } else {
                    result.insert(QStringLiteral("taskCount"), count.value(0).toInt());
                }
                if (reason.isEmpty()
                    && (!count.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions"))
                        || !count.next())) {
                    reason = QStringLiteral("读取备份专注记录数量失败");
                } else if (reason.isEmpty()) {
                    result.insert(QStringLiteral("sessionCount"), count.value(0).toInt());
                }
            }
            database.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);

    result.insert(QStringLiteral("valid"), reason.isEmpty());
    result.insert(QStringLiteral("reason"), reason);
    return result;
}

EmbeddedSettingsResult readEmbeddedSettings(const QString& sourcePath)
{
    EmbeddedSettingsResult result;
    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupSettingsRead_"));
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
        database.setDatabaseName(sourcePath);
        database.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        if (!database.open()) {
            result.error = QStringLiteral("无法读取备份偏好：") + database.lastError().text();
        } else if (!tableExists(database, QStringLiteral("backup_settings"))) {
            result.error = QStringLiteral("备份缺少偏好数据");
        } else {
            QSqlQuery rows(database);
            if (!rows.exec(QStringLiteral("SELECT key, value FROM backup_settings"))) {
                result.error = QStringLiteral("读取备份偏好失败：") + rows.lastError().text();
            } else {
                bool ok = true;
                int skipped = 0;
                while (rows.next()) {
                    const QString key = rows.value(0).toString();

                    // 只恢复本应用拥有的键。备份文件是外部输入——可能来自别的版本、
                    // 被手工改过、或者干脆是伪造的。写回陌生键既没有意义，
                    // 又会在自己的偏好文件里留下永远不会被清理的垃圾。
                    if (!AppSettings::isOwnedSettingKey(key)) {
                        ++skipped;
                        continue;
                    }

                    QByteArray blob = rows.value(1).toByteArray();
                    // 单个值的字节数上限。QDataStream 解 QVariant 时会先读出容器长度
                    // 再按该长度预留空间，一个被篡改的长度字段能让这里试图分配几个 GB。
                    // 正常设置值都是标量或短字符串，这个上限留了几个数量级的余量。
                    if (blob.size() > kMaxSettingValueBytes) {
                        result.error = QStringLiteral("备份偏好数据异常：%1 的值过大").arg(key);
                        ok = false;
                        break;
                    }

                    QDataStream stream(&blob, QIODevice::ReadOnly);
                    QVariant value;
                    stream >> value;
                    if (stream.status() != QDataStream::Ok) {
                        result.error = QStringLiteral("备份偏好数据已损坏：") + key;
                        ok = false;
                        break;
                    }
                    result.values.insert(key, value);

                    if (result.values.size() > kMaxSettingEntries) {
                        result.error = QStringLiteral("备份偏好条目过多");
                        ok = false;
                        break;
                    }
                }
                if (ok && skipped > 0) {
                    // 不静默：丢了什么必须留下痕迹，否则用户只会发现"恢复后某项没回来"。
                    qInfo() << "Restore skipped" << skipped
                            << "unrecognised setting key(s) from backup";
                }
                result.success = ok;
            }
            database.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);
    return result;
}

} // namespace BackupOperations
