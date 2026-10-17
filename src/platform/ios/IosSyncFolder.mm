#include "IosSyncFolder.h"
#include "../apple/AppleCoordinatedFiles.h"

#include "../apple/AppleUbiquitousItem.h"

#import <Foundation/Foundation.h>

#include <QSet>

#include <cerrno>

namespace {

// 把 Foundation 的错误归成同步关心的几类。
SyncFolder::Error errorFrom(NSError* error, const QString& context)
{
    SyncFolder::Error result;
    result.kind = SyncFolder::ErrorKind::Io;
    result.message = error ? QStringLiteral("%1：%2").arg(context, QString::fromNSString(error.localizedDescription))
                           : context;
    if (!error) {
        return result;
    }
    if ([error.domain isEqualToString:NSCocoaErrorDomain]) {
        switch (error.code) {
        case NSFileNoSuchFileError:
        case NSFileReadNoSuchFileError:
            result.kind = SyncFolder::ErrorKind::NotFound;
            break;
        case NSFileReadNoPermissionError:
        case NSFileWriteNoPermissionError:
        // iCloud 整个不可用（关了 iCloud 云盘、退出了 Apple ID）。
        case NSUbiquitousFileUbiquityServerNotAvailable:
            result.kind = SyncFolder::ErrorKind::Unavailable;
            break;
        case NSFileWriteOutOfSpaceError:
            result.kind = SyncFolder::ErrorKind::NoSpace;
            break;
        default:
            break;
        }
    } else if ([error.domain isEqualToString:NSPOSIXErrorDomain]) {
        switch (error.code) {
        case ENOENT:
        case ENOTDIR:
            result.kind = SyncFolder::ErrorKind::NotFound;
            break;
        case EACCES:
        case EPERM:
            result.kind = SyncFolder::ErrorKind::Unavailable;
            break;
        case ENOSPC:
        case EDQUOT:
            result.kind = SyncFolder::ErrorKind::NoSpace;
            break;
        default:
            break;
        }
    }
    // 底层原因有时包在 NSUnderlyingErrorKey 里（例如协调失败包着文件不存在）：外层没认出来就看里层。
    NSError* underlying = error.userInfo[NSUnderlyingErrorKey];
    if (result.kind == SyncFolder::ErrorKind::Io && underlying != nil) {
        const SyncFolder::Error inner = errorFrom(underlying, context);
        result.kind = inner.kind;
    }
    return result;
}

void setError(SyncFolder::Error* target, const SyncFolder::Error& error)
{
    if (target) {
        *target = error;
    }
}

} // namespace

struct IosSyncFolder::State {
    QByteArray bookmark;
    std::function<void(const QByteArray&)> bookmarkRefreshed;
    NSURL* root = nil;
    bool accessing = false;
    AppleCoordinatedFiles files;

    NSURL* urlFor(const QString& relativePath) const
    {
        if (relativePath.isEmpty()) {
            return root;
        }
        return [root URLByAppendingPathComponent:relativePath.toNSString()];
    }

    void releaseAccess()
    {
        if (root != nil && accessing) {
            [root stopAccessingSecurityScopedResource];
        }
        accessing = false;
        root = nil;
    }
};

IosSyncFolder::IosSyncFolder(QByteArray bookmark, std::function<void(const QByteArray&)> bookmarkRefreshed)
    : d(std::make_unique<State>())
{
    d->bookmark = std::move(bookmark);
    d->bookmarkRefreshed = std::move(bookmarkRefreshed);
}

IosSyncFolder::~IosSyncFolder()
{
    d->releaseAccess();
}

