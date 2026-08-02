#include "BackupOperations.h"

#include <QCoreApplication>
#include <QDataStream>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QSettings>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <QUuid>

#include <memory>

namespace BackupOperations {

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
                while (rows.next()) {
                    const QString key = rows.value(0).toString();
                    QByteArray blob = rows.value(1).toByteArray();
                    QDataStream stream(&blob, QIODevice::ReadOnly);
                    QVariant value;
                    stream >> value;
                    if (stream.status() != QDataStream::Ok) {
                        result.error = QStringLiteral("备份偏好数据已损坏：") + key;
                        ok = false;
                        break;
                    }
                    result.values.insert(key, value);
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
