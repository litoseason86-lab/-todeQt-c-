#include "McpEndpointFiles.h"
#include "McpContracts.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
bool privateObject(const QString& path, bool directory)
{
    struct stat info {};
    if (::lstat(QFile::encodeName(path).constData(), &info) != 0) return false;
    return info.st_uid == ::geteuid() && (info.st_mode & 0077) == 0
        && (directory ? S_ISDIR(info.st_mode) : S_ISREG(info.st_mode));
}
bool ancestorsWithoutLinks(const QString& path)
{
    QString current = QDir::cleanPath(path);
    while (current != QStringLiteral("/")) {
        struct stat info {};
        if (::lstat(QFile::encodeName(current).constData(), &info) == 0) {
            if (!S_ISDIR(info.st_mode)) return false;
        } else if (errno != ENOENT) return false;
        current = QFileInfo(current).absolutePath();
    }
    return true;
}
bool writePrivate(const QString& path, const QByteArray& bytes)
{
    // 排他创建避免跟随已有符号链接；发现文件最后发布，客户端不会把半套凭据当成可用端点。
    const QByteArray native = QFile::encodeName(path);
    const int descriptor = ::open(native.constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (descriptor < 0) return false;
    qsizetype written = 0;
    while (written < bytes.size()) {
        const ssize_t count = ::write(descriptor, bytes.constData() + written, size_t(bytes.size() - written));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        written += count;
    }
    const bool ok = written == bytes.size() && ::fsync(descriptor) == 0;
    ::close(descriptor);
    if (!ok) ::unlink(native.constData());
    return ok;
}
QByteArray readPrivate(const QString& path)
{
    const int descriptor = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) return {};
    struct stat info {};
    QByteArray bytes;
    if (::fstat(descriptor, &info) == 0 && S_ISREG(info.st_mode)
        && info.st_uid == ::geteuid() && (info.st_mode & 0077) == 0
        && info.st_size > 0 && info.st_size <= 4096) {
        bytes.resize(info.st_size);
        qsizetype offset = 0;
        while (offset < bytes.size()) {
            const ssize_t count = ::read(descriptor, bytes.data() + offset, size_t(bytes.size() - offset));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { bytes.clear(); break; }
            offset += count;
        }
    }
    ::close(descriptor);
    return bytes;
}
}

bool McpEndpointFiles::validateRoot(const McpPaths::PathSet& paths)
{
    return ancestorsWithoutLinks(paths.rootDirectory) && privateObject(paths.rootDirectory, true);
}
bool McpEndpointFiles::prepareRoot(const McpPaths::PathSet& paths, QString* error)
{
    if (!ancestorsWithoutLinks(paths.rootDirectory)) {
        if (error) *error = QStringLiteral("接入目录不能经过符号链接");
        return false;
    }
    const QByteArray root = QFile::encodeName(paths.rootDirectory);
    const bool parents = QDir().mkpath(QFileInfo(paths.rootDirectory).absolutePath());
    if (!parents || (::mkdir(root.constData(), 0700) != 0 && errno != EEXIST)
        || !validateRoot(paths)) {
        if (error) *error = QStringLiteral("接入目录须属于当前用户，且仅当前用户可访问");
        return false;
    }
    return true;
}
bool McpEndpointFiles::removeOwned(const QString& path, bool socket)
{
    struct stat info {};
    const QByteArray native = QFile::encodeName(path);
    if (::lstat(native.constData(), &info) != 0) return errno == ENOENT;
    if (info.st_uid != ::geteuid() || (socket ? !S_ISSOCK(info.st_mode) : !S_ISREG(info.st_mode)))
        return false;
    return ::unlink(native.constData()) == 0;
}
bool McpEndpointFiles::publish(const McpPaths::PathSet& paths, const QByteArray& credential)
{
    if (!validateRoot(paths) || !writePrivate(paths.credentialPath, credential)) return false;
    const QJsonObject discovery {{"version", McpContracts::kBridgeProtocolVersion}, {"socket", paths.socketPath}};
    if (writePrivate(paths.discoveryPath, QJsonDocument(discovery).toJson(QJsonDocument::Compact))) return true;
    removeOwned(paths.credentialPath);
    return false;
}
bool McpEndpointFiles::read(const McpPaths::PathSet& paths, QByteArray* credential, int* version)
{
    if (!validateRoot(paths)) return false;
    const QByteArray key = readPrivate(paths.credentialPath);
    const QJsonObject discovery = QJsonDocument::fromJson(readPrivate(paths.discoveryPath)).object();
    if (key.size() != 64 || QByteArray::fromHex(key).toHex() != key
        || discovery.value("socket").toString() != paths.socketPath
        || !discovery.value("version").isDouble()) return false;
    *credential = key;
    *version = discovery.value("version").toInt(-1);
    return true;
}
