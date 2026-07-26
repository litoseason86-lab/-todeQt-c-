#include "BackupService.h"

#include "AppSettings.h"
#include "BackupOperations.h"
#include "DatabaseManager.h"
#include "FocusTimer.h"

#include <QDateTime>
#include <QDebug>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QSettings>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QUrl>
#include <QtConcurrent>

#include <memory>

namespace {
const auto kBackupExtension = QStringLiteral(".tomatobackup");
const auto kAutoPrefix = QStringLiteral("auto-");
const auto kBeforeRestorePrefix = QStringLiteral("before-restore-");
const auto kAutoEnabledKey = QStringLiteral("backup/autoEnabled");
const auto kLastBackupIsoKey = QStringLiteral("backup/lastBackupIso");

QString timestampToken()
{
    return QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss-zzz"));
}

std::unique_ptr<QSettings> makeSettings(const QString& path)
{
    if (path.isEmpty()) {
        return std::make_unique<QSettings>();
    }
    return std::make_unique<QSettings>(path, QSettings::IniFormat);
}

QVariantMap settingsWithLocalBackupPolicy(const QVariantMap& restored,
                                          const QVariantMap& current)
{
    QVariantMap result;
    for (auto it = restored.constBegin(); it != restored.constEnd(); ++it) {
        if (!it.key().startsWith(QStringLiteral("backup/"))) {
            result.insert(it.key(), it.value());
        }
    }
    // 自动备份开关和上次执行时间属于当前设备策略，不随数据备份跨设备回滚。
    for (auto it = current.constBegin(); it != current.constEnd(); ++it) {
        if (it.key().startsWith(QStringLiteral("backup/"))) {
            result.insert(it.key(), it.value());
        }
    }
    return result;
}

struct RestorePreflightResult
{
    bool success = false;
    QString error;
    QVariantMap restoredSettings;
};

} // namespace

struct BackupService::RestoreContext
{
    QString sourcePath;
    QString databasePath;
    QString preRestorePath;
    QVariantMap originalSettings;
    QVariantMap restoredSettings;
};

BackupService::BackupService(QObject* parent)
    : QObject(parent)
{
}

BackupService* BackupService::instance()
{
    static BackupService service;
    return &service;
}

void BackupService::configure(const QString& settingsFilePath, const QString& backupsDir)
{
    m_settingsFilePath = settingsFilePath;
    m_backupsDir = backupsDir;
}

QString BackupService::backupFileExtension() const
{
    return kBackupExtension;
}

QString BackupService::lastError() const
{
    return m_lastError;
}

void BackupService::setLastError(const QString& message) const
{
    m_lastError = message;
    if (!message.isEmpty()) {
        qWarning() << "BackupService:" << message;
    }
}

bool BackupService::busy() const
{
    return m_busy;
}

bool BackupService::operationBlocksUi() const
{
    return m_operationBlocksUi;
}

QString BackupService::operationText() const
{
    return m_operationText;
}

void BackupService::setBusy(bool busy,
                            const QString& operationText,
                            bool operationBlocksUi)
{
    if (m_busy != busy) {
        m_busy = busy;
        emit busyChanged();
    }
    if (m_operationText != operationText) {
        m_operationText = operationText;
        emit operationTextChanged();
    }
    const bool nextBlocksUi = busy && operationBlocksUi;
    if (m_operationBlocksUi != nextBlocksUi) {
        m_operationBlocksUi = nextBlocksUi;
        emit operationBlocksUiChanged();
    }
}

QString BackupService::databasePath() const
{
    return DatabaseManager::instance()->database().databaseName();
}

QString BackupService::autoBackupsDir() const
{
    if (!m_backupsDir.isEmpty()) {
        return m_backupsDir;
    }
    const QString dbPath = databasePath();
    if (!dbPath.isEmpty()) {
        return QDir(QFileInfo(dbPath).absolutePath()).filePath(QStringLiteral("backups"));
    }
    const QString dataDir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return QDir(dataDir).filePath(QStringLiteral("backups"));
}

