#ifndef BACKUPEXECUTOR_H
#define BACKUPEXECUTOR_H

#include "BackupOperations.h"

// 后台文件任务的同步边界；平台装配决定在当前进程还是独立进程中执行。
class BackupExecutor
{
public:
    virtual ~BackupExecutor() = default;
    virtual BackupOperations::OperationResult createSnapshot(
        const BackupOperations::SnapshotRequest& request, const BackupOperation& operation) = 0;
    virtual QVariantMap inspectBackup(const QString& path, int schema,
                                     const BackupOperation& operation) = 0;
    virtual BackupOperations::OperationResult stageCopy(
        const QString& source, const QString& destination, qint64 maxBytes,
        const BackupOperation& operation) = 0;
    virtual bool hasAbandonedWork() const = 0;
};

class InProcessBackupExecutor final : public BackupExecutor
{
public:
    BackupOperations::OperationResult createSnapshot(
        const BackupOperations::SnapshotRequest& request, const BackupOperation& operation) override;
    QVariantMap inspectBackup(const QString& path, int schema,
                             const BackupOperation& operation) override;
    BackupOperations::OperationResult stageCopy(
        const QString& source, const QString& destination, qint64 maxBytes,
        const BackupOperation& operation) override;
    bool hasAbandonedWork() const override;
};

#endif // BACKUPEXECUTOR_H
