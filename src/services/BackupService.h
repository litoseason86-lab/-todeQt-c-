#ifndef BACKUPSERVICE_H
#define BACKUPSERVICE_H

#include <QObject>
#include <QList>
#include <QSharedPointer>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

#include "ServiceReadResult.h"
#include "BackupOperationControl.h"

#include <functional>

class QFutureWatcherBase;

namespace BackupOperations {
struct OperationResult;
}

// 数据备份与恢复：把整库做成单文件 SQLite 快照（.tomatobackup），并把存在 QSettings 里的
// 偏好一并嵌入快照，实现换机/损坏/误操作后的完整恢复。不是 CSV 导出，也不做云同步。
class BackupService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool autoBackupEnabled READ autoBackupEnabled WRITE setAutoBackupEnabled NOTIFY autoBackupEnabledChanged)
    Q_PROPERTY(QString lastBackupTimeIso READ lastBackupTimeIso NOTIFY lastBackupTimeChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool operationBlocksUi READ operationBlocksUi NOTIFY operationBlocksUiChanged)
    Q_PROPERTY(QString operationText READ operationText NOTIFY operationTextChanged)

public:
    // 备份文件扩展名与自动备份保留份数、周期。
    static constexpr int kAutoBackupRetention = 4;
    static constexpr int kAutoBackupIntervalDays = 7;
    // 恢复前快照单独计数，不与自动备份共用配额：这两类的作用完全不同——
    // 自动备份是周期性存档，恢复前快照是「这次恢复搞砸了还能退回去」的保险。
    // 混在一起算的话，连续几次恢复就会把周期存档全挤掉，反之亦然。
    static constexpr int kBeforeRestoreRetention = 3;
    // 设备间同步要整体换掉本机数据之前（第一次加入、另一台设备恢复了备份）的自动备份，同样单独计数：
    // 两台设备来回恢复几次就会连着替换好几次，不能因此挤掉周期存档和恢复前快照。
    static constexpr int kBeforeSyncRetention = 3;

    static BackupService* instance();
    explicit BackupService(QObject* parent = nullptr);
    ~BackupService() override;

    // 测试注入设置文件路径与备份目录；生产用默认（默认 QSettings + AppDataLocation/backups）。
    // 数据库路径始终取自 DatabaseManager 当前连接，无需注入。
    void configure(const QString& settingsFilePath, const QString& backupsDir);

    Q_INVOKABLE bool createBackup(const QString& destPath);
    // 恢复前预览：返回 {valid,reason,createdAt,appVersion,schemaVersion,taskCount,sessionCount}。
    Q_INVOKABLE QVariantMap readBackupInfo(const QString& srcPath) const;
    Q_INVOKABLE bool restoreBackup(const QString& srcPath);
    // 应用启动/退出时调用：到期才创建自动备份，保留最近 N 份；失败不阻断启动/退出。
    Q_INVOKABLE bool runAutoBackupIfDue();
    // 同步整体替换本机数据之前调用（主线程，同步执行）：备份写成了才允许替换，被换掉的数据只能从这份里找回。
    // 另一项备份或恢复正在进行时拒绝（error 说明原因），同步稍后会再试。
    bool backupBeforeSyncReplace(QString* error);
    // 恢复意图准备回调（主线程执行，接 SyncController::prepareForRestore）：
    // 在 emit restoreStarted、关库或派发任务前调用；返回 false 时中止恢复。
    using RestorePreparationCallback = std::function<bool(QString* error)>;
    void setRestorePreparationCallback(RestorePreparationCallback callback);

    // QML 使用异步入口，避免完整性检查、VACUUM、复制和恢复阻塞 GUI 事件循环。
    Q_INVOKABLE void requestBackup(const QString& destPath);
    Q_INVOKABLE void requestBackupInfo(const QString& srcPath);
    Q_INVOKABLE void requestRestore(const QString& srcPath);
    void requestAutoBackupIfDue();
    // aboutToQuit 中调用：先请求协作停止并等后台任务实际结束，再允许数据库和Qt全局对象销毁。
    // 永久阻塞的系统I/O仍可能拖住这里，不能把取消请求当作线程已退出。
    // 该函数可重复调用，避免退出路径因重复信号或析构兜底而二次释放 watcher。
    void prepareForShutdown();
    // 只请求停止；busy与恢复保护由实际完成回调解除。
    Q_INVOKABLE void cancelCurrentOperation();

    Q_INVOKABLE QString backupsDirectory() const;
    Q_INVOKABLE QVariantList listBackups() const;
    // 同 listBackups，但区分「还没有备份」（文件夹不存在或为空，成功的空列表）与文件夹读不了（报 Storage）。
    // iPad 设置页用它；listBackups 失败时仍回落为空列表，Mac 照旧。
    ServiceReadResult<QVariantList> readBackups() const;
    Q_INVOKABLE bool openBackupsFolder() const;
    Q_INVOKABLE QString suggestedBackupFileName() const;
    Q_INVOKABLE QString lastError() const;
    Q_INVOKABLE QString lastBackupTimeIso() const;
    Q_INVOKABLE QString backupFileExtension() const;

    bool autoBackupEnabled() const;
    void setAutoBackupEnabled(bool enabled);
    bool busy() const;
    bool operationBlocksUi() const;
    QString operationText() const;

