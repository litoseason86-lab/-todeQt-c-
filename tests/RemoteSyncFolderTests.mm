#include "../src/platform/apple/AppleSyncBlockCipher.h"
#include "../src/platform/apple/AppleSyncHttpClient.h"
#include "../src/services/LocalSyncFolder.h"
#include "../src/services/RemoteSyncFolder.h"
#include "../src/services/SyncCrypto.h"
#include "../src/services/SyncFiles.h"

#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QHostAddress>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QScopeGuard>
#include <QSet>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

namespace {

class CountingHttpClient final : public SyncHttpClient
{
public:
    Response send(const Request& request) override
    {
        Q_UNUSED(request);
        ++calls;
        Response response;
        response.failure = Failure::Network;
        response.message = QStringLiteral("不应发出请求");
        return response;
    }

    void cancelAll() override { ++cancellations; }

    std::atomic<int> calls{0};
    std::atomic<int> cancellations{0};
};

class BlockingHttpClient final : public SyncHttpClient
{
public:
    Response send(const Request& request) override
    {
        Q_UNUSED(request);
        entered.store(true);
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [this] { return cancelled; });
        Response response;
        response.failure = Failure::Cancelled;
        response.message = QStringLiteral("测试取消");
        return response;
    }

    void cancelAll() override
    {
        {
            const std::lock_guard<std::mutex> lock(mutex);
            cancelled = true;
        }
        condition.notify_all();
    }

    std::atomic<bool> entered{false};
    std::mutex mutex;
    std::condition_variable condition;
    bool cancelled = false;
};

QByteArray secret(char value)
{
    return QByteArray(32, value);
}

QStringList sorted(QStringList values)
{
    values.sort();
    return values;
}

} // namespace

class RemoteSyncFolderTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void openCachesEmptyTreeAndMissingDirectoryIsNotFound();
    void matchesLocalFolderForNestedWritesAndLists();
    void removeKeepsDirectoriesAndMissingFilesAreBenign();
    void serverStoresOnlySealedBytes();
    void rejectsWrongPairingTamperingAndCrossPathCopy();
    void mapsServerLossAndRejectsUnsafeBaseUrlWithoutRequest();
    void mapsQuotaFailureWithoutLosingFirstFile();
    void cancellationUnblocksFakeAndAppleClients();
    void appleClientAndFolderDoNotFollowRedirects();

private:
    QUrl baseUrl() const;
    RemoteSyncFolder::Config config(const QString& space,
                                    const QByteArray& pairSecret) const;
    bool createSpace(const QString& space, const QByteArray& pairSecret,
                     QString* error);
    std::unique_ptr<RemoteSyncFolder> folder(
        const QString& space, const QByteArray& pairSecret) const;
    QString diskFilePath(const QString& space, const QString& relativePath) const;
    void stopServer();

    std::unique_ptr<QTemporaryDir> stateDirectory;
    QProcess* server = nullptr;
    QString serverOutput;
    quint16 serverPort = 0;
    QString enrollSecret;
};

