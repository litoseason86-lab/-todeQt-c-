#import <Foundation/Foundation.h>

#include "../src/platform/macos/MacSyncFolder.h"
#include "../src/services/SyncFiles.h"

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QFuture>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QtConcurrent>
#include <QtTest>

#include <atomic>
#include <mutex>

// 文件呈现者在独立串行队列上应答，避免测试主线程等待协调时把通知也堵在同一个线程。
@interface SyncFilePresenter : NSObject <NSFilePresenter> {
@public
    std::atomic<int> readRequests;
    std::atomic<int> writeRequests;
    std::atomic<int> deletionRequests;
@private
    NSURL* _url;
    NSOperationQueue* _queue;
    std::mutex _mutex;
    bool _holdReads;
    void (^_pendingReader)(void (^)(void));
}
- (instancetype)initWithPath:(const QString&)path holdReads:(bool)holdReads;
- (void)releaseHeldRead;
@end

@implementation SyncFilePresenter
- (instancetype)initWithPath:(const QString&)path holdReads:(bool)holdReads
{
    self = [super init];
    if (self) {
        _url = [NSURL fileURLWithPath:path.toNSString()];
        _queue = [NSOperationQueue new];
        _queue.maxConcurrentOperationCount = 1;
        _holdReads = holdReads;
        readRequests = 0;
        writeRequests = 0;
        deletionRequests = 0;
    }
    return self;
}
- (NSURL*)presentedItemURL { return _url; }
- (NSOperationQueue*)presentedItemOperationQueue { return _queue; }
- (void)relinquishPresentedItemToReader:(void (^)(void (^)(void)))reader
{
    {
        const std::lock_guard<std::mutex> lock(_mutex);
        if (_holdReads) {
            _pendingReader = [reader copy];
            ++readRequests;
            return;
        }
    }
    ++readRequests;
    reader(^{});
}
- (void)relinquishPresentedItemToWriter:(void (^)(void (^)(void)))writer
{
    ++writeRequests;
    writer(^{});
}
- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError*))completionHandler
{
    ++deletionRequests;
    completionHandler(nil);
}
- (void)releaseHeldRead
{
    void (^reader)(void (^)(void)) = nil;
    {
        const std::lock_guard<std::mutex> lock(_mutex);
        _holdReads = false;
        reader = _pendingReader;
        _pendingReader = nil;
    }
    if (reader) reader(^{});
}
@end

namespace {
struct AccessResult {
    bool success = false;
    SyncFolder::Error error;
    QByteArray data = QByteArrayLiteral("未读取");
};

QFuture<AccessResult> accessFile(MacSyncFolder* folder, const QString& action, const QString& path)
{
    // 与生产一致，把可能等下载或文件呈现者的操作放到工作线程；测试主线程继续处理事件。
    return QtConcurrent::run([folder, action, path] {
        @autoreleasepool {
            AccessResult result;
            if (action == QStringLiteral("read")) {
                result.success = folder->read(path, &result.data, &result.error);
            } else if (action == QStringLiteral("write")) {
                result.success = folder->write(path, QByteArrayLiteral("替换内容"), &result.error);
            } else {
                result.success = folder->remove(path, &result.error);
            }
            return result;
        }
    });
}
}

class MacSyncFolderTests : public QObject
{
    Q_OBJECT
private slots:
    void coordinatedAccessNotifiesPresenter_data();
    void coordinatedAccessNotifiesPresenter();
    void cancellationUnblocksHeldRead();
    void readRejectsOversizedFiles_data();
    void readRejectsOversizedFiles();
    void writeCreatesParentsAndMissingRemovalSucceeds();
};

// 保证 Mac 同步文件的读、写、删均通过文件协调，文件呈现者能在操作前作出响应。
void MacSyncFolderTests::coordinatedAccessNotifiesPresenter_data()
{
    QTest::addColumn<QString>("action");
    QTest::newRow("read") << QStringLiteral("read");
    QTest::newRow("write") << QStringLiteral("write");
    QTest::newRow("remove") << QStringLiteral("remove");
}