QString BackupService::backupsDirectory() const
{
    return autoBackupsDir();
}

QString BackupService::suggestedBackupFileName() const
{
    return QStringLiteral("番茄Todo-备份-%1%2")
        .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss")),
             kBackupExtension);
}

bool BackupService::autoBackupEnabled() const
{
    std::unique_ptr<QSettings> settings = makeSettings(m_settingsFilePath);
    return settings->value(kAutoEnabledKey, true).toBool();
}

void BackupService::setAutoBackupEnabled(bool enabled)
{
    if (autoBackupEnabled() == enabled) {
        return;
    }

    std::unique_ptr<QSettings> settings = makeSettings(m_settingsFilePath);
    settings->setValue(kAutoEnabledKey, enabled);
    settings->sync();
    if (settings->status() != QSettings::NoError) {
        setLastError(QStringLiteral("自动备份设置保存失败"));
        return;
    }
    emit autoBackupEnabledChanged();
}

QString BackupService::lastBackupTimeIso() const
{
    std::unique_ptr<QSettings> settings = makeSettings(m_settingsFilePath);
    return settings->value(kLastBackupIsoKey).toString();
}

bool BackupService::writeSnapshot(const QString& destPath, const QString& kind)
{
    const QString sourcePath = databasePath();
    if (sourcePath.isEmpty() || !DatabaseManager::instance()->isOpen()) {
        setLastError(QStringLiteral("数据库未打开，无法备份"));
        return false;
    }

    const BackupOperations::OperationResult result =
        BackupOperations::createSnapshot(sourcePath,
                                         m_settingsFilePath,
                                         destPath,
                                         kind,
                                         DatabaseManager::kCurrentSchemaVersion);
    setLastError(result.success ? QString() : result.error);
    return result.success;
}

bool BackupService::createBackup(const QString& destPath)
{
    setLastError(QString());
    const bool ok = writeSnapshot(destPath, QStringLiteral("manual"));
    emit backupCompleted(ok, ok ? QStringLiteral("备份已保存") : m_lastError);
    return ok;
}

QVariantMap BackupService::inspectBackup(const QString& srcPath) const
{
    return BackupOperations::inspectBackup(
        srcPath, DatabaseManager::kCurrentSchemaVersion);
}

QVariantMap BackupService::readBackupInfo(const QString& srcPath) const
{
    return inspectBackup(srcPath);
}

QVariantMap BackupService::currentSettingsSnapshot(bool* ok) const
{
    QVariantMap result;
    std::unique_ptr<QSettings> settings = makeSettings(m_settingsFilePath);
    settings->sync();
    if (settings->status() != QSettings::NoError) {
        if (ok) {
            *ok = false;
        }
        return result;
    }

    for (const QString& key : settings->allKeys()) {
        result.insert(key, settings->value(key));
    }
    if (ok) {
        *ok = true;
    }
    return result;
}

bool BackupService::applySettingsSnapshot(const QVariantMap& values) const
{
    std::unique_ptr<QSettings> settings = makeSettings(m_settingsFilePath);
    settings->clear();
    for (auto it = values.constBegin(); it != values.constEnd(); ++it) {
        settings->setValue(it.key(), it.value());
    }
    settings->sync();
    return settings->status() == QSettings::NoError;
}

bool BackupService::verifyRestoredDatabase() const
{
    const QSqlDatabase database = DatabaseManager::instance()->database();
    if (!database.isOpen()) {
        return false;
    }

    for (const QString& table : {
             QStringLiteral("tasks"),
             QStringLiteral("focus_sessions"),
             QStringLiteral("categories")}) {
        QSqlQuery verify(database);
        if (!verify.exec(QStringLiteral("SELECT COUNT(*) FROM %1").arg(table))
            || !verify.next()) {
            return false;
        }
    }
    return true;
}

