#include "AppleCoordinatedFiles.h"
#include "../../services/SyncFiles.h"

#import <Foundation/Foundation.h>

#include <cerrno>
#include <mutex>

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

struct AppleCoordinatedFiles::State {
    // 同一工作线程一次只协调一个文件；取消线程只能在锁内取得当前协调者的强引用。
    std::mutex mutex;
    NSFileCoordinator* current = nil;

    NSFileCoordinator* beginCoordination()
    {
        NSFileCoordinator* coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        const std::lock_guard<std::mutex> lock(mutex);
        current = coordinator;
        return coordinator;
    }

    void endCoordination()
    {
        const std::lock_guard<std::mutex> lock(mutex);
        current = nil;
    }
};

AppleCoordinatedFiles::AppleCoordinatedFiles() : d(std::make_unique<State>()) {}
AppleCoordinatedFiles::~AppleCoordinatedFiles() = default;

bool AppleCoordinatedFiles::read(const QString& absolutePath, const QString& relativePath,
                                 QByteArray* data, SyncFolder::Error* error)
{
    @autoreleasepool {
        const qint64 budget = SyncFiles::maxBudgetForPath(relativePath);
        if (budget <= 0) {
            setError(error, {SyncFolder::ErrorKind::Io, QStringLiteral("拒绝读取未知同步文件: %1").arg(relativePath)});
            return false;
        }
        __block NSData* content = nil;
        __block NSError* readError = nil;
        __block bool exceededBudget = false;
        NSError* coordinationError = nil;
        NSFileCoordinator* coordinator = d->beginCoordination();
        [coordinator coordinateReadingItemAtURL:[NSURL fileURLWithPath:absolutePath.toNSString()]
                                        options:0
                                          error:&coordinationError
                                     byAccessor:^(NSURL* newURL) {
            NSError* localError = nil;
            // 在分配 NSData 之前通过文件属性检查大小，超出预算时直接拒绝，防止极端大文件耗尽内存
            NSDictionary<NSFileAttributeKey, id>* attrs =
                [[NSFileManager defaultManager] attributesOfItemAtPath:newURL.path error:&localError];
            if (attrs != nil) {
                const unsigned long long fileSize = [attrs fileSize];
                if (fileSize > static_cast<unsigned long long>(budget)) {
                    exceededBudget = true;
                    return;
                }
            }
            content = [NSData dataWithContentsOfURL:newURL options:0 error:&localError];
            readError = localError;
        }];
        d->endCoordination();
        if (exceededBudget) {
            setError(error, {SyncFolder::ErrorKind::Io, QStringLiteral("文件大小超出预算上限: %1").arg(relativePath)});
            return false;
        }
        if (coordinationError != nil || content == nil) {
            setError(error, errorFrom(coordinationError ?: readError, QStringLiteral("读不出 %1").arg(relativePath)));
            return false;
        }
        // 二次防御：在 NSData 读取成功后追加实际 content.length 检查，
        // 保证在属性检查失效（attrs 为 nil）或读取过程中文件并发增长时同样阻断
        if (static_cast<qint64>(content.length) > budget) {
            setError(error, {SyncFolder::ErrorKind::Io, QStringLiteral("文件大小超出预算上限: %1").arg(relativePath)});
            return false;
        }
        *data = QByteArray::fromNSData(content);
        setError(error, {});
        return true;
    }
}

bool AppleCoordinatedFiles::write(const QString& absolutePath, const QString& relativePath,
                                  const QByteArray& data, SyncFolder::Error* error)
{
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:absolutePath.toNSString()];
        NSError* directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:[url URLByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&directoryError]) {
            setError(error, errorFrom(directoryError, QStringLiteral("建不了目录")));
            return false;
        }
        NSData* payload = data.toNSData();
        __block BOOL written = NO;
        __block NSError* writeError = nil;
        NSError* coordinationError = nil;
        NSFileCoordinator* coordinator = d->beginCoordination();
        // NSFileCoordinator（系统文件协调）先通知文件呈现者，让 iCloud 准备好文件。
        // 先写临时文件、写完整再换上（NSDataWritingAtomic）：对方永远读不到写了一半的文件。
        [coordinator coordinateWritingItemAtURL:url
                                        options:NSFileCoordinatorWritingForReplacing
                                          error:&coordinationError
                                     byAccessor:^(NSURL* newURL) {
            NSError* localError = nil;
            written = [payload writeToURL:newURL options:NSDataWritingAtomic error:&localError];
            writeError = localError;
        }];
        d->endCoordination();
        if (coordinationError != nil || !written) {
            setError(error, errorFrom(coordinationError ?: writeError, QStringLiteral("写不进 %1").arg(relativePath)));
            return false;
        }
        setError(error, {});
        return true;
    }
}

bool AppleCoordinatedFiles::remove(const QString& absolutePath, const QString& relativePath,
                                   SyncFolder::Error* error)
{
    @autoreleasepool {
        __block BOOL removed = NO;
        __block NSError* removeError = nil;
        NSError* coordinationError = nil;
        NSFileCoordinator* coordinator = d->beginCoordination();
        [coordinator coordinateWritingItemAtURL:[NSURL fileURLWithPath:absolutePath.toNSString()]
                                        options:NSFileCoordinatorWritingForDeleting
                                          error:&coordinationError
                                     byAccessor:^(NSURL* newURL) {
            NSError* localError = nil;
            removed = [[NSFileManager defaultManager] removeItemAtURL:newURL error:&localError];
            removeError = localError;
        }];
        d->endCoordination();
        if (coordinationError == nil && removed) {
            setError(error, {});
            return true;
        }
        const SyncFolder::Error failure = errorFrom(coordinationError ?: removeError,
                                                    QStringLiteral("删不掉 %1").arg(relativePath));
        // 本来就不存在也算删掉了：对方可能已经删过。
        if (failure.kind == SyncFolder::ErrorKind::NotFound) {
            setError(error, {});
            return true;
        }
        setError(error, failure);
        return false;
    }
}

void AppleCoordinatedFiles::cancelPendingIo()
{
    NSFileCoordinator* coordinator = nil;
    {
        const std::lock_guard<std::mutex> lock(d->mutex);
        coordinator = d->current;
    }
    // 苹果文档：cancel 可以从任何线程调用，正在等的协调会以错误结束。
    [coordinator cancel];
}
