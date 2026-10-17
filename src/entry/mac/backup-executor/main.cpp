#include "services/BackupExecutorProtocol.h"

#include <QCoreApplication>

#include <cstdio>
#include <cstdlib>
#include <thread>

namespace {
bool readLine(QByteArray* line)
{
    line->clear();
    for (;;) {
        const int next = std::getc(stdin);
        if (next == EOF) return false;
        if (next == '\n') return true;
        if (line->size() >= BackupExecutorProtocol::kMaxLineBytes) return false;
        line->append(static_cast<char>(next));
    }
}

[[noreturn]] void finish(const BackupExecutorProtocol::Result& result)
{
    const auto line = BackupExecutorProtocol::encodeResult(result);
    std::fwrite(line.constData(), 1, static_cast<size_t>(line.size()), stdout);
    std::fflush(stdout);
    // 标准输入线程可能仍阻塞在父进程管道上；结果已发布，不能再等线程或 Qt 全局析构。
    std::_Exit(0);
}
}

int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationVersion(QStringLiteral(POMODORO_TODO_VERSION));
    QByteArray line;
    QString error;
    if (!readLine(&line)) finish({{false, QStringLiteral("未收到完整的备份执行器请求")}, {}});
    const auto request = BackupExecutorProtocol::decodeRequest(line, &error);
    if (!request) finish({{false, error}, {}});

    const auto operation = std::make_shared<BackupOperationControl>(request->budgetMs);
    std::thread([operation] {
        QByteArray stopLine;
        while (readLine(&stopLine)) {
            if (const auto reason = BackupExecutorProtocol::decodeStop(stopLine)) {
                operation->requestStop(*reason);
                return;
            }
        }
        // 父进程消失或关闭输入时也停止，避免继续发布已经无人等待的快照。
        operation->requestStop(BackupOperationControl::StopReason::Shutdown);
    }).detach();

    // 所有备份连接显式构造 BackupSqliteDriver，直连系统 SQLite，不经过 QSQLITE 插件。
    // POSIX 记录锁在这里按进程隔离；关闭本进程连接不会释放主进程另一条连接的锁。
    finish(BackupExecutorProtocol::runRequest(*request, operation));
}