bool BackupService::cleanBackupTables() const
{
    QSqlDatabase database = DatabaseManager::instance()->database();
    if (!database.isOpen() || !database.transaction()) {
        return false;
    }

    QSqlQuery drop(database);
    if (!drop.exec(QStringLiteral("DROP TABLE IF EXISTS backup_meta"))
        || !drop.exec(QStringLiteral("DROP TABLE IF EXISTS backup_settings"))
        || !database.commit()) {
        database.rollback();
        return false;
    }
    return true;
}

bool BackupService::restoreFromPreRestoreSnapshot(const QString& preRestorePath,
                                                  const QString& dbPath,
                                                  const QVariantMap& originalSettings,
                                                  QString* error)
{
    DatabaseManager::instance()->close();
    const BackupOperations::OperationResult copy =
        BackupOperations::atomicCopy(preRestorePath, dbPath);
    if (!copy.success) {
        // 与异步回滚同理：拷贝失败不代表原库损坏，必须把连接重新打开，
        // 否则调用方拿到 false 之后整个应用没有数据库可用。
        const bool reopened = DatabaseManager::instance()->initialize(dbPath);
        if (error) {
            *error = reopened
                ? QStringLiteral("自动回滚失败：%1。恢复前备份仍保留在 %2")
                      .arg(copy.error, preRestorePath)
                : QStringLiteral("自动回滚失败且数据库无法打开：%1。恢复前备份仍保留在 %2")
                      .arg(copy.error, preRestorePath);
        }
        return false;
    }

    if (!DatabaseManager::instance()->initialize(dbPath)
        || !verifyRestoredDatabase()
        || !cleanBackupTables()) {
        if (error) {
            *error = QStringLiteral("恢复原数据库后重新初始化失败，恢复前备份保留在 ")
                + preRestorePath;
        }
        return false;
    }

    if (!applySettingsSnapshot(originalSettings)) {
        if (error) {
            *error = QStringLiteral("数据库已回滚，但原设置恢复失败");
        }
        return false;
    }
    if (m_settingsFilePath.isEmpty()) {
        AppSettings::instance()->reload();
    }
    if (!FocusTimer::instance()->restoreInterruptedSession()) {
        if (error) {
            *error = QStringLiteral("数据库已回滚，但计时运行态重新加载失败");
        }
        return false;
    }
    return true;
}

bool BackupService::restoreBackup(const QString& srcPath)
{
    setLastError(QString());
    if (m_busy) {
        setLastError(QStringLiteral("已有备份或恢复任务正在执行"));
        emit restoreCompleted(false, m_lastError);
        return false;
    }
    if (FocusTimer::instance()->hasActiveSession()
        || FocusTimer::instance()->phase() != FocusTimer::NoPhase
        || FocusTimer::instance()->isRunning()) {
        setLastError(QStringLiteral("请先结束当前专注或休息，再恢复备份"));
        emit restoreCompleted(false, m_lastError);
        return false;
    }

    const QVariantMap info = inspectBackup(srcPath);
    if (!info.value(QStringLiteral("valid")).toBool()) {
        setLastError(info.value(QStringLiteral("reason")).toString());
        emit restoreCompleted(false, m_lastError);
        return false;
    }

    const QString dbPath = databasePath();
    if (dbPath.isEmpty()) {
        setLastError(QStringLiteral("数据库未打开，无法恢复"));
        emit restoreCompleted(false, m_lastError);
        return false;
    }

    bool settingsOk = false;
    const QVariantMap originalSettings = currentSettingsSnapshot(&settingsOk);
    if (!settingsOk) {
        setLastError(QStringLiteral("读取当前设置失败，已中止恢复"));
        emit restoreCompleted(false, m_lastError);
        return false;
    }

    const BackupOperations::EmbeddedSettingsResult restoredSettings =
        BackupOperations::readEmbeddedSettings(srcPath);
    if (!restoredSettings.success) {
        setLastError(restoredSettings.error);
        emit restoreCompleted(false, m_lastError);
        return false;
    }

    if (!QDir().mkpath(autoBackupsDir())) {
        setLastError(QStringLiteral("无法创建备份目录"));
        emit restoreCompleted(false, m_lastError);
        return false;
    }
    const QString preRestorePath = QDir(autoBackupsDir()).filePath(
        kBeforeRestorePrefix + timestampToken() + kBackupExtension);
    emit restoreStarted();
    if (!writeSnapshot(preRestorePath, QStringLiteral("before-restore"))) {
        emit restoreCompleted(
            false, QStringLiteral("恢复前备份当前数据失败，已中止：") + m_lastError);
        return false;
    }

    DatabaseManager::instance()->close();
    const BackupOperations::OperationResult install =
        BackupOperations::atomicCopy(srcPath, dbPath);
    bool ok = install.success
        && DatabaseManager::instance()->initialize(dbPath)
        && verifyRestoredDatabase()
        && cleanBackupTables();

    const QVariantMap targetSettings =
        settingsWithLocalBackupPolicy(restoredSettings.values, originalSettings);
    if (ok) {
        ok = applySettingsSnapshot(targetSettings);
    }
    if (ok && m_settingsFilePath.isEmpty()) {
        AppSettings::instance()->reload();
    }
    if (ok) {
        ok = FocusTimer::instance()->restoreInterruptedSession();
    }

    if (!ok) {
        QString rollbackError;
        const bool rolledBack = restoreFromPreRestoreSnapshot(
            preRestorePath, dbPath, originalSettings, &rollbackError);
        setLastError(rolledBack
                         ? QStringLiteral("恢复失败，已安全回滚到恢复前数据")
                         : rollbackError);
        emit restoreCompleted(false, m_lastError);
        return false;
    }

    emit restoreCompleted(true, QStringLiteral("恢复完成"));
    return true;
}

