#include "MacBackupExecutor.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QScopeGuard>

#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <utility>

extern char** environ;

namespace {
constexpr int kPollIntervalMs = 50;
constexpr qsizetype kMaxStandardErrorBytes = 4 * 1024;
// 2026-10-17，macOS 27.0.1 / Qt 6.10.3，本地 472829952 字节合成库：正常快照 878 ms；
// VACUUM 已写出至少 64 MiB 后停止五次为 71/64/66/66/65 ms，无强制结束、无暂存残留。
// 停止响应给 2 秒以覆盖调度余量；之后 SIGKILL，另给 2 秒回收。实测不证明永久 I/O 会结束，
// 超过回收上限仍未确认结束必须标记放弃；父线程每轮至多 poll 50 ms，不再等待文件 I/O。

struct Pipe
{
    int ends[2]{-1, -1};
    ~Pipe() { closeRead(); closeWrite(); }
    void closeRead() { if (ends[0] >= 0) { ::close(ends[0]); ends[0] = -1; } }
    void closeWrite() { if (ends[1] >= 0) { ::close(ends[1]); ends[1] = -1; } }
    bool open()
    {
        return ::pipe(ends) == 0 && ::fcntl(ends[0], F_SETFD, FD_CLOEXEC) == 0
            && ::fcntl(ends[1], F_SETFD, FD_CLOEXEC) == 0;
    }
};

bool nonblocking(int descriptor)
{
    const int flags = ::fcntl(descriptor, F_GETFL);
    return flags >= 0 && ::fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0;
}

BackupExecutorProtocol::Result failure(const QString& error, bool committed = false)
{
    return {{false, error, committed}, {}};
}

void drain(int descriptor, QByteArray* output, qsizetype limit, bool* exceeded, bool keepTail = false)
{
    char bytes[8192];
    // 每轮最多排空一小批；子进程持续输出时也必须回到停止状态与期限检查。
    for (int chunk = 0; chunk < 32; ++chunk) {
        const ssize_t count = ::read(descriptor, bytes, sizeof(bytes));
        if (count > 0) {
            if (keepTail) {
                // 错误原因通常在末尾；持续输出也只保留有限尾部，避免前部刷屏挤掉最后诊断。
                output->append(bytes, count);
                if (output->size() > limit) output->remove(0, output->size() - limit);
                continue;
            }
            const auto available = std::max<qsizetype>(0, limit - output->size());
            output->append(bytes, std::min<qsizetype>(count, available));
            if (count > available) *exceeded = true;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return;
        }
    }
}

std::optional<BackupExecutorProtocol::Result> completeResult(const QByteArray& output, bool exceeded)
{
    const auto newline = output.indexOf('\n');
    if (exceeded || newline < 0 || !output.mid(newline + 1).trimmed().isEmpty()) return std::nullopt;
    return BackupExecutorProtocol::decodeResult(output.first(newline), nullptr);
}
}

int MacBackupExecutor::ProcessControl::sendSignal(pid_t process, int signal)
{
    return ::kill(process, signal);
}

pid_t MacBackupExecutor::ProcessControl::wait(pid_t process, int* status, int options)
{
    return ::waitpid(process, status, options);
}

void MacBackupExecutor::ProcessControl::didSpawn(pid_t) {}

MacBackupExecutor::MacBackupExecutor(QString executablePath,
                                     std::shared_ptr<ProcessControl> processControl)
    : m_executablePath(executablePath.isEmpty()
          ? QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("PomodoroTodoBackupExecutor"))
          : std::move(executablePath)),
      m_processControl(processControl ? std::move(processControl) : std::make_shared<ProcessControl>())
{
}

bool MacBackupExecutor::hasAbandonedWork() const
{
    return m_abandoned.load();
}

BackupOperations::OperationResult MacBackupExecutor::createSnapshot(
    const BackupOperations::SnapshotRequest& snapshot, const BackupOperation& operation)
{
    BackupExecutorProtocol::Request request;
    request.op = QStringLiteral("snapshot");
    request.snapshot = snapshot;
    return execute(std::move(request), operation).operation;
}

QVariantMap MacBackupExecutor::inspectBackup(const QString& path, int schema, const BackupOperation& operation)
{
    BackupExecutorProtocol::Request request;
    request.op = QStringLiteral("inspect");
    request.sourcePath = path;
    request.schema = schema;
    auto result = execute(std::move(request), operation);
    if (!result.operation.success) {
        return {{QStringLiteral("valid"), false}, {QStringLiteral("reason"), result.operation.error}};
    }
    if (result.info.value(QStringLiteral("valid")).metaType().id() != QMetaType::Bool
        || !result.info.value(QStringLiteral("valid")).toBool()) {
        return {{QStringLiteral("valid"), false}, {QStringLiteral("reason"), QStringLiteral("备份执行器缺少有效检查结果")}};
    }
    return result.info;
}