void RemoteSyncFolderTests::init()
{
    stateDirectory = std::make_unique<QTemporaryDir>(
        QDir::tempPath() + QStringLiteral("/pt-remote-sync-test-XXXXXX"));
    QVERIFY(stateDirectory->isValid());
    serverOutput.clear();
    serverPort = 0;
    enrollSecret = QStringLiteral("enroll-secret-for-remote-folder-tests");

    const QString enrollFile
        = stateDirectory->filePath(QStringLiteral("enroll.sha256"));
    QFile file(enrollFile);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    const QByteArray digest = QCryptographicHash::hash(
        enrollSecret.toUtf8(), QCryptographicHash::Sha256).toHex();
    QCOMPARE(file.write(digest), digest.size());
    file.close();

    server = new QProcess(this);
    server->setProcessChannelMode(QProcess::SeparateChannels);
    connect(server, &QProcess::readyReadStandardOutput, this, [this] {
        serverOutput += QString::fromUtf8(server->readAllStandardOutput());
        static const QRegularExpression readyPattern(
            QStringLiteral("PT_SYNC_READY (\\d+)"));
        const QRegularExpressionMatch match = readyPattern.match(serverOutput);
        if (match.hasMatch()) {
            serverPort = static_cast<quint16>(match.captured(1).toUInt());
        }
    });
    server->start(
        QStringLiteral(PTSYNC_PYTHON3_EXECUTABLE),
        {
            QStringLiteral("-I"),
            QStringLiteral(PTSYNC_SOURCE_DIR)
                + QStringLiteral("/server/pt_sync_server.py"),
            QStringLiteral("serve"),
            QStringLiteral("--host"),
            QStringLiteral("127.0.0.1"),
            QStringLiteral("--port"),
            QStringLiteral("0"),
            QStringLiteral("--state-dir"),
            stateDirectory->filePath(QStringLiteral("state")),
            QStringLiteral("--enroll-hash-file"),
            enrollFile,
            QStringLiteral("--max-space-bytes"),
            QStringLiteral("300"),
        });
    QVERIFY2(server->waitForStarted(5000), qPrintable(server->errorString()));
    QTRY_VERIFY_WITH_TIMEOUT(serverPort != 0, 5000);
}

void RemoteSyncFolderTests::cleanup()
{
    stopServer();
    stateDirectory.reset();
}

void RemoteSyncFolderTests::stopServer()
{
    if (!server) {
        return;
    }
    if (server->state() != QProcess::NotRunning) {
        server->terminate();
        if (!server->waitForFinished(3000)) {
            server->kill();
            server->waitForFinished(3000);
        }
    }
    delete server;
    server = nullptr;
}

QUrl RemoteSyncFolderTests::baseUrl() const
{
    return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(serverPort));
}

RemoteSyncFolder::Config RemoteSyncFolderTests::config(
    const QString& space, const QByteArray& pairSecret) const
{
    return {baseUrl(), space, pairSecret};
}

bool RemoteSyncFolderTests::createSpace(
    const QString& space, const QByteArray& pairSecret, QString* error)
{
    const SyncCrypto::Keys keys
        = SyncCrypto::deriveKeys(pairSecret, space);
    const QByteArray tokenText
        = SyncCrypto::authTokenText(keys).toUtf8();
    const QByteArray tokenHash
        = QCryptographicHash::hash(tokenText, QCryptographicHash::Sha256)
              .toHex();
    const QJsonObject body{
        {QStringLiteral("space"), space},
        {QStringLiteral("tokenSha256"), QString::fromLatin1(tokenHash)},
    };

    AppleSyncHttpClient client;
    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("POST");
    request.url = QUrl(baseUrl().toString() + QStringLiteral("/v1/spaces"));
    request.timeoutMs = 5000;
    request.headers = {
        {QByteArrayLiteral("Content-Type"), QByteArrayLiteral("application/json")},
        {QByteArrayLiteral("X-PT-Enroll"), enrollSecret.toUtf8()},
    };
    request.body = QJsonDocument(body).toJson(QJsonDocument::Compact);
    const SyncHttpClient::Response response = client.send(request);
    if (response.failure != SyncHttpClient::Failure::None
        || response.status != 201) {
        if (error) {
            *error = response.failure != SyncHttpClient::Failure::None
                ? response.message
                : QStringLiteral("建空间 HTTP %1：%2")
                      .arg(response.status)
                      .arg(QString::fromUtf8(response.body));
        }
        return false;
    }
    return true;
}

std::unique_ptr<RemoteSyncFolder> RemoteSyncFolderTests::folder(
    const QString& space, const QByteArray& pairSecret) const
{
    return std::make_unique<RemoteSyncFolder>(
        config(space, pairSecret),
        std::make_shared<AppleSyncHttpClient>(),
        std::make_shared<AppleSyncBlockCipher>());
}

QString RemoteSyncFolderTests::diskFilePath(
    const QString& space, const QString& relativePath) const
{
    return stateDirectory->filePath(
        QStringLiteral("state/spaces/") + space
        + QStringLiteral("/files/") + relativePath);
}