void BackupService::startBackupJob(const QString& destinationPath,
                                   const QString& kind,
                                   bool automatic)
{
    if (m_busy) {
        if (!automatic) {
            emit backupCompleted(false, QStringLiteral("已有备份或恢复任务正在执行"));
        }
        return;
    }

    const QString sourcePath = databasePath();
    if (sourcePath.isEmpty() || !DatabaseManager::instance()->isOpen()) {
        if (!automatic) {
            emit backupCompleted(false, QStringLiteral("数据库未打开，无法备份"));
        }
        return;
    }

    setBusy(true,
            automatic ? QStringLiteral("正在自动备份")
                      : QStringLiteral("正在创建备份"),
            !automatic);
    auto* watcher = new QFutureWatcher<BackupOperations::OperationResult>(this);
    connect(watcher, &QFutureWatcherBase::finished, this,
            [this, watcher, automatic]() {
        const BackupOperations::OperationResult result = watcher->result();
        watcher->deleteLater();

        if (automatic && result.success) {
            std::unique_ptr<QSettings> settings = makeSettings(m_settingsFilePath);
            settings->setValue(
                kLastBackupIsoKey, QDateTime::currentDateTime().toString(Qt::ISODate));
            settings->sync();
            if (settings->status() == QSettings::NoError) {
                pruneAutoBackups();
                emit lastBackupTimeChanged();
            } else {
                qWarning() << "自动备份完成，但时间记录保存失败";
            }
        }

        setLastError(result.success ? QString() : result.error);
        setBusy(false);
        if (!automatic) {
            emit backupCompleted(
                result.success,
                result.success ? QStringLiteral("备份已保存") : result.error);
        } else if (!result.success) {
            qWarning() << "自动备份失败:" << result.error;
        }
    });

    watcher->setFuture(QtConcurrent::run(
        [sourcePath,
         settingsPath = m_settingsFilePath,
         destinationPath,
         kind]() {
            return BackupOperations::createSnapshot(
                sourcePath,
                settingsPath,
                destinationPath,
                kind,
                DatabaseManager::kCurrentSchemaVersion);
        }));
}

void BackupService::requestBackup(const QString& destPath)
{
    startBackupJob(destPath, QStringLiteral("manual"), false);
}

