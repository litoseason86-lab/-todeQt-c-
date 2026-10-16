#ifndef MACSQLITERUNTIME_H
#define MACSQLITERUNTIME_H

#include <QString>

namespace MacSqliteRuntime {
// 必须在首个数据库连接之前于主线程调用；失败由入口阻断启动，不能回退到SDK插件。
bool initialize(const QString& pluginPath, QString* error);
QString loadedPluginPath();
}

#endif
