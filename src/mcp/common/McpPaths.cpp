#include "McpPaths.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonValue>
#include <QStandardPaths>
#include <QtGlobal>

#if defined(Q_OS_MACOS)
#include <sys/un.h>

// 容量常量写在公共头里供两端共用；这里对照系统头文件，SDK 若改了 sun_path 的大小，
// 编译当场失败，而不是运行时出现“路径校验通过、listen 却失败”的分叉。
static_assert(sizeof(sockaddr_un::sun_path) == McpPaths::kSocketPathCapacityBytes,
              "sockaddr_un.sun_path 的容量与 McpPaths::kSocketPathCapacityBytes 不一致");
#endif

namespace McpPaths {

QString organizationName()
{
    return QStringLiteral("PomodoroTodo");
}

QString applicationName()
{
    return QStringLiteral("PomodoroTodo");
}

void applyApplicationIdentity()
{
    QCoreApplication::setOrganizationName(organizationName());
    QCoreApplication::setApplicationName(applicationName());
}

QString pathErrorReason(PathError error)
{
    switch (error) {
    case PathError::None:
        return QString();
    case PathError::IdentityNotApplied:
        return QStringLiteral("identity_not_applied");
    case PathError::EmptyRoot:
        return QStringLiteral("empty_root");
    case PathError::EmbeddedNul:
        return QStringLiteral("embedded_nul");
    case PathError::RelativeRoot:
        return QStringLiteral("relative_root");
    case PathError::SocketPathTooLong:
        return QStringLiteral("path_too_long");
    }
    Q_UNREACHABLE();
    return QString();
}

Resolution resolveForRoot(const QString& rootDirectory)
{
    Resolution resolution;
    if (rootDirectory.isEmpty()) {
        resolution.error = PathError::EmptyRoot;
        return resolution;
    }
    // NUL 在 C 接口里会提前截断字符串：校验看到的是完整路径，系统调用用的却是前半截。
    if (rootDirectory.contains(QChar(u'\0'))) {
        resolution.error = PathError::EmbeddedNul;
        return resolution;
    }
    // 相对路径会跟着各自进程的工作目录走，而 AI 客户端拉起辅助程序时的工作目录并不固定。
    if (!QDir::isAbsolutePath(rootDirectory)) {
        resolution.error = PathError::RelativeRoot;
        return resolution;
    }

    // cleanPath 只做字符串层面的规整（去掉多余的斜杠和 . / ..），不访问磁盘。
    const QString root = QDir::cleanPath(rootDirectory);
    const QDir rootDir(root);
    const QString socketPath = rootDir.filePath(QStringLiteral("s"));

    // 与 QLocalServer/QLocalSocket 填写 sun_path 时用的是同一个编码函数，
    // 字节数才和系统调用实际看到的一致。
    const int socketBytes = static_cast<int>(QFile::encodeName(socketPath).size());
    if (socketBytes > kMaxSocketPathBytes) {
        resolution.error = PathError::SocketPathTooLong;
        resolution.socketPathBytes = socketBytes;
        return resolution;
    }

    resolution.socketPathBytes = socketBytes;
    resolution.paths.rootDirectory = root;
    resolution.paths.socketPath = socketPath;
    resolution.paths.credentialPath = rootDir.filePath(QStringLiteral("key"));
    resolution.paths.discoveryPath = rootDir.filePath(QStringLiteral("endpoint.json"));
    return resolution;
}

Resolution resolveProduction()
{
    // 身份不一致时 AppDataLocation 会指向别的目录。宁可明确报错，也不能算出一个“看起来正常”的错路径。
    if (QCoreApplication::organizationName() != organizationName()
        || QCoreApplication::applicationName() != applicationName()) {
        Resolution resolution;
        resolution.error = PathError::IdentityNotApplied;
        return resolution;
    }

    const QString appData = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (appData.isEmpty()) {
        Resolution resolution;
        resolution.error = PathError::EmptyRoot;
        return resolution;
    }
    return resolveForRoot(QDir(appData).filePath(QStringLiteral("mcp")));
}

QJsonObject pathErrorDetails(const Resolution& resolution)
{
    const bool tooLong = resolution.error == PathError::SocketPathTooLong;
    return QJsonObject{
        {QStringLiteral("reason"), pathErrorReason(resolution.error)},
        {QStringLiteral("actual_bytes"),
         tooLong ? QJsonValue(resolution.socketPathBytes) : QJsonValue(QJsonValue::Null)},
        {QStringLiteral("max_bytes"),
         tooLong ? QJsonValue(kMaxSocketPathBytes) : QJsonValue(QJsonValue::Null)},
    };
}

} // namespace McpPaths