void BackupService::requestBackupInfo(const QString& srcPath)
{
    if (m_busy) {
        QVariantMap info;
        info.insert(QStringLiteral("valid"), false);
        info.insert(QStringLiteral("reason"), QStringLiteral("已有备份或恢复任务正在执行"));
        emit backupInfoReady(srcPath, info);
        return;
    }

    setBusy(true, QStringLiteral("正在校验备份"), true);
    auto* watcher = new QFutureWatcher<QVariantMap>(this);
    connect(watcher, &QFutureWatcherBase::finished, this,
            [this, watcher, srcPath]() {
        const QVariantMap info = watcher->result();
        watcher->deleteLater();
        setBusy(false);
        emit backupInfoReady(srcPath, info);
    });
    watcher->setFuture(QtConcurrent::run([srcPath]() {
        return BackupOperations::inspectBackup(
            srcPath, DatabaseManager::kCurrentSchemaVersion);
    }));
}

void BackupService::requestRestore(const QString& srcPath)
{
    if (m_busy) {
        emit restoreCompleted(false, QStringLiteral("已有备份或恢复任务正在执行"));
        return;
    }
    if (FocusTimer::instance()->hasActiveSession()
        || FocusTimer::instance()->phase() != FocusTimer::NoPhase
        || FocusTimer::instance()->isRunning()) {
        emit restoreCompleted(false, QStringLiteral("请先结束当前专注或休息，再恢复备份"));
        return;
    }

    const QString dbPath = databasePath();
    if (dbPath.isEmpty() || !DatabaseManager::instance()->isOpen()) {
        emit restoreCompleted(false, QStringLiteral("数据库未打开，无法恢复"));
        return;
    }

    bool settingsOk = false;
    const QVariantMap originalSettings = currentSettingsSnapshot(&settingsOk);
    if (!settingsOk) {
        emit restoreCompleted(false, QStringLiteral("读取当前设置失败，已中止恢复"));
        return;
    }

    auto context = QSharedPointer<RestoreContext>::create();
    context->sourcePath = srcPath;
    context->databasePath = dbPath;
    context->preRestorePath = QDir(autoBackupsDir()).filePath(
        kBeforeRestorePrefix + timestampToken() + kBackupExtension);
    context->originalSettings = originalSettings;

    setBusy(true, QStringLiteral("正在校验恢复文件"), true);
    emit restoreStarted();

    auto* watcher = new QFutureWatcher<RestorePreflightResult>(this);
    connect(watcher, &QFutureWatcherBase::finished, this,
            [this, watcher, context]() {
        const RestorePreflightResult result = watcher->result();
        watcher->deleteLater();
        if (!result.success) {
            setLastError(result.error);
            setBusy(false);
            emit restoreCompleted(false, result.error);
            return;
        }
        context->restoredSettings = result.restoredSettings;
        installPreparedRestore(context);
    });
    watcher->setFuture(QtConcurrent::run([srcPath]() {
        RestorePreflightResult result;
        const QVariantMap info = BackupOperations::inspectBackup(
            srcPath, DatabaseManager::kCurrentSchemaVersion);
        if (!info.value(QStringLiteral("valid")).toBool()) {
            result.error = info.value(QStringLiteral("reason")).toString();
            return result;
        }

        const BackupOperations::EmbeddedSettingsResult settings =
            BackupOperations::readEmbeddedSettings(srcPath);
        result.success = settings.success;
        result.error = settings.error;
        result.restoredSettings = settings.values;
        return result;
    }));
}

