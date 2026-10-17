#ifndef MACBACKUPEXECUTOR_H
#define MACBACKUPEXECUTOR_H

#include "services/BackupExecutor.h"
#include "services/BackupExecutorProtocol.h"

#include <sys/types.h>

#include <atomic>

class MacBackupExecutor final : public BackupExecutor
{
public:
    class ProcessControl
    {
    public:
        virtual ~ProcessControl() = default;
        virtual int sendSignal(pid_t process, int signal);
        virtual pid_t wait(pid_t process, int* status, int options);
        // 测试护栏在启动后立即登记子进程，产品实现无需观察进程身份。
        virtual void didSpawn(pid_t process);
    };

    static constexpr int kStopResponseBudgetMs = 2000;
    static constexpr int kReapBudgetMs = 2000;

    explicit MacBackupExecutor(QString executablePath = {},
                               std::shared_ptr<ProcessControl> processControl = {});
    BackupOperations::OperationResult createSnapshot(
        const BackupOperations::SnapshotRequest& request, const BackupOperation& operation) override;
    QVariantMap inspectBackup(const QString& path, int schema, const BackupOperation& operation) override;
    BackupOperations::OperationResult stageCopy(
        const QString& source, const QString& destination, qint64 maxBytes,
        const BackupOperation& operation) override;
    bool hasAbandonedWork() const override;

private:
    BackupExecutorProtocol::Result execute(BackupExecutorProtocol::Request request,
                                            const BackupOperation& operation);
    QString m_executablePath;
    std::shared_ptr<ProcessControl> m_processControl;
    std::atomic_bool m_abandoned = false;
};

#endif // MACBACKUPEXECUTOR_H