BackupOperations::OperationResult MacBackupExecutor::stageCopy(
    const QString& source, const QString& destination, qint64 maxBytes, const BackupOperation& operation)
{
    BackupExecutorProtocol::Request request;
    request.op = QStringLiteral("stage");
    request.sourcePath = source;
    request.destinationPath = destination;
    request.maxBytes = maxBytes;
    return execute(std::move(request), operation).operation;
}

BackupExecutorProtocol::Result MacBackupExecutor::execute(BackupExecutorProtocol::Request request,
                                                          const BackupOperation& operation)
{
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>();
    if (hasAbandonedWork()) {
        return failure(QStringLiteral("上一次备份操作没能确认结束，请重启应用后再备份或恢复"));
    }
    if (control->stopped()) return failure(control->message());
    request.budgetMs = std::max(1, control->remainingBudgetMs());
    const auto input = BackupExecutorProtocol::encodeRequest(request);
    QString protocolError;
    if (!BackupExecutorProtocol::decodeRequest(input, &protocolError)) return failure(protocolError);

    Pipe standardInput, standardOutput, standardError;
    if (!standardInput.open() || !standardOutput.open() || !standardError.open()
        || !nonblocking(standardInput.ends[1]) || !nonblocking(standardOutput.ends[0])
        || !nonblocking(standardError.ends[0])
        || ::fcntl(standardInput.ends[1], F_SETNOSIGPIPE, 1) != 0) {
        return failure(QStringLiteral("无法创建备份执行器管道：") + QString::fromLocal8Bit(std::strerror(errno)));
    }

    posix_spawn_file_actions_t actions;
    int spawnError = ::posix_spawn_file_actions_init(&actions);
    if (spawnError != 0) return failure(QStringLiteral("无法初始化备份执行器"));
    const auto destroyActions = qScopeGuard([&] { ::posix_spawn_file_actions_destroy(&actions); });
    posix_spawnattr_t attributes;
    spawnError = ::posix_spawnattr_init(&attributes);
    if (spawnError != 0) return failure(QStringLiteral("无法初始化备份执行器属性"));
    const auto destroyAttributes = qScopeGuard([&] { ::posix_spawnattr_destroy(&attributes); });
    const auto addAction = [&](int error) { if (spawnError == 0) spawnError = error; };
    addAction(::posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT));
    // macOS 27.0.1 实测：stdin 管道恰为 0 时，同号 dup2 仍可能在 exec 时因 FD_CLOEXEC 关闭。
    // 显式继承该编号，保证标准流已关闭的宿主也能把请求管道传给执行器。
    if (standardInput.ends[0] == STDIN_FILENO) {
        addAction(::posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO));
    } else {
        addAction(::posix_spawn_file_actions_adddup2(&actions, standardInput.ends[0], STDIN_FILENO));
    }
    addAction(::posix_spawn_file_actions_adddup2(&actions, standardOutput.ends[1], STDOUT_FILENO));
    addAction(::posix_spawn_file_actions_adddup2(&actions, standardError.ends[1], STDERR_FILENO));
    for (const auto* pipe : {&standardInput, &standardOutput, &standardError}) {
        // 宿主标准流关闭时 pipe() 会复用 0–2；dup2 后这些编号已经是子进程标准流，不能再关闭。
        for (const int descriptor : pipe->ends) {
            if (descriptor > STDERR_FILENO) addAction(::posix_spawn_file_actions_addclose(&actions, descriptor));
        }
    }
    if (spawnError != 0) return failure(QStringLiteral("无法设置备份执行器管道"));

    // 卡在系统 I/O 的线程无法安全打断，文件任务交给子进程，父线程只等待可控的进程协议。
    // 不用 QProcess：其析构在进程未结束时还可能阻塞至多 30 秒，会越过这里的停止预算。
    const QByteArray executable = QFile::encodeName(m_executablePath);
    char* arguments[]{const_cast<char*>(executable.constData()), nullptr};
    pid_t child = -1;
    spawnError = ::posix_spawn(&child, executable.constData(), &actions, &attributes, arguments, environ);
    if (spawnError != 0) {
        return failure(QStringLiteral("无法启动备份执行器：") + QString::fromLocal8Bit(std::strerror(spawnError)));
    }
    m_processControl->didSpawn(child);
    standardInput.closeRead();
    standardOutput.closeWrite();
    standardError.closeWrite();

    QByteArray output, errors;
    qsizetype written = 0;
    QString transportError;
    bool stopping = false;
    bool killed = false;
    bool outputExceeded = false;
    bool errorExceeded = false;
    bool succeeded = false;
    const auto logFailure = qScopeGuard([&] {
        if (succeeded) return;
        // 子进程退出后再读一轮，保留退出前刚写出的诊断；只进日志，不改变用户错误文案。
        drain(standardError.ends[0], &errors, kMaxStandardErrorBytes, &errorExceeded, true);
        QString diagnostic = QString::fromUtf8(errors).trimmed();
        diagnostic.replace(QLatin1Char('\r'), QLatin1Char(' '));
        diagnostic.replace(QLatin1Char('\n'), QLatin1Char(' '));
        if (!diagnostic.isEmpty()) qWarning().noquote() << "备份执行器标准错误：" << diagnostic;
    });
    QElapsedTimer stopTimer;
    int status = 0;
    for (;;) {
        if (!stopping && (control->stopped() || !transportError.isEmpty())) {
            stopping = true;
            stopTimer.start();
            if (standardInput.ends[1] >= 0 && written == input.size()) {
                const auto stop = BackupExecutorProtocol::encodeStop(control->stopReason());
                // 停止行小于 PIPE_BUF；非阻塞写不成功时关闭输入，用 EOF 传递停止，不能在这里等待。
                const auto ignored = ::write(standardInput.ends[1], stop.constData(), static_cast<size_t>(stop.size()));
                Q_UNUSED(ignored);
            }
            standardInput.closeWrite();
        }
        drain(standardOutput.ends[0], &output, BackupExecutorProtocol::kMaxLineBytes, &outputExceeded);
        drain(standardError.ends[0], &errors, kMaxStandardErrorBytes, &errorExceeded, true);
        if (outputExceeded) transportError = QStringLiteral("备份执行器结果超出预算");
        const pid_t waited = m_processControl->wait(child, &status, WNOHANG);
        if (waited == child) break;
        if (waited < 0 && errno != EINTR) {
            m_abandoned.store(true);
            const auto result = completeResult(output, outputExceeded);
            return failure(QStringLiteral("无法确认备份执行器已经回收"), result && result->operation.committed);
        }
        if (stopping && !killed && stopTimer.elapsed() >= kStopResponseBudgetMs) {
            m_processControl->sendSignal(child, SIGKILL);
            killed = true;
        }
        if (stopping && killed && stopTimer.elapsed() >= kStopResponseBudgetMs + kReapBudgetMs) {
            m_abandoned.store(true);
            // 放弃等待仍保留完整结果已证明的提交事实，不能把“未回收”说成“目标未动”。
            const auto result = completeResult(output, outputExceeded);
            return failure(QStringLiteral("备份执行器未能在期限内回收，请重启应用"), result && result->operation.committed);
        }
        if (!stopping && written < input.size()) {
            const auto remaining = std::min<qsizetype>(input.size() - written, 64 * 1024);
            const ssize_t count = ::write(standardInput.ends[1], input.constData() + written, static_cast<size_t>(remaining));
            if (count > 0) written += count;
            else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                transportError = QStringLiteral("发送备份执行器请求失败");
            }
        }
        pollfd descriptors[]{{standardOutput.ends[0], POLLIN, 0}, {standardError.ends[0], POLLIN, 0},
                              {standardInput.ends[1], static_cast<short>(!stopping && written < input.size() ? POLLOUT : 0), 0}};
        if (::poll(descriptors, 3, kPollIntervalMs) < 0 && errno != EINTR) {
            transportError = QStringLiteral("等待备份执行器失败");
        }
    }
    drain(standardOutput.ends[0], &output, BackupExecutorProtocol::kMaxLineBytes, &outputExceeded);
    const auto result = completeResult(output, outputExceeded);
    const bool committed = result && result->operation.committed;
    if (!transportError.isEmpty()) return failure(transportError, committed);
    if (control->stopped()) return failure(control->message(), committed);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return failure(QStringLiteral("备份执行器异常退出"), committed);
    if (!result) return failure(QStringLiteral("备份执行器缺少完整有效的结果"));
    if (request.op == QLatin1String("inspect") && result->operation.success
        && (result->info.value(QStringLiteral("valid")).metaType().id() != QMetaType::Bool
            || !result->info.value(QStringLiteral("valid")).toBool())) {
        return failure(QStringLiteral("备份执行器缺少有效检查结果"));
    }
    succeeded = result->operation.success;
    return *result;
}