// 保证读写删通知来自真实系统协调，且操作仍产生完整的预期文件内容。
void MacSyncFolderTests::coordinatedAccessNotifiesPresenter()
{
    QFETCH(QString, action);
    QTemporaryDir drive;
    QVERIFY(drive.isValid());
    MacSyncFolder folder(QDir(drive.path()).canonicalPath());
    SyncFolder::Error error;
    QVERIFY(folder.open(&error));
    const QString relativePath = SyncFiles::markerFileName();
    const QString path = QDir(folder.displayPath()).filePath(relativePath);
    QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write("original"), 8);
    file.close();

    SyncFilePresenter* presenter = [[SyncFilePresenter alloc] initWithPath:path holdReads:false];
    [NSFileCoordinator addFilePresenter:presenter];
    const auto unregister = qScopeGuard([&] {
        [presenter releaseHeldRead];
        [NSFileCoordinator removeFilePresenter:presenter];
        [presenter.presentedItemOperationQueue waitUntilAllOperationsAreFinished];
    });
    QCOMPARE(presenter->readRequests.load(), 0);
    QCOMPARE(presenter->writeRequests.load(), 0);
    QCOMPARE(presenter->deletionRequests.load(), 0);
    auto future = accessFile(&folder, action, relativePath);
    // 断言失败也取消并回收自己的操作，避免悬空的 folder 或登记影响后续用例。
    const auto finish = qScopeGuard([&] {
        folder.cancelPendingIo();
        [presenter releaseHeldRead];
        future.waitForFinished();
    });
    QTRY_VERIFY_WITH_TIMEOUT(future.isFinished(), 5000);
    const AccessResult result = future.result();
    QVERIFY2(result.success, qPrintable(result.error.message));
    QVERIFY(result.error.ok());
    if (action == QStringLiteral("read")) {
        QCOMPARE(result.data, QByteArrayLiteral("original"));
        QVERIFY2(presenter->readRequests.load() > 0, "读取未通知文件呈现者");
    } else {
        // 替换和删除都会要求呈现者让出写权限或同意删除，均应在访问文件前发生。
        QVERIFY2(presenter->writeRequests.load() + presenter->deletionRequests.load() > 0,
                 "写入或删除未通知文件呈现者");
        if (action == QStringLiteral("write")) {
            QVERIFY(file.open(QIODevice::ReadOnly));
            QCOMPARE(file.readAll(), QByteArrayLiteral("替换内容"));
        } else {
            QVERIFY(!QFileInfo::exists(path));
        }
    }
}

// 保证退出时跨线程取消可结束正在等文件呈现者的读取，无须等对方让出文件。
void MacSyncFolderTests::cancellationUnblocksHeldRead()
{
    QTemporaryDir drive;
    QVERIFY(drive.isValid());
    MacSyncFolder folder(QDir(drive.path()).canonicalPath());
    SyncFolder::Error error;
    QVERIFY(folder.open(&error));
    const QString relativePath = SyncFiles::markerFileName();
    const QString path = QDir(folder.displayPath()).filePath(relativePath);
    QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write("original"), 8);
    file.close();

    // 只在隔离的临时文件上扣住 reader 回调，不交还访问权，稳定模拟协调卡住；清理时无条件放行。
    SyncFilePresenter* presenter = [[SyncFilePresenter alloc] initWithPath:path holdReads:true];
    [NSFileCoordinator addFilePresenter:presenter];
    const auto unregister = qScopeGuard([&] {
        [presenter releaseHeldRead];
        [NSFileCoordinator removeFilePresenter:presenter];
        [presenter.presentedItemOperationQueue waitUntilAllOperationsAreFinished];
    });
    QCOMPARE(presenter->readRequests.load(), 0);
    auto future = accessFile(&folder, QStringLiteral("read"), relativePath);
    const auto finish = qScopeGuard([&] {
        folder.cancelPendingIo();
        [presenter releaseHeldRead];
        future.waitForFinished();
    });
    QTRY_VERIFY_WITH_TIMEOUT(presenter->readRequests.load() > 0 || future.isFinished(), 5000);
    QVERIFY2(presenter->readRequests.load() > 0, "读取未进入协调，无法验证取消等待");
    QVERIFY(!future.isFinished());
    QElapsedTimer timer;
    timer.start();
    // 读取占着工作线程，取消从测试主线程发起，遵循 cancelPendingIo 的跨线程契约。
    folder.cancelPendingIo();
    QTRY_VERIFY_WITH_TIMEOUT(future.isFinished(), 3000);
    QVERIFY(timer.elapsed() < 3000);
    const AccessResult result = future.result();
    QVERIFY(!result.success);
    QCOMPARE(result.error.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(!result.error.message.isEmpty());
    QCOMPARE(result.data, QByteArrayLiteral("未读取"));
}