bool IosSyncFolder::open(Error* error)
{
    @autoreleasepool {
        // 已经打开着：确认文件夹还在（可能被删了、iCloud 被关了），在的话直接用，不必每轮重新解析书签。
        if (d->root != nil && d->accessing) {
            NSError* reachError = nil;
            if ([d->root checkResourceIsReachableAndReturnError:&reachError]) {
                return true;
            }
            d->releaseAccess();
        }
        if (d->bookmark.isEmpty()) {
            setError(error, {ErrorKind::Unavailable, QStringLiteral("还没有选择同步文件夹")});
            return false;
        }
        BOOL stale = NO;
        NSError* resolveError = nil;
        NSURL* url = [NSURL URLByResolvingBookmarkData:d->bookmark.toNSData()
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:&resolveError];
        if (url == nil) {
            SyncFolder::Error failure = errorFrom(resolveError, QStringLiteral("找不到之前选的同步文件夹"));
            failure.kind = ErrorKind::Unavailable;
            setError(error, failure);
            return false;
        }
        d->accessing = [url startAccessingSecurityScopedResource];
        d->root = url;
        if (stale) {
            // 过期的书签这一次还能用，但系统要求换一份新的；不换的话，下次启动可能就解析不出来了。
            NSError* refreshError = nil;
            NSData* fresh = [url bookmarkDataWithOptions:0
                          includingResourceValuesForKeys:nil
                                           relativeToURL:nil
                                                   error:&refreshError];
            if (fresh != nil) {
                d->bookmark = QByteArray::fromNSData(fresh);
                if (d->bookmarkRefreshed) {
                    d->bookmarkRefreshed(d->bookmark);
                }
            }
        }
        if (!d->accessing) {
            d->releaseAccess();
            setError(error, {ErrorKind::Unavailable, QStringLiteral("没有访问同步文件夹的权限，请重新选择文件夹")});
            return false;
        }
        NSError* reachError = nil;
        if (![url checkResourceIsReachableAndReturnError:&reachError]) {
            SyncFolder::Error failure = errorFrom(reachError, QStringLiteral("同步文件夹暂时打不开"));
            failure.kind = ErrorKind::Unavailable;
            d->releaseAccess();
            setError(error, failure);
            return false;
        }
        setError(error, {});
        return true;
    }
}

QString IosSyncFolder::name() const
{
    return d->root == nil ? QString() : QString::fromNSString(d->root.lastPathComponent);
}

QString IosSyncFolder::displayPath() const
{
    return d->root == nil ? QString() : QString::fromNSString(d->root.path);
}

QStringList IosSyncFolder::list(const QString& relativeDir, Error* error)
{
    @autoreleasepool {
        NSError* listError = nil;
        NSArray<NSURL*>* items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:d->urlFor(relativeDir)
                                                               includingPropertiesForKeys:nil
                                                                                  options:0
                                                                                    error:&listError];
        if (items == nil) {
            setError(error, errorFrom(listError, QStringLiteral("列不出同步文件夹里的内容")));
            return {};
        }
        QStringList names;
        QSet<QString> seen;
        for (NSURL* item in items) {
            QString name = QString::fromNSString(item.lastPathComponent);
            // 还没下载的文件，较早的系统在目录里只放一个「.原名.icloud」占位。按原名报上去：
            // 协调读取原名时系统会先把它下载下来。
            if (name.startsWith(QLatin1Char('.')) && name.endsWith(QStringLiteral(".icloud"))) {
                name = name.mid(1, name.size() - 1 - int(qstrlen(".icloud")));
            }
            if (!name.isEmpty() && !seen.contains(name)) {
                seen.insert(name);
                names.append(name);
            }
        }
        setError(error, {});
        return names;
    }
}

bool IosSyncFolder::read(const QString& relativePath, QByteArray* data, Error* error)
{
    @autoreleasepool {
        return d->files.read(QString::fromNSString(d->urlFor(relativePath).path), relativePath, data, error);
    }
}

bool IosSyncFolder::write(const QString& relativePath, const QByteArray& data, Error* error)
{
    @autoreleasepool {
        return d->files.write(QString::fromNSString(d->urlFor(relativePath).path), relativePath, data, error);
    }
}

bool IosSyncFolder::remove(const QString& relativePath, Error* error)
{
    @autoreleasepool {
        return d->files.remove(QString::fromNSString(d->urlFor(relativePath).path), relativePath, error);
    }
}

QString IosSyncFolder::uploadProblem(const QString& relativePath)
{
    if (d->root == nil) {
        return {};
    }
    @autoreleasepool {
        return AppleUbiquitousItem::uploadProblem(QString::fromNSString(d->urlFor(relativePath).path));
    }
}

void IosSyncFolder::cancelPendingIo()
{
    d->files.cancelPendingIo();
}
