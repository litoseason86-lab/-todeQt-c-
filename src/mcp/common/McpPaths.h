#ifndef MCPPATHS_H
#define MCPPATHS_H

#include <QJsonObject>
#include <QString>

// 外部 AI 接入（MCP）的本机路径。主应用的监听端与辅助程序的连接端都只从这里取路径，
// 两个进程各算一套就可能落到不同目录，表现为“应用明明开着却连不上”。
//
// 这里全部是纯计算：不创建目录、不检查文件是否存在。目录的创建、所有者与符号链接校验
// 属于主应用启用接入时的职责（McpAccessController）。
//
// 注入约定：需要端点的类（McpBridgeClient、McpLocalServer、McpAccessController）都从构造函数
// 接收算好的路径，没有默认值。只有两个进程的 main 调用 resolveProduction()；测试一律用
// resolveForRoot() 注入临时目录，因此测试不会误连用户正在运行的应用。
namespace McpPaths {

// 与主应用一致的应用身份。QStandardPaths 的 AppDataLocation 由这两个名字推导，
// 辅助程序若沿用自己的可执行文件名，就会在另一个目录里找端点。
QString organizationName();
QString applicationName();
// 两个进程在计算任何路径之前调用。
void applyApplicationIdentity();

// macOS 的 sockaddr_un.sun_path 是 104 字节数组，结尾要留一个字节给 NUL，
// 所以路径编码后最多 103 字节。按字节而不是按字符计：一个汉字在 UTF-8 里占 3 字节。
// McpPaths.cpp 会在编译期用系统头文件核对这个容量。
constexpr int kSocketPathCapacityBytes = 104;
constexpr int kMaxSocketPathBytes = kSocketPathCapacityBytes - 1;

enum class PathError {
    None,
    // 调用 resolveProduction() 前没有设置与主应用一致的应用身份。
    IdentityNotApplied,
    EmptyRoot,
    EmbeddedNul,
    RelativeRoot,
    SocketPathTooLong
};

struct PathSet
{
    // 接入运行目录，主应用启用接入时以 0700 创建。
    QString rootDirectory;
    // 本地 socket。文件名固定为最短的 "s"，给用户名较长的主目录多留余量。
    QString socketPath;
    // 接入凭据（0600），只由主应用写入、辅助程序读取。
    QString credentialPath;
    // 发现信息（端点与私有协议版本），不含任何业务数据。
    QString discoveryPath;
};

struct Resolution
{
    PathError error = PathError::None;
    // 只有 ok() 为真时才有意义；出错时保持为空，调用方不能拿半截路径去 listen/connect。
    PathSet paths;
    // socket 路径编码后的字节数（不含结尾 NUL）。超长时用于诊断，其余错误为 0。
    int socketPathBytes = 0;

    bool ok() const { return error == PathError::None; }
};

// 稳定的错误原因标识，例如 "path_too_long"，写入错误 details 与状态查询结果。
QString pathErrorReason(PathError error);

// 以给定根目录计算全部路径。根目录必须是不含 NUL 的非空绝对路径，socket 路径不能超长；
// 不满足时返回错误而不是截断或换目录。
Resolution resolveForRoot(const QString& rootDirectory);

// 生产路径：<AppDataLocation>/mcp。要求已调用 applyApplicationIdentity()。
Resolution resolveProduction();

// 对外（工具结果、错误 details）只给原因和字节数，不给完整路径：
// 完整的本机诊断路径只在应用自己的设置区展示。
QJsonObject pathErrorDetails(const Resolution& resolution);

} // namespace McpPaths

#endif // MCPPATHS_H
