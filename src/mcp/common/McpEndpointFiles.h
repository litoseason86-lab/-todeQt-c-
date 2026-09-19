#pragma once
#include "McpPaths.h"

// 只处理端点元数据，不处理任务数据。读取也检查所有者和权限，拒绝被重定向的凭据。
namespace McpEndpointFiles {
bool prepareRoot(const McpPaths::PathSet& paths, QString* error);
bool validateRoot(const McpPaths::PathSet& paths);
bool publish(const McpPaths::PathSet& paths, const QByteArray& credential);
bool read(const McpPaths::PathSet& paths, QByteArray* credential, int* version);
bool removeOwned(const QString& path, bool socket = false);
}