void BackupService::installPreparedRestore(
    const QSharedPointer<RestoreContext>& context)
{
    // 从此刻起关闭主连接，后台线程才能得到一个精确且不会再被业务层修改的恢复前快照。
    DatabaseManager::instance()->close();
    setBusy(true, QStringLiteral("正在备份当前数据并恢复"), true);

    auto* watcher = new QFutureWatcher<BackupOperations::OperationResult>(this);
    connect(watcher, &QFutureWatcherBase::finished, this,
            [this, watcher, context]() {
        const BackupOperations::OperationResult result = watcher->result();
        watcher->deleteLater();
        if (!result.success) {
            // 原子安装失败时旧数据库仍在原路径，只需重新打开；恢复前快照若已生成则继续保留。
            const bool reopened =
                DatabaseManager::instance()->initialize(context->databasePath);
            const QString message = reopened
                ? QStringLiteral("恢复失败，原数据未改动：") + result.error
                : QStringLiteral("恢复失败且数据库重新打开失败：") + result.error;
            setLastError(message);
            setBusy(false);
            emit restoreCompleted(false, message);
            return;
        }

        bool ok = DatabaseManager::instance()->initialize(context->databasePath)
            && verifyRestoredDatabase()
            && cleanBackupTables();
        const QVariantMap targetSettings =
            settingsWithLocalBackupPolicy(
                context->restoredSettings, context->originalSettings);
        if (ok) {
            ok = applySettingsSnapshot(targetSettings);
        }
        if (ok && m_settingsFilePath.isEmpty()) {
            AppSettings::instance()->reload();
        }
        if (ok) {
            ok = FocusTimer::instance()->restoreInterruptedSession();
        }

        if (!ok) {
            rollbackAsyncRestore(
                context, QStringLiteral("恢复后的数据库、设置或计时状态校验失败"));
            return;
        }

        setLastError(QString());
        setBusy(false);
        emit restoreCompleted(true, QStringLiteral("恢复完成"));
    });

    watcher->setFuture(QtConcurrent::run(
        [context, settingsPath = m_settingsFilePath]() {
            const BackupOperations::OperationResult snapshot =
                BackupOperations::createSnapshot(
                    context->databasePath,
                    settingsPath,
                    context->preRestorePath,
                    QStringLiteral("before-restore"),
                    DatabaseManager::kCurrentSchemaVersion);
            if (!snapshot.success) {
                return snapshot;
            }
            return BackupOperations::atomicCopy(
                context->sourcePath, context->databasePath);
        }));
}

void BackupService::rollbackAsyncRestore(
    const QSharedPointer<RestoreContext>& context,
    const QString& reason)
{
    DatabaseManager::instance()->close();
    setBusy(true, QStringLiteral("恢复失败，正在安全回滚"), true);

    auto* watcher = new QFutureWatcher<BackupOperations::OperationResult>(this);
    connect(watcher, &QFutureWatcherBase::finished, this,
            [this, watcher, context, reason]() {
        const BackupOperations::OperationResult result = watcher->result();
        watcher->deleteLater();

        // 无论回滚拷贝成败，都必须先把数据库重新打开：拷贝失败时原库文件通常仍完好，
        // 只是连接被关掉了。若把 initialize 挂在 && 链后半段，拷贝一失败就会短路，
        // 应用会一直停在"数据库未打开"的僵尸态，连再试一次恢复都做不到。
        const bool reopened =
            DatabaseManager::instance()->initialize(context->databasePath);

        bool rolledBack = result.success
            && reopened
            && verifyRestoredDatabase()
            && cleanBackupTables()
            && applySettingsSnapshot(context->originalSettings);
        if (rolledBack && m_settingsFilePath.isEmpty()) {
            AppSettings::instance()->reload();
        }
        if (rolledBack) {
            rolledBack = FocusTimer::instance()->restoreInterruptedSession();
        }

        QString message;
        if (rolledBack) {
            message = reason + QStringLiteral("，已回滚到恢复前数据");
        } else if (reopened) {
            // 数据库能打开就说明用户还能继续用，提示语必须和"彻底不可用"区分开。
            message = reason + QStringLiteral("；自动回滚未完成，当前数据可能不完整，"
                                              "恢复前备份保留在 ")
                + context->preRestorePath;
        } else {
            message = reason + QStringLiteral("；自动回滚失败且数据库无法打开，"
                                              "请重启应用；恢复前备份保留在 ")
                + context->preRestorePath;
        }
        setLastError(message);
        setBusy(false);
        emit restoreCompleted(false, message);
    });
    const bool forceFailure = m_forceRollbackCopyFailureForTest;
    m_forceRollbackCopyFailureForTest = false;   // 一次性开关，用完即清
    watcher->setFuture(QtConcurrent::run([context, forceFailure]() {
        if (forceFailure) {
            BackupOperations::OperationResult forced;
            forced.success = false;
            forced.error = QStringLiteral("测试注入的回滚拷贝失败");
            return forced;
        }
        return BackupOperations::atomicCopy(
            context->preRestorePath, context->databasePath);
    }));
}

