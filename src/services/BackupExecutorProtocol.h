#ifndef BACKUPEXECUTORPROTOCOL_H
#define BACKUPEXECUTORPROTOCOL_H

#include "BackupOperations.h"

#include <optional>

namespace BackupExecutorProtocol {

inline constexpr qsizetype kMaxLineBytes = 48 * 1024 * 1024;

struct Request
{
    QString op;
    BackupOperations::SnapshotRequest snapshot;
    QString sourcePath;
    QString destinationPath;
    int schema = 0;
    qint64 maxBytes = BackupOperations::kMaxBackupFileBytes;
    int budgetMs = BackupOperationControl::kDefaultBudgetMs;
};

struct Result
{
    BackupOperations::OperationResult operation;
    QVariantMap info;
};

QByteArray encodeRequest(const Request& request);
std::optional<Request> decodeRequest(const QByteArray& line, QString* error);
QByteArray encodeResult(const Result& result);
std::optional<Result> decodeResult(const QByteArray& line, QString* error);
Result runRequest(const Request& request, const BackupOperation& operation);
QByteArray encodeStop(BackupOperationControl::StopReason reason);
std::optional<BackupOperationControl::StopReason> decodeStop(const QByteArray& line);

} // namespace BackupExecutorProtocol

#endif // BACKUPEXECUTORPROTOCOL_H
