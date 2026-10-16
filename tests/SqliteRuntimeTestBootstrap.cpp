#include "platform/macos/SqliteRuntime.h"

#include <QCoreApplication>
#include <QDebug>

namespace {
void installSqliteRuntime()
{
    // 在QCoreApplication构造结束时装配，覆盖测试入口及其QProcess子进程；
    // 使用编译目标的确定路径，插件缺失必须让测试失败，不能回退后产生假绿灯。
    QString error;
    if (!MacSqliteRuntime::initialize(QString::fromUtf8(POMODORO_SQLITE_TEST_PLUGIN_PATH), &error)) {
        qFatal("%s", qPrintable(error));
    }
}
}

Q_COREAPP_STARTUP_FUNCTION(installSqliteRuntime)