// 保证 open() 只缓存服务器树，空空间根目录存在而未出现过的子目录是 NotFound。
void RemoteSyncFolderTests::openCachesEmptyTreeAndMissingDirectoryIsNotFound()
{
    const QString space = QStringLiteral("space-1234567890ab01");
    QString createError;
    QVERIFY2(createSpace(space, secret('A'), &createError),
             qPrintable(createError));
    auto remote = folder(space, secret('A'));
    SyncFolder::Error error;
    QVERIFY2(remote->open(&error), qPrintable(error.message));
    QCOMPARE(remote->list(QString(), &error), QStringList());
    QVERIFY(error.ok());
    QCOMPARE(remote->list(QStringLiteral("devices"), &error), QStringList());
    QCOMPARE(error.kind, SyncFolder::ErrorKind::NotFound);
}

// 保证同一组中文标记、游标和改动文件在远端和本地产生一致的读写内容与目录清单。
void RemoteSyncFolderTests::matchesLocalFolderForNestedWritesAndLists()
{
    const QString space = QStringLiteral("space-1234567890ab02");
    QString createError;
    QVERIFY2(createSpace(space, secret('B'), &createError),
             qPrintable(createError));
    auto remote = folder(space, secret('B'));
    QTemporaryDir localDirectory;
    QVERIFY(localDirectory.isValid());
    LocalSyncFolder local(localDirectory.path());
    SyncFolder::Error error;
    QVERIFY2(remote->open(&error), qPrintable(error.message));
    QVERIFY2(local.open(&error), qPrintable(error.message));

    const QString device = QStringLiteral("0123456789abcdef0123456789abcdef");
    const QList<QPair<QString, QByteArray>> files = {
        {SyncFiles::markerFileName(), QByteArrayLiteral("marker-content")},
        {SyncFiles::deviceDirectory(device) + QStringLiteral("/cursor.json"),
         QByteArrayLiteral("cursor-content")},
        {SyncFiles::changesDirectory(device)
             + QStringLiteral("/0000-00000001.json"),
         QByteArrayLiteral("change-content")},
    };
    for (const auto& file : files) {
        QVERIFY2(remote->write(file.first, file.second, &error),
                 qPrintable(error.message));
        QVERIFY2(local.write(file.first, file.second, &error),
                 qPrintable(error.message));
        QByteArray remoteRead;
        QByteArray localRead;
        QVERIFY2(remote->read(file.first, &remoteRead, &error),
                 qPrintable(error.message));
        QVERIFY2(local.read(file.first, &localRead, &error),
                 qPrintable(error.message));
        QCOMPARE(remoteRead, file.second);
        QCOMPARE(localRead, file.second);
    }

    for (const QString& directory :
         {QString(), SyncFiles::devicesDirectory(),
          SyncFiles::changesDirectory(device)}) {
        QCOMPARE(sorted(remote->list(directory, &error)),
                 sorted(local.list(directory, &error)));
        QVERIFY(error.ok());
    }
}

// 保证删除只移除文件、保留空目录，重复删除成功，读取已删文件返回 NotFound。
void RemoteSyncFolderTests::removeKeepsDirectoriesAndMissingFilesAreBenign()
{
    const QString space = QStringLiteral("space-1234567890ab03");
    QString createError;
    QVERIFY2(createSpace(space, secret('C'), &createError),
             qPrintable(createError));
    auto remote = folder(space, secret('C'));
    SyncFolder::Error error;
    QVERIFY2(remote->open(&error), qPrintable(error.message));
    const QString path
        = QStringLiteral("devices/0123456789abcdef0123456789abcdef/changes/"
                         "0000-00000001.json");
    QVERIFY2(remote->write(path, QByteArrayLiteral("data"), &error),
             qPrintable(error.message));
    QVERIFY2(remote->remove(path, &error), qPrintable(error.message));
    QVERIFY(!remote->list(
                 QStringLiteral("devices/0123456789abcdef0123456789abcdef/changes"),
                 &error)
                 .contains(QStringLiteral("0000-00000001.json")));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::None);
    QVERIFY2(remote->remove(path, &error), qPrintable(error.message));
    QByteArray content;
    QVERIFY(!remote->read(path, &content, &error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::NotFound);
}