// 保证 Mac 对标记、游标、改动和快照分别执行已有的读取预算，未知文件同样拒绝。
void MacSyncFolderTests::readRejectsOversizedFiles_data()
{
    QTest::addColumn<QString>("relativePath");
    QTest::newRow("marker") << SyncFiles::markerFileName();
    QTest::newRow("cursor") << QStringLiteral("devices/test/cursor.json");
    QTest::newRow("changes") << QStringLiteral("devices/test/changes/0000-00000001.json");
    QTest::newRow("snapshot") << QStringLiteral("devices/test/snapshot-0000-00000001.json");
    QTest::newRow("unknown") << QStringLiteral("unexpected.bin");
}

// 保证超预算读取返回错误且不交付部分内容，不能把拒绝误报成空文件成功。
void MacSyncFolderTests::readRejectsOversizedFiles()
{
    QFETCH(QString, relativePath);
    QTemporaryDir drive;
    QVERIFY(drive.isValid());
    MacSyncFolder folder(QDir(drive.path()).canonicalPath());
    SyncFolder::Error error;
    QVERIFY(folder.open(&error));
    const qint64 budget = SyncFiles::maxBudgetForPath(relativePath);
    QVERIFY(budget >= 0);
    const QString path = QDir(folder.displayPath()).filePath(relativePath);
    QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    // 用稀疏文件制造超限，不在测试中分配整份 64 MiB 快照内容。
    QVERIFY(file.resize(budget + 1));
    file.close();
    QCOMPARE(QFileInfo(path).size(), budget + 1);
    auto future = accessFile(&folder, QStringLiteral("read"), relativePath);
    const auto finish = qScopeGuard([&] { folder.cancelPendingIo(); future.waitForFinished(); });
    QTRY_VERIFY_WITH_TIMEOUT(future.isFinished(), 5000);
    const AccessResult result = future.result();
    QVERIFY(!result.success);
    QCOMPARE(result.error.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(!result.error.message.isEmpty());
    QCOMPARE(result.data, QByteArrayLiteral("未读取"));
}

// 保证首次写入连父目录一起创建，完整内容可读回，重复删除不存在的文件也成功。
void MacSyncFolderTests::writeCreatesParentsAndMissingRemovalSucceeds()
{
    QTemporaryDir drive;
    QVERIFY(drive.isValid());
    MacSyncFolder folder(QDir(drive.path()).canonicalPath());
    SyncFolder::Error error;
    QVERIFY(folder.open(&error));
    const QString relativePath = QStringLiteral("devices/test/cursor.json");
    const QString path = QDir(folder.displayPath()).filePath(relativePath);
    QVERIFY(!QFileInfo(path).absoluteDir().exists());
    QVERIFY(folder.write(relativePath, QByteArrayLiteral("complete"), &error));
    QVERIFY(error.ok());
    QByteArray content;
    QVERIFY(folder.read(relativePath, &content, &error));
    QCOMPARE(content, QByteArrayLiteral("complete"));
    QVERIFY(folder.remove(relativePath, &error));
    QVERIFY(error.ok());
    QVERIFY(!QFileInfo::exists(path));
    QVERIFY(folder.remove(relativePath, &error));
    QVERIFY(error.ok());
    QVERIFY(!folder.read(relativePath, &content, &error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::NotFound);
}

QTEST_GUILESS_MAIN(MacSyncFolderTests)
#include "MacSyncFolderTests.moc"
