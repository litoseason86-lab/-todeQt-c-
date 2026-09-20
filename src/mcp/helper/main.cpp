#include "McpStdioServer.h"
#include "McpStdioDevice.h"
#include "McpBridgeClient.h"
#include "../common/McpPaths.h"
#include <QCoreApplication>
#include <QDebug>
#include <QTimer>
#include <csignal>

int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    McpPaths::applyApplicationIdentity();
    QCoreApplication::setApplicationVersion(QStringLiteral(POMODORO_TODO_VERSION));
    // 管道另一端退出时交给异步错误路径收尾，不让 SIGPIPE 抢先终止进程。
    std::signal(SIGPIPE, SIG_IGN);
#ifdef MCP_TEST_HOST
    // 仅测试目标编入此分支；必须显式给出目录，没有退回生产端点的路径。
    if (app.arguments().size() != 2) return 2;
    const auto endpoint = McpPaths::resolveForRoot(app.arguments().at(1));
#else
    const auto endpoint = McpPaths::resolveProduction();
#endif
    McpStdioDevice device;
    if (!device.start()) { qCritical() << "无法打开 MCP 标准输入输出"; return 2; }
    McpBridgeClient bridge(endpoint);
    McpStdioServer server(&device, &bridge);
    bool ending = false;
    QObject::connect(&device, &McpStdioDevice::inputClosed, &server, &McpStdioServer::endInput);
    QObject::connect(&device, &McpStdioDevice::transportFailed, &app, [&app] {
        // 退出原因写 stderr（stdout 只能有协议消息），客户端日志里才查得到为什么断开。
        qWarning().noquote() << QStringLiteral("番茄Todo MCP 辅助程序：标准输入输出读写失败，退出");
        app.exit(2);
    });
    QObject::connect(&server, &McpStdioServer::finished, &app, [&] {
        ending = true;
        if (device.bytesToWrite() == 0) app.quit();
        else QTimer::singleShot(1000, &app, &QCoreApplication::quit);
    });
    QObject::connect(&device, &QIODevice::bytesWritten, &app, [&] {
        if (ending && device.bytesToWrite() == 0) app.quit();
    });
    return app.exec();
}