// 保证服务器磁盘上的同步文件只有 PTE1 密文，找不到写入时使用的明文特征串。
void RemoteSyncFolderTests::serverStoresOnlySealedBytes()
{
    const QString space = QStringLiteral("space-1234567890ab04");
    QString createError;
    QVERIFY2(createSpace(space, secret('D'), &createError),
             qPrintable(createError));
    auto remote = folder(space, secret('D'));
    SyncFolder::Error error;
    QVERIFY2(remote->open(&error), qPrintable(error.message));
    const QByteArray plain
        = QByteArrayLiteral("server-must-never-see-this-plaintext-7f29");
    QVERIFY2(remote->write(SyncFiles::markerFileName(), plain, &error),
             qPrintable(error.message));

    QFile encrypted(diskFilePath(space, SyncFiles::markerFileName()));
    QVERIFY2(encrypted.open(QIODevice::ReadOnly), qPrintable(encrypted.fileName()));
    const QByteArray bytes = encrypted.readAll();
    QVERIFY(bytes.startsWith("PTE1"));
    QVERIFY(!bytes.contains(plain));
}

// 保证错误配对无法打开空间，密文改字节和跨路径复制都在认证阶段失败。
void RemoteSyncFolderTests::rejectsWrongPairingTamperingAndCrossPathCopy()
{
    const QString space = QStringLiteral("space-1234567890ab05");
    QString createError;
    QVERIFY2(createSpace(space, secret('E'), &createError),
             qPrintable(createError));
    auto remote = folder(space, secret('E'));
    SyncFolder::Error error;
    QVERIFY2(remote->open(&error), qPrintable(error.message));

    auto wrongPairing = folder(space, secret('F'));
    QVERIFY(!wrongPairing->open(&error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Unavailable);

    const QString first
        = QStringLiteral("devices/0123456789abcdef0123456789abcdef/changes/"
                         "0000-00000001.json");
    const QString second
        = QStringLiteral("devices/0123456789abcdef0123456789abcdef/changes/"
                         "0000-00000002.json");
    QVERIFY2(remote->write(first, QByteArrayLiteral("first"), &error),
             qPrintable(error.message));
    QVERIFY2(remote->write(second, QByteArrayLiteral("second"), &error),
             qPrintable(error.message));

    QFile::remove(diskFilePath(space, second));
    QVERIFY(QFile::copy(diskFilePath(space, first),
                        diskFilePath(space, second)));
    QByteArray content;
    QVERIFY(!remote->read(second, &content, &error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Io);
    QVERIFY(error.message.contains(QStringLiteral("校验不通过")));

    QVERIFY2(remote->write(first, QByteArrayLiteral("first-again"), &error),
             qPrintable(error.message));
    QFile tampered(diskFilePath(space, first));
    QVERIFY(tampered.open(QIODevice::ReadWrite));
    QVERIFY(tampered.seek(4 + 16));
    char byte = 0;
    QCOMPARE(tampered.read(&byte, 1), qint64(1));
    byte ^= 1;
    QVERIFY(tampered.seek(4 + 16));
    QCOMPARE(tampered.write(&byte, 1), qint64(1));
    tampered.close();
    QVERIFY(!remote->read(first, &content, &error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Io);
}

// 保证服务器断开映射为 Io，不安全地址在发送任何请求前就被拒绝。
void RemoteSyncFolderTests::mapsServerLossAndRejectsUnsafeBaseUrlWithoutRequest()
{
    const QString space = QStringLiteral("space-1234567890ab06");
    QString createError;
    QVERIFY2(createSpace(space, secret('G'), &createError),
             qPrintable(createError));
    auto remote = folder(space, secret('G'));
    SyncFolder::Error error;
    QVERIFY2(remote->open(&error), qPrintable(error.message));
    stopServer();
    QVERIFY(!remote->open(&error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Io);
    QByteArray content;
    QVERIFY(!remote->read(SyncFiles::markerFileName(), &content, &error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Io);

    QVERIFY(!RemoteSyncFolder::isAcceptableBaseUrl(
        QUrl(QStringLiteral("http://example.com"))));
    QVERIFY(RemoteSyncFolder::isAcceptableBaseUrl(
        QUrl(QStringLiteral("https://example.com"))));
    QVERIFY(RemoteSyncFolder::isAcceptableBaseUrl(
        QUrl(QStringLiteral("http://127.0.0.1:1234"))));

    auto counting = std::make_shared<CountingHttpClient>();
    RemoteSyncFolder rejected(
        {QUrl(QStringLiteral("http://example.com")), space, secret('G')},
        counting, std::make_shared<AppleSyncBlockCipher>());
    QVERIFY(!rejected.open(&error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::Unavailable);
    QCOMPARE(counting->calls.load(), 0);
}

// 保证远端空间配额超限返回 NoSpace，且先前已经写入的文件仍可完整读回。
void RemoteSyncFolderTests::mapsQuotaFailureWithoutLosingFirstFile()
{
    const QString space = QStringLiteral("space-1234567890ab07");
    QString createError;
    QVERIFY2(createSpace(space, secret('H'), &createError),
             qPrintable(createError));
    auto remote = folder(space, secret('H'));
    SyncFolder::Error error;
    QVERIFY2(remote->open(&error), qPrintable(error.message));
    const QString first
        = QStringLiteral("devices/0123456789abcdef0123456789abcdef/changes/"
                         "0000-00000001.json");
    const QString second
        = QStringLiteral("devices/0123456789abcdef0123456789abcdef/changes/"
                         "0000-00000002.json");
    const QByteArray firstContent(100, 'a');
    const QByteArray secondContent(150, 'b');
    QVERIFY2(remote->write(first, firstContent, &error),
             qPrintable(error.message));
    QVERIFY(!remote->write(second, secondContent, &error));
    QCOMPARE(error.kind, SyncFolder::ErrorKind::NoSpace);
    QByteArray readBack;
    QVERIFY2(remote->read(first, &readBack, &error),
             qPrintable(error.message));
    QCOMPARE(readBack, firstContent);
}

// 保证假 HTTP 与真实 NSURLSession 的阻塞请求都能被另一线程在 1 秒内取消。
void RemoteSyncFolderTests::cancellationUnblocksFakeAndAppleClients()
{
    const QString space = QStringLiteral("space-1234567890ab08");
    auto blocking = std::make_shared<BlockingHttpClient>();
    RemoteSyncFolder fake(
        {baseUrl(), space, secret('I')},
        blocking, std::make_shared<AppleSyncBlockCipher>());
    SyncFolder::Error fakeError;
    std::atomic<bool> fakeDone{false};
    std::thread fakeThread([&] {
        QByteArray data;
        fake.read(SyncFiles::markerFileName(), &data, &fakeError);
        fakeDone.store(true);
    });
    const auto joinFake = qScopeGuard([&] {
        blocking->cancelAll();
        if (fakeThread.joinable()) {
            fakeThread.join();
        }
    });
    QTRY_VERIFY_WITH_TIMEOUT(blocking->entered.load(), 1000);
    QElapsedTimer fakeTimer;
    fakeTimer.start();
    fake.cancelPendingIo();
    QTRY_VERIFY_WITH_TIMEOUT(fakeDone.load(), 1000);
    QVERIFY(fakeTimer.elapsed() < 1000);
    QCOMPARE(fakeError.kind, SyncFolder::ErrorKind::Io);
    QCOMPARE(fakeError.message, QStringLiteral("同步已取消"));

    QTcpServer silentServer;
    QVERIFY(silentServer.listen(QHostAddress::LocalHost, 0));
    AppleSyncHttpClient appleClient;
    SyncHttpClient::Response appleResponse;
    std::atomic<bool> appleDone{false};
    std::thread appleThread([&] {
        SyncHttpClient::Request request;
        request.method = QByteArrayLiteral("GET");
        request.url = QUrl(
            QStringLiteral("http://127.0.0.1:%1/v1/spaces/%2/tree")
                .arg(silentServer.serverPort())
                .arg(space));
        request.timeoutMs = 30000;
        appleResponse = appleClient.send(request);
        appleDone.store(true);
    });
    const auto joinApple = qScopeGuard([&] {
        appleClient.cancelAll();
        if (appleThread.joinable()) {
            appleThread.join();
        }
    });
    QTRY_VERIFY_WITH_TIMEOUT(silentServer.hasPendingConnections(), 2000);
    QTcpSocket* silentSocket = silentServer.nextPendingConnection();
    QVERIFY(silentSocket != nullptr);
    QElapsedTimer appleTimer;
    appleTimer.start();
    appleClient.cancelAll();
    QTRY_VERIFY_WITH_TIMEOUT(appleDone.load(), 1000);
    QVERIFY(appleTimer.elapsed() < 1000);
    QCOMPARE(appleResponse.failure, SyncHttpClient::Failure::Cancelled);
}

// 保证 Apple HTTP 客户端保留 302 状态而不跟随，远端文件夹把它归类为 Unavailable。
void RemoteSyncFolderTests::appleClientAndFolderDoNotFollowRedirects()
{
    QTcpServer redirectServer;
    QVERIFY(redirectServer.listen(QHostAddress::LocalHost, 0));
    const QByteArray redirectResponse
        = QByteArrayLiteral("HTTP/1.1 302 Found\r\n"
                            "Location: https://example.invalid/other\r\n"
                            "Content-Length: 0\r\n"
                            "Connection: close\r\n\r\n");
    connect(&redirectServer, &QTcpServer::newConnection, this, [&] {
        while (QTcpSocket* socket = redirectServer.nextPendingConnection()) {
            const auto respond = [socket, redirectResponse] {
                if (socket->bytesAvailable() <= 0) {
                    return;
                }
                socket->readAll();
                socket->write(redirectResponse);
                socket->disconnectFromHost();
            };
            connect(socket, &QTcpSocket::readyRead, socket, respond);
            respond();
        }
    });

    AppleSyncHttpClient client;
    SyncHttpClient::Response directResponse;
    std::atomic<bool> directDone{false};
    std::thread directThread([&] {
        SyncHttpClient::Request request;
        request.method = QByteArrayLiteral("GET");
        request.url = QUrl(
            QStringLiteral("http://127.0.0.1:%1/test")
                .arg(redirectServer.serverPort()));
        request.timeoutMs = 5000;
        directResponse = client.send(request);
        directDone.store(true);
    });
    const auto joinDirect = qScopeGuard([&] {
        client.cancelAll();
        if (directThread.joinable()) {
            directThread.join();
        }
    });
    QTRY_VERIFY_WITH_TIMEOUT(directDone.load(), 5000);
    QCOMPARE(directResponse.failure, SyncHttpClient::Failure::None);
    QCOMPARE(directResponse.status, 302);

    const QString space = QStringLiteral("space-1234567890ab09");
    RemoteSyncFolder remote(
        {QUrl(QStringLiteral("http://127.0.0.1:%1")
                  .arg(redirectServer.serverPort())),
         space, secret('J')},
        std::make_shared<AppleSyncHttpClient>(),
        std::make_shared<AppleSyncBlockCipher>());
    SyncFolder::Error openError;
    std::atomic<bool> openDone{false};
    std::thread openThread([&] {
        remote.open(&openError);
        openDone.store(true);
    });
    const auto joinOpen = qScopeGuard([&] {
        remote.cancelPendingIo();
        if (openThread.joinable()) {
            openThread.join();
        }
    });
    QTRY_VERIFY_WITH_TIMEOUT(openDone.load(), 5000);
    QCOMPARE(openError.kind, SyncFolder::ErrorKind::Unavailable);
    QVERIFY(openError.message.contains(QStringLiteral("跳转")));
}

QTEST_GUILESS_MAIN(RemoteSyncFolderTests)
#include "RemoteSyncFolderTests.moc"
