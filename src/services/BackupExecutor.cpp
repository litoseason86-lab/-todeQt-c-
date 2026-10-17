#include "BackupExecutor.h"

BackupOperations::OperationResult InProcessBackupExecutor::createSnapshot(
    const BackupOperations::SnapshotRequest& request, const BackupOperation& operation)
{
    return BackupOperations::createSnapshot(request, operation);
}

QVariantMap InProcessBackupExecutor::inspectBackup(const QString& path, int schema,
                                                  const BackupOperation& operation)
{
    return BackupOperations::inspectBackup(path, schema, operation);
}

BackupOperations::OperationResult InProcessBackupExecutor::stageCopy(
    const QString& source, const QString& destination, qint64 maxBytes,
    const BackupOperation& operation)
{
    return BackupOperations::atomicCopy(source, destination, maxBytes, operation);
}

bool InProcessBackupExecutor::hasAbandonedWork() const
{
    return false;
}