bool BackupService::autoBackupDue() const
{
    if (!autoBackupEnabled()) {
        return false;
    }
    const QDateTime now = QDateTime::currentDateTime();
    const QDateTime last = QDateTime::fromString(lastBackupTimeIso(), Qt::ISODate);
    if (!last.isValid()) {
        return true;
    }
    // 系统时间若被调到未来，不应无限压制自动备份；未来时间直接视为到期。
    return last > now || last.daysTo(now) >= kAutoBackupIntervalDays;
}

bool BackupService::runAutoBackupIfDue()
{
    setLastError(QString());
    if (!autoBackupDue()) {
        return true;
    }

    if (!QDir().mkpath(autoBackupsDir())) {
        setLastError(QStringLiteral("无法创建自动备份目录"));
        return false;
    }
    const QString path = QDir(autoBackupsDir()).filePath(
        kAutoPrefix + timestampToken() + kBackupExtension);
    if (!writeSnapshot(path, QStringLiteral("auto"))) {
        return false;
    }

    std::unique_ptr<QSettings> settings = makeSettings(m_settingsFilePath);
    settings->setValue(
        kLastBackupIsoKey, QDateTime::currentDateTime().toString(Qt::ISODate));
    settings->sync();
    if (settings->status() != QSettings::NoError) {
        setLastError(QStringLiteral("自动备份完成，但时间记录保存失败"));
        return false;
    }

    pruneAutoBackups();
    emit lastBackupTimeChanged();
    return true;
}

void BackupService::requestAutoBackupIfDue()
{
    if (m_busy || !autoBackupDue()) {
        return;
    }
    const QString path = QDir(autoBackupsDir()).filePath(
        kAutoPrefix + timestampToken() + kBackupExtension);
    startBackupJob(path, QStringLiteral("auto"), true);
}

void BackupService::pruneAutoBackups() const
{
    QDir dir(autoBackupsDir());
    const QFileInfoList autos = dir.entryInfoList(
        QStringList{kAutoPrefix + QStringLiteral("*") + kBackupExtension},
        QDir::Files,
        QDir::Time);
    for (int index = kAutoBackupRetention; index < autos.size(); ++index) {
        if (!QFile::remove(autos.at(index).absoluteFilePath())) {
            qWarning() << "删除过期自动备份失败:" << autos.at(index).absoluteFilePath();
        }
    }
}

QVariantList BackupService::listBackups() const
{
    QVariantList result;
    QDir dir(autoBackupsDir());
    const QFileInfoList files = dir.entryInfoList(
        QStringList{QStringLiteral("*") + kBackupExtension},
        QDir::Files,
        QDir::Time);
    for (const QFileInfo& file : files) {
        QVariantMap entry;
        entry.insert(QStringLiteral("path"), file.absoluteFilePath());
        entry.insert(QStringLiteral("name"), file.fileName());
        entry.insert(QStringLiteral("modified"), file.lastModified().toString(Qt::ISODate));
        entry.insert(QStringLiteral("sizeBytes"), file.size());
        result.append(entry);
    }
    return result;
}

bool BackupService::openBackupsFolder() const
{
    const QString directory = autoBackupsDir();
    if (!QDir().mkpath(directory)) {
        return false;
    }
    return QDesktopServices::openUrl(QUrl::fromLocalFile(directory));
}
