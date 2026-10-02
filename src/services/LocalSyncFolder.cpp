#include "LocalSyncFolder.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QStorageInfo>

#include <cerrno>
#include <cstring>
#include <utility>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

namespace {

// 把 POSIX 的错误码归成同步关心的几类。
SyncFolder::Error errorFromErrno(int code, const QString& path)
{
    SyncFolder::Error error;
    error.message = QStringLiteral("%1：%2").arg(path, QString::fromLocal8Bit(std::strerror(code)));
    switch (code) {
    case ENOENT:
    case ENOTDIR:
        error.kind = SyncFolder::ErrorKind::NotFound;
        break;
    case EACCES:
    case EPERM:
        error.kind = SyncFolder::ErrorKind::Unavailable;
        break;
    case ENOSPC:
    case EDQUOT:
        error.kind = SyncFolder::ErrorKind::NoSpace;
        break;
    default:
        error.kind = SyncFolder::ErrorKind::Io;
        break;
    }
    return error;
}

void setError(SyncFolder::Error* target, const SyncFolder::Error& error)
{
    if (target) {
        *target = error;
    }
}

// 写入失败时 QSaveFile 不给出错误码，只能事后判断：剩余空间放不下这份数据就算空间不足，
// 目录不可写算不可用，其余按一般读写错误。
SyncFolder::Error classifyWriteFailure(const QString& path, qint64 size, const QString& message)
{
    SyncFolder::Error error;
    error.message = QStringLiteral("%1：%2").arg(path, message);
    const QFileInfo directory(QFileInfo(path).absolutePath());
    const QStorageInfo storage(directory.absoluteFilePath());
    // 留 1 MB 余量：临时文件、文件系统元数据都要占地方，剩余空间刚好等于文件大小时同样写不下。
    if (storage.isValid() && storage.bytesAvailable() >= 0 && storage.bytesAvailable() < size + 1024 * 1024) {
        error.kind = SyncFolder::ErrorKind::NoSpace;
    } else if (directory.exists() && !directory.isWritable()) {
        error.kind = SyncFolder::ErrorKind::Unavailable;
    } else {
        error.kind = SyncFolder::ErrorKind::Io;
    }
    return error;
}

} // namespace

LocalSyncFolder::LocalSyncFolder(QString rootPath)
    : m_root(QDir::cleanPath(std::move(rootPath)))
{
}

bool LocalSyncFolder::open(Error* error)
{
    const QFileInfo root(m_root);
    if (root.exists()) {
        if (!root.isDir()) {
            setError(error, {ErrorKind::Unavailable, QStringLiteral("%1 不是文件夹").arg(m_root)});
            return false;
        }
        // 真的列一次：有没有读权限，只有试过才知道。
        Error listError;
        list(QString(), &listError);
        if (!listError.ok()) {
            setError(error, listError);
            return false;
        }
        return true;
    }
    if (!QFileInfo(root.absolutePath()).isDir()) {
        setError(error, {ErrorKind::Unavailable, QStringLiteral("找不到 %1").arg(root.absolutePath())});
        return false;
    }
    return true;
}

QString LocalSyncFolder::name() const
{
    return QFileInfo(m_root).fileName();
}

QString LocalSyncFolder::displayPath() const
{
    return QDir::toNativeSeparators(m_root);
}

QString LocalSyncFolder::absolutePath(const QString& relativePath) const
{
    return relativePath.isEmpty() ? m_root : m_root + QLatin1Char('/') + relativePath;
}

QStringList LocalSyncFolder::list(const QString& relativeDir, Error* error)
{
    const QString path = absolutePath(relativeDir);
    DIR* directory = ::opendir(QFile::encodeName(path).constData());
    if (!directory) {
        setError(error, errorFromErrno(errno, path));
        return {};
    }
    QStringList names;
    errno = 0;
    while (const dirent* entry = ::readdir(directory)) {
        const QString name = QFile::decodeName(entry->d_name);
        if (name != QLatin1String(".") && name != QLatin1String("..")) {
            names.append(name);
        }
    }
    const int readError = errno;
    ::closedir(directory);
    if (readError != 0) {
        setError(error, errorFromErrno(readError, path));
        return {};
    }
    setError(error, {});
    return names;
}

bool LocalSyncFolder::read(const QString& relativePath, QByteArray* data, Error* error)
{
    const QString path = absolutePath(relativePath);
    // Mac 开着「优化 Mac 存储」时，对方刚写来的文件可能只是占位：这里的读取会让系统先把内容下载回来，
    // 所以可能要等上一秒左右（049 实测）。
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        setError(error, errorFromErrno(errno, path));
        return false;
    }
    QByteArray content;
    char buffer[64 * 1024];
    for (;;) {
        const ssize_t count = ::read(fd, buffer, sizeof(buffer));
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            const int readError = errno;
            ::close(fd);
            setError(error, errorFromErrno(readError, path));
            return false;
        }
        if (count == 0) {
            break;
        }
        content.append(buffer, count);
    }
    ::close(fd);
    *data = content;
    setError(error, {});
    return true;
}

bool LocalSyncFolder::write(const QString& relativePath, const QByteArray& data, Error* error)
{
    const QString path = absolutePath(relativePath);
    const QString directory = QFileInfo(path).absolutePath();
    if (!QDir().mkpath(directory)) {
        setError(error, classifyWriteFailure(path, data.size(), QStringLiteral("建不了目录")));
        return false;
    }
    // QSaveFile 先写同一目录下的临时文件（<文件名>.<6 位随机字符>），写完整再改名换上。
    // 改名是原子的：对方要么看到旧文件、要么看到完整的新文件，不会看到写了一半的。
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        setError(error, classifyWriteFailure(path, data.size(), file.errorString()));
        return false;
    }
    if (file.write(data) != data.size()) {
        const QString message = file.errorString();
        file.cancelWriting();
        setError(error, classifyWriteFailure(path, data.size(), message));
        return false;
    }
    if (!file.commit()) {
        setError(error, classifyWriteFailure(path, data.size(), file.errorString()));
        return false;
    }
    setError(error, {});
    return true;
}

bool LocalSyncFolder::remove(const QString& relativePath, Error* error)
{
    const QString path = absolutePath(relativePath);
    if (::unlink(QFile::encodeName(path).constData()) == 0 || errno == ENOENT) {
        setError(error, {});
        return true;
    }
    setError(error, errorFromErrno(errno, path));
    return false;
}