signals:
    void backupCompleted(bool success, const QString& message);
    void backupInfoReady(const QString& sourcePath, const QVariantMap& info);
    void restoreStarted();
    void restoreCompleted(bool success, const QString& message);
    // 仅供同步装配使用的内部恢复完成信号（严格先于 UI restoreCompleted 发送）：
    // 只有实际通过 prepareForRestore 准入的恢复才发送；safeToResume 区分是否已安全回滚原数据。
    void restoreSyncCompleted(bool success, bool safeToResume);
    void autoBackupEnabledChanged();
    void lastBackupTimeChanged();
    void busyChanged();
    void operationBlocksUiChanged();
    void operationTextChanged();

private:
    // 回滚拷贝失败在真实环境由磁盘满/文件占用触发，测试无法稳定复现（快照刚写出，必然可拷）。
    // 沿用 FocusTimer 的受控友元约定，用一个测试专用开关强制该分支，
    // 避免测试侧 #define private public 的未定义行为写法。
    friend class BackupServiceTests;
    friend class SharedAppTests;

    struct RestoreContext;

    // 写快照的实际步骤由纯后台操作层执行，当前函数保留给单元测试和非 GUI 调用。
    bool writeSnapshot(const QString& destPath, const QString& kind, const BackupOperation& operation = {});
    QVariantMap inspectBackup(const QString& srcPath) const;
    // 同步恢复的实际步骤由公共入口持有准入，内部收尾完成后才释放并发送UI完成信号。
    bool restoreSynchronously(const QString& srcPath, const BackupOperation& operation);

    QString databasePath() const;
    QString autoBackupsDir() const;
    QVariantMap currentSettingsSnapshot(bool* ok) const;
    bool applySettingsSnapshot(const QVariantMap& values) const;
    bool cleanBackupTables() const;
    bool verifyRestoredDatabase() const;
    bool restoreFromPreRestoreSnapshot(const QString& preRestorePath,
                                       const QString& dbPath,
                                       const QVariantMap& originalSettings,
                                       QString* error);
    bool autoBackupDue() const;
    void startBackupJob(const QString& destinationPath,
                        const QString& kind,
                        bool automatic);
    void installPreparedRestore(const QSharedPointer<RestoreContext>& context);
    void rollbackAsyncRestore(const QSharedPointer<RestoreContext>& context,
                              const QString& reason);
    // keepPath 是刚建好的那份，无条件保留（见 SnapshotRetention::prune）。
    void pruneAutoBackups(const QString& keepPath) const;
    // 仅在本次恢复前快照已经原子创建成功后调用，把临时的 N+1 份收敛回 N 份；
    // 创建失败时不能调用，否则会在没有新恢复点兜底的情况下删掉旧快照。
    void pruneBeforeRestoreBackups(const QString& keepPath) const;
    // 两类快照共用的按前缀清理。files 按修改时间倒序，保留最新 retention 份。
    void pruneByPrefix(const QString& prefix, int retention, const QString& keepPath) const;
    void setLastError(const QString& message) const;
    void setBusy(bool busy,
                 const QString& operationText = QString(),
                 bool operationBlocksUi = false);
    void trackWorker(QFutureWatcherBase* watcher);
    void retireWorker(QFutureWatcherBase* watcher);

    QString m_settingsFilePath;   // 空 = 默认 QSettings（生产）
    QString m_backupsDir;         // 空 = AppDataLocation/backups
    mutable QString m_lastError;
    bool m_busy = false;
    bool m_operationBlocksUi = false;
    QString m_operationText;
    // QtConcurrent 任务不归 QObject 生命周期管理；必须持有 watcher，才能在事件循环停止前等待。
    QList<QFutureWatcherBase*> m_activeWorkers;
    bool m_shutdownPrepared = false;
    BackupOperation m_operation;
    BackupOperation m_nextOperationForTest;
    BackupOperation beginOperation();
    // 仅供 BackupServiceTests 置位：强制下一次回滚的拷贝返回失败。生产代码永远不写它。
    bool m_forceRollbackCopyFailureForTest = false;
    // 仅供测试在“校验完成、安装尚未开始”的窗口替换外部源路径，锁定恢复必须使用受控副本。
    std::function<void()> m_afterRestoreValidationHookForTest;
    RestorePreparationCallback m_restorePreparationCallback;
};

#endif // BACKUPSERVICE_H
