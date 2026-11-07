#include "../src/platform/apple/AppleSyncBlockCipher.h"
#include "../src/platform/apple/AppleSyncHttpClient.h"
#include "../src/services/AppSettings.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/LocalSyncFolder.h"
#include "../src/services/RemoteSyncFolder.h"
#include "../src/services/SyncController.h"
#include "../src/services/SyncCrypto.h"
#include "../src/services/SyncFiles.h"
#include "../src/services/SyncPairing.h"
#include "../src/services/SyncServerWatcher.h"
#include "../src/services/SyncStore.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QProcess>
#include <QRegularExpression>
#include <QScopeGuard>
#include <QSettings>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>

#include <algorithm>
#include <functional>
#include <memory>

namespace {

const QString kSpace = QStringLiteral("space-1234567890ab20");
const QByteArray kSecret(32, 'S');

struct Peer {
    QString path;
    QString connection;
    QString id;
    std::unique_ptr<SyncEngine> engine;
    std::unique_ptr<SyncServerWatcher> watcher;
};

struct MacHarness {
    QString iCloudRoot;
    int retireCalls = 0;
    bool retireFails = false;
};

struct IosHarness {
    QByteArray pickedBookmark;
    QString pickedPath;
    int pickerShown = 0;
};

SyncEngine::Options testOptions()
{
    SyncEngine::Options options;
    options.tickMs = 60 * 60 * 1000;
    options.publishIntervalMs = 0;
    options.scanIntervalMs = 0;
    options.retryMinMs = 20;
    options.retryMaxMs = 100;
    return options;
}

void configurePreferences(const QString& directory)
{
    QCoreApplication::setOrganizationName(
        QStringLiteral("PomodoroTodoSyncControllerServerTests"));
    QCoreApplication::setApplicationName(
        QStringLiteral("SyncControllerServerTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, directory);
}

QVariant scalar(const QString& connection, const QString& sql)
{
    QSqlQuery query(QSqlDatabase::database(connection));
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return {};
    }
    return query.next() ? query.value(0) : QVariant();
}

QStringList taskTitles(const QString& connection)
{
    QStringList titles;
    QSqlQuery query(QSqlDatabase::database(connection));
    query.exec(QStringLiteral("SELECT title FROM tasks ORDER BY title, id"));
    while (query.next()) {
        titles.append(query.value(0).toString());
    }
    return titles;
}

QString addTask(const QString& connection, const QString& title)
{
    QSqlQuery query(QSqlDatabase::database(connection));
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES "
        "(:title, '2026-09-30', 0, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks "
        "WHERE date = '2026-09-30'))"));
    query.bindValue(QStringLiteral(":title"), title);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(connection,
                  QStringLiteral("SELECT sync_id FROM tasks WHERE id = %1")
                      .arg(query.lastInsertId().toLongLong()))
        .toString();
}

bool waitIdle(SyncEngine& engine, int timeoutMs = 15000)
{
    QElapsedTimer timer;
    timer.start();
    while (!engine.isIdle()) {
        if (timer.elapsed() > timeoutMs) {
            return false;
        }
        QTest::qWait(1);
    }
    return true;
}

bool waitUntil(const std::function<bool()>& predicate,
               int timeoutMs = 10000)
{
    QElapsedTimer timer;
    timer.start();
    while (!predicate()) {
        if (timer.elapsed() > timeoutMs) {
            return false;
        }
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QTest::qWait(5);
    }
    return true;
}

bool retireFake(const QString& root, QString* error)
{
    const QString source
        = root + QLatin1Char('/') + SyncFiles::defaultFolderName();
    if (!QFileInfo::exists(source)) {
        return true;
    }
    const QStringList entries = QDir(source).entryList(
        QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden);
    if (SyncFiles::isEffectivelyEmpty(entries)) {
        return true;
    }
    const QString base
        = source + QStringLiteral("-旧-20261107-102030Z");
    QString target = base;
    for (int suffix = 2; QFileInfo::exists(target); ++suffix) {
        target = base + QStringLiteral("-%1").arg(suffix);
    }
    if (!QDir().rename(source, target)) {
        if (error) {
            *error = QStringLiteral("测试目录改名失败");
        }
        return false;
    }
    QFile::remove(target + QLatin1Char('/') + SyncFiles::markerFileName());
    return true;
}

} // namespace

class SyncControllerServerTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void cleanup();

    void defaultsToICloudAndKeepsOriginalOptions();
    void macCreatesServerSpaceWithPairingAndRetiresICloud();
    void macSynchronizesICloudBeforeCreatingSpace();
    void ipadJoinsByPairingCodeAfterValidation();
    void watcherDrivesControllerWithoutScanTimer();
    void ipadStopsWatcherInBackgroundAndResumesOnForeground();
    void switchToICloudMacCreatesFreshFolderWhileServerDown();
    void switchToICloudIpadRequiresFolderPicker();
    void settingsFailureKeepsTransportAndReportsError();
    void restoreStopsAndRestartsServerWatcher();

private:
    void openMainDatabase(const QString& name);
    Peer openPeer(const QString& name, bool mayCreateFolder,
                  const QString& localRoot = QString());
    std::unique_ptr<SyncEngine> remotePeerEngine(
        Peer* peer, const QString& space, const QByteArray& secret,
        bool mayCreateFolder, const QString& initialTask = QString());
    SyncController::Platform macPlatform(std::shared_ptr<MacHarness> harness);
    SyncController::Platform ipadPlatform(std::shared_ptr<IosHarness> harness);
    bool startServer(quint16 port);
    void stopServer();
    bool createEmptyServerSpace(const QString& space,
                                const QByteArray& secret, QString* error);
    QUrl baseUrl() const;
    QSet<QString> serverPaths(const QString& space,
                              const QByteArray& secret);
    bool pairRemoteEngine(Peer* peer, const QString& space,
                          const QByteArray& secret, bool mayCreateFolder,
                          const QString& initialTask = QString());
    bool joinIpadControllerToPeer(SyncController* controller, Peer* mac,
                                  const QString& space,
                                  const QByteArray& secret);
    void startPeerWatcher(Peer* peer, const QString& space,
                          const QByteArray& secret);

    std::unique_ptr<QTemporaryDir> preferences;
    std::unique_ptr<QTemporaryDir> data;
    QStringList connections;
    QProcess* server = nullptr;
    QString serverOutput;
    QString serverErrorOutput;
    QString enrollFile;
    QString enrollSecret;
    quint16 serverPort = 0;
};

void SyncControllerServerTests::initTestCase()
{
    preferences = std::make_unique<QTemporaryDir>();
    QVERIFY(preferences->isValid());
    configurePreferences(preferences->path());
}

void SyncControllerServerTests::cleanupTestCase()
{
    preferences.reset();
}

void SyncControllerServerTests::init()
{
    data = std::make_unique<QTemporaryDir>();
    QVERIFY(data->isValid());
    QSettings settings;
    settings.clear();
    settings.sync();
    AppSettings::instance()->reload();
    enrollSecret = QStringLiteral("enroll-secret-for-controller-server-tests");
    enrollFile = data->filePath(QStringLiteral("enroll.sha256"));
    QFile file(enrollFile);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    const QByteArray digest = QCryptographicHash::hash(
        enrollSecret.toUtf8(), QCryptographicHash::Sha256).toHex();
    QCOMPARE(file.write(digest), digest.size());
    file.close();
    SyncPairing::Info wrappedInfo;
    QString wrappedError;
    const QString wrappedCode
        = SyncPairing::encode({QUrl(QStringLiteral("https://example.com")),
                               kSpace, kSecret});
    const QString brokenAcrossLines
        = wrappedCode.left(12) + QLatin1Char('\n') + wrappedCode.mid(12);
    QVERIFY2(SyncPairing::decode(
                 brokenAcrossLines, &wrappedInfo, &wrappedError),
             qPrintable(wrappedError));
    QVERIFY(startServer(0));
}

void SyncControllerServerTests::cleanup()
{
    stopServer();
    DatabaseManager::instance()->close();
    for (const QString& connection : std::as_const(connections)) {
        {
            QSqlDatabase database
                = QSqlDatabase::database(connection, false);
            database.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }
    connections.clear();
    data.reset();
}

void SyncControllerServerTests::openMainDatabase(const QString& name)
{
    DatabaseManager::instance()->close();
    QVERIFY(DatabaseManager::instance()->initialize(
        data->filePath(name + QStringLiteral(".sqlite"))));
}

Peer SyncControllerServerTests::openPeer(
    const QString& name, bool mayCreateFolder, const QString& localRoot)
{
    Peer peer;
    const QString mainPath
        = DatabaseManager::instance()->database().databaseName();
    peer.path = data->filePath(name + QStringLiteral(".sqlite"));
    DatabaseManager::instance()->close();
    if (!DatabaseManager::instance()->initialize(peer.path)) {
        qWarning() << "peer initialize failed";
    }
    DatabaseManager::instance()->close();
    DatabaseManager::instance()->initialize(mainPath);

    peer.connection = QStringLiteral("controller-server-peer-") + name;
    QSqlDatabase database
        = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),
                                    peer.connection);
    database.setDatabaseName(peer.path);
    database.open();
    QSqlQuery(database).exec(QStringLiteral("PRAGMA foreign_keys = ON"));
    QSqlQuery(database).exec(QStringLiteral("PRAGMA busy_timeout = 5000"));
    connections.append(peer.connection);
    peer.id = SyncStore(peer.connection).deviceId();

    if (!localRoot.isEmpty()) {
        SyncEngine::Options options = testOptions();
        options.mayCreateFolder = mayCreateFolder;
        peer.engine = std::make_unique<SyncEngine>(
            std::make_unique<LocalSyncFolder>(localRoot), options,
            peer.connection);
        peer.engine->setChangeNotifier(
            [](const SyncStore::ApplyResult&) {});
    }
    return peer;
}

std::unique_ptr<SyncEngine> SyncControllerServerTests::remotePeerEngine(
    Peer* peer, const QString& space, const QByteArray& secret,
    bool mayCreateFolder, const QString& initialTask)
{
    SyncEngine::Options options = testOptions();
    options.mayCreateFolder = mayCreateFolder;
    auto engine = std::make_unique<SyncEngine>(
        std::make_unique<RemoteSyncFolder>(
            RemoteSyncFolder::Config{baseUrl(), space, secret},
            std::make_shared<AppleSyncHttpClient>(),
            std::make_shared<AppleSyncBlockCipher>()),
        options, peer->connection);
    engine->setChangeNotifier([](const SyncStore::ApplyResult&) {});
    if (!initialTask.isEmpty()) {
        addTask(peer->connection, initialTask);
    }
    return engine;
}

SyncController::Platform SyncControllerServerTests::macPlatform(
    std::shared_ptr<MacHarness> harness)
{
    SyncController::Platform platform;
    platform.makeFolder = [harness](const QByteArray&,
                                    std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(std::make_unique<LocalSyncFolder>(
            harness->iCloudRoot + QLatin1Char('/')
            + SyncFiles::defaultFolderName()));
    };
    platform.makeHttpClient = [] {
        return std::make_shared<AppleSyncHttpClient>();
    };
    platform.makeBlockCipher = [] {
        return std::make_shared<AppleSyncBlockCipher>();
    };
    platform.retireICloudFolder = [harness](QString* error) {
        ++harness->retireCalls;
        if (harness->retireFails) {
            *error = QStringLiteral("测试拒绝退役");
            return false;
        }
        return retireFake(harness->iCloudRoot, error);
    };
    platform.fixedFolderDisplayPath
        = QStringLiteral("iCloud 云盘/番茄todo");
    platform.engine = testOptions();
    platform.engine.mayCreateFolder = true;
    platform.engine.runInBackground = true;
    return platform;
}

SyncController::Platform SyncControllerServerTests::ipadPlatform(
    std::shared_ptr<IosHarness> harness)
{
    SyncController::Platform platform;
    platform.makeFolder = [](const QByteArray& bookmark,
                             std::function<void(const QByteArray&)>) {
        return std::unique_ptr<SyncFolder>(
            std::make_unique<LocalSyncFolder>(
                QString::fromUtf8(bookmark)));
    };
    platform.pickFolder = [harness](
                              std::function<void(const QByteArray&,
                                                 const QString&)> done) {
        ++harness->pickerShown;
        QTimer::singleShot(0, [done, harness] {
            done(harness->pickedBookmark, harness->pickedPath);
        });
    };
    platform.makeHttpClient = [] {
        return std::make_shared<AppleSyncHttpClient>();
    };
    platform.makeBlockCipher = [] {
        return std::make_shared<AppleSyncBlockCipher>();
    };
    platform.engine = testOptions();
    platform.engine.mayCreateFolder = false;
    platform.engine.runInBackground = false;
    return platform;
}

bool SyncControllerServerTests::startServer(quint16 port)
{
    stopServer();
    serverOutput.clear();
    serverErrorOutput.clear();
    server = new QProcess(this);
    server->setProcessChannelMode(QProcess::SeparateChannels);
    connect(server, &QProcess::readyReadStandardOutput, this, [this] {
        serverOutput += QString::fromUtf8(server->readAllStandardOutput());
    });
    connect(server, &QProcess::readyReadStandardError, this, [this] {
        serverErrorOutput += QString::fromUtf8(server->readAllStandardError());
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
            QString::number(port),
            QStringLiteral("--state-dir"),
            data->filePath(QStringLiteral("server-state")),
            QStringLiteral("--enroll-hash-file"),
            enrollFile,
        });
    if (!server->waitForStarted(5000)) {
        return false;
    }
    QElapsedTimer timer;
    timer.start();
    static const QRegularExpression pattern(
        QStringLiteral("PT_SYNC_READY (\\d+)"));
    while (timer.elapsed() < 5000) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        const QRegularExpressionMatch match = pattern.match(serverOutput);
        if (match.hasMatch()) {
            serverPort = static_cast<quint16>(match.captured(1).toUInt());
            return port == 0 || serverPort == port;
        }
        QTest::qWait(10);
    }
    return false;
}

void SyncControllerServerTests::stopServer()
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

QUrl SyncControllerServerTests::baseUrl() const
{
    return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(serverPort));
}

bool SyncControllerServerTests::createEmptyServerSpace(
    const QString& space, const QByteArray& secret, QString* error)
{
    const QString token
        = SyncCrypto::authTokenText(
              SyncCrypto::deriveKeys(secret, space))
              .toUtf8();
    const QJsonObject body{
        {QStringLiteral("space"), space},
        {QStringLiteral("tokenSha256"),
         QString::fromLatin1(
             QCryptographicHash::hash(
                 token.toUtf8(), QCryptographicHash::Sha256)
                 .toHex())},
    };
    AppleSyncHttpClient client;
    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("POST");
    request.url = QUrl(baseUrl().toString() + QStringLiteral("/v1/spaces"));
    request.timeoutMs = 5000;
    request.headers = {
        {QByteArrayLiteral("Content-Type"),
         QByteArrayLiteral("application/json")},
        {QByteArrayLiteral("X-PT-Enroll"), enrollSecret.toUtf8()},
    };
    request.body = QJsonDocument(body).toJson(QJsonDocument::Compact);
    const SyncHttpClient::Response response = client.send(request);
    if (response.failure != SyncHttpClient::Failure::None
        || response.status != 201) {
        if (error) {
            *error = response.failure != SyncHttpClient::Failure::None
                ? response.message
                : QStringLiteral("HTTP %1").arg(response.status);
        }
        return false;
    }
    return true;
}

QSet<QString> SyncControllerServerTests::serverPaths(
    const QString& space, const QByteArray& secret)
{
    AppleSyncHttpClient client;
    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("GET");
    request.url = QUrl(baseUrl().toString()
                       + QStringLiteral("/v1/spaces/%1/tree").arg(space));
    request.timeoutMs = 5000;
    request.headers = {
        {QByteArrayLiteral("Authorization"),
         QByteArrayLiteral("Bearer ")
             + SyncCrypto::authTokenText(
                   SyncCrypto::deriveKeys(secret, space))
                   .toUtf8()},
        {QByteArrayLiteral("User-Agent"),
         QByteArrayLiteral("PomodoroTodo-sync/1")},
    };
    const SyncHttpClient::Response response = client.send(request);
    if (response.status != 200) {
        return {};
    }
    QSet<QString> paths;
    const QJsonArray entries
        = QJsonDocument::fromJson(response.body)
              .object()
              .value(QStringLiteral("entries"))
              .toArray();
    for (const QJsonValue& value : entries) {
        paths.insert(value.toObject().value(QStringLiteral("path")).toString());
    }
    return paths;
}

bool SyncControllerServerTests::pairRemoteEngine(
    Peer* peer, const QString& space, const QByteArray& secret,
    bool mayCreateFolder, const QString& initialTask)
{
    peer->engine = remotePeerEngine(
        peer, space, secret, mayCreateFolder, initialTask);
    peer->engine->start();
    if (!waitIdle(*peer->engine)) {
        return false;
    }
    if (!mayCreateFolder
        && peer->engine->status() == SyncEngine::Status::NeedsConfirmation) {
        peer->engine->confirmJoin();
        if (!waitIdle(*peer->engine)) {
            return false;
        }
    }
    return peer->engine->status() == SyncEngine::Status::UpToDate;
}

bool SyncControllerServerTests::joinIpadControllerToPeer(
    SyncController* controller, Peer* mac, const QString& space,
    const QByteArray& secret)
{
    QString error;
    if (!createEmptyServerSpace(space, secret, &error)) {
        qWarning() << error;
        return false;
    }
    mac->engine = remotePeerEngine(
        mac, space, secret, true, QStringLiteral("Mac 已有任务"));
    mac->engine->start();
    if (!waitIdle(*mac->engine)) {
        return false;
    }
    const QString code = SyncPairing::encode({baseUrl(), space, secret});
    controller->joinWithPairingCode(code);
    if (!waitUntil([controller] {
            return !controller->isSwitchingTransport();
        }, 10000)
        || controller->transport() != QStringLiteral("server")
        || !waitUntil([controller] {
               return controller->statusKey()
                   == QStringLiteral("needsConfirmation");
           }, 5000)) {
        return false;
    }
    controller->confirmJoin();
    return waitIdle(*controller->engine())
        && waitUntil([controller] {
               return controller->statusKey()
                   == QStringLiteral("upToDate");
           }, 10000);
}

void SyncControllerServerTests::startPeerWatcher(
    Peer* peer, const QString& space, const QByteArray& secret)
{
    peer->watcher = std::make_unique<SyncServerWatcher>(
        SyncServerWatcher::Config{
            baseUrl(),
            space,
            SyncCrypto::authTokenText(
                SyncCrypto::deriveKeys(secret, space)),
            2,
            100,
            500,
        },
        std::make_shared<AppleSyncHttpClient>());
    connect(peer->watcher.get(), &SyncServerWatcher::changed,
            peer->engine.get(), &SyncEngine::syncNow,
            Qt::QueuedConnection);
    peer->watcher->start();
}

// 保证老用户没有 sync/transport 时仍按 iCloud 方式启动，服务器专用节拍不污染原选项。
void SyncControllerServerTests::defaultsToICloudAndKeepsOriginalOptions()
{
    openMainDatabase(QStringLiteral("main"));
    auto harness = std::make_shared<MacHarness>();
    harness->iCloudRoot = data->filePath(QStringLiteral("icloud"));
    QVERIFY(QDir().mkpath(harness->iCloudRoot));
    SyncController controller(macPlatform(harness));
    controller.initialize();
    QCOMPARE(controller.transport(), QStringLiteral("icloud"));
    QVERIFY(controller.serverHost().isEmpty());
    QVERIFY(controller.pairingCode().isEmpty());
    QVERIFY(controller.canCreateServerSpace());
    controller.setEnabled(true);
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 5000);
    const SyncEngine::Options server = SyncController::serverEngineOptions(
        macPlatform(harness).engine);
    QCOMPARE(server.publishIntervalMs, 2000);
    QCOMPARE(server.scanIntervalMs, 60000);
    QCOMPARE(server.retryMinMs, 5000);
    QCOMPARE(server.retryMaxMs, 60000);
    QCOMPARE(server.stallTimeoutMs, 60000);
    QVERIFY(!AppSettings::ownedSettingGroups().contains(QStringLiteral("sync")));
}

// 保证错误口令不改状态，正确口令写入服务器配置、生成可解码配对码并退役旧 iCloud 目录。
void SyncControllerServerTests::macCreatesServerSpaceWithPairingAndRetiresICloud()
{
    openMainDatabase(QStringLiteral("main"));
    auto harness = std::make_shared<MacHarness>();
    harness->iCloudRoot = data->filePath(QStringLiteral("icloud"));
    QVERIFY(QDir().mkpath(harness->iCloudRoot));
    SyncController controller(macPlatform(harness));
    controller.initialize();
    controller.setEnabled(true);
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 5000);
    SyncEngine* const oldEngine = controller.engine();
    QVERIFY(oldEngine != nullptr);

    controller.createServerSpace(
        baseUrl().toString(), QStringLiteral("wrong-enroll"));
    QTRY_VERIFY_WITH_TIMEOUT(!controller.isSwitchingTransport(), 5000);
    QVERIFY(controller.transportProblem().contains(QStringLiteral("注册口令不对")));
    QCOMPARE(controller.transport(), QStringLiteral("icloud"));
    QCOMPARE(controller.engine(), oldEngine);
    QVERIFY(!QSettings().contains(QStringLiteral("sync/server/url")));

    QSignalSpy transportSpy(&controller, &SyncController::transportChanged);
    controller.createServerSpace(baseUrl().toString(), enrollSecret);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.transport() == QStringLiteral("server")
        && !controller.isSwitchingTransport(), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 10000);
    QVERIFY(controller.serverHost() == QStringLiteral("127.0.0.1"));
    QCOMPARE(controller.folderDisplayPath(), QStringLiteral("127.0.0.1"));
    QVERIFY(controller.hasFolder());
    QCOMPARE(transportSpy.count(), 1);
    QCOMPARE(harness->retireCalls, 1);

    QSettings settings;
    QCOMPARE(settings.value(QStringLiteral("sync/transport")).toString(),
             QStringLiteral("server"));
    QVERIFY(!settings.value(QStringLiteral("sync/server/url")).toString().isEmpty());
    QVERIFY(!settings.value(QStringLiteral("sync/server/space")).toString().isEmpty());
    QVERIFY(!settings.value(QStringLiteral("sync/server/secret")).toString().isEmpty());

    SyncPairing::Info decoded;
    QString pairingError;
    QVERIFY2(SyncPairing::decode(controller.pairingCode(), &decoded, &pairingError),
             qPrintable(pairingError));
    QCOMPARE(decoded.baseUrl, baseUrl());
    const QString space = decoded.spaceId;
    QVERIFY(!space.isEmpty());
    const QSet<QString> paths = serverPaths(space, decoded.secret);
    QVERIFY(paths.contains(SyncFiles::markerFileName()));
    QVERIFY(std::any_of(paths.cbegin(), paths.cend(),
                        [](const QString& path) {
                            return path.contains(QStringLiteral("/snapshot-"));
                        }));
    QSignalSpy copySpy(&controller, &SyncController::copyRequested);
    controller.copyPairingCode();
    QCOMPARE(copySpy.count(), 1);
    QCOMPARE(copySpy.first().first().toString(), controller.pairingCode());
}

// 保证 Mac 切服务器前先同步一轮 iCloud，把另一台刚写出的改动带进服务器快照。
void SyncControllerServerTests::macSynchronizesICloudBeforeCreatingSpace()
{
    openMainDatabase(QStringLiteral("main"));
    auto macHarness = std::make_shared<MacHarness>();
    macHarness->iCloudRoot = data->filePath(QStringLiteral("icloud"));
    QVERIFY(QDir().mkpath(macHarness->iCloudRoot));
    SyncController mac(macPlatform(macHarness));
    mac.initialize();
    mac.setEnabled(true);
    QTRY_VERIFY_WITH_TIMEOUT(mac.statusKey() == QStringLiteral("upToDate"), 5000);

    Peer ipad = openPeer(QStringLiteral("ipad"), false,
                         macHarness->iCloudRoot + QLatin1Char('/')
                             + SyncFiles::defaultFolderName());
    ipad.engine->setSafetyBackup([](QString*) { return true; });
    ipad.engine->start();
    QVERIFY(waitIdle(*ipad.engine));
    if (ipad.engine->status() == SyncEngine::Status::NeedsConfirmation) {
        ipad.engine->confirmJoin();
        QVERIFY(waitIdle(*ipad.engine));
    }
    QCOMPARE(ipad.engine->status(), SyncEngine::Status::UpToDate);
    QVERIFY(!addTask(ipad.connection, QStringLiteral("iPad 先写出的任务")).isEmpty());
    ipad.engine->syncNow();
    QVERIFY(waitIdle(*ipad.engine));
    ipad.engine->stop();
    QVERIFY(!taskTitles(
                 DatabaseManager::instance()->database().connectionName())
                 .contains(QStringLiteral("iPad 先写出的任务")));

    mac.createServerSpace(baseUrl().toString(), enrollSecret);
    QTRY_VERIFY_WITH_TIMEOUT(
        mac.transport() == QStringLiteral("server")
        && !mac.isSwitchingTransport(), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(mac.statusKey() == QStringLiteral("upToDate"), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(
        taskTitles(DatabaseManager::instance()->database().connectionName())
            .contains(QStringLiteral("iPad 先写出的任务")), 5000);

    SyncPairing::Info info;
    QString error;
    QVERIFY(SyncPairing::decode(mac.pairingCode(), &info, &error));
    Peer ipadServer = openPeer(QStringLiteral("ipad-server"), false);
    QVERIFY(pairRemoteEngine(&ipadServer, info.spaceId, info.secret, false));
    QVERIFY(taskTitles(ipadServer.connection).contains(
        QStringLiteral("iPad 先写出的任务")));
}

// 保证配对码错误不改状态、空空间提示“还没建好”，正确加入清书签并要求确认和显示待发送警告。
void SyncControllerServerTests::ipadJoinsByPairingCodeAfterValidation()
{
    openMainDatabase(QStringLiteral("ipad"));
    QVERIFY(!addTask(
                 DatabaseManager::instance()->database().connectionName(),
                 QStringLiteral("iPad 未发任务")).isEmpty());
    QSettings settings;
    settings.setValue(QStringLiteral("sync/bookmark"), QByteArrayLiteral("old"));
    settings.setValue(QStringLiteral("sync/folderPath"), QStringLiteral("old"));
    settings.sync();
    auto harness = std::make_shared<IosHarness>();
    SyncController controller(ipadPlatform(harness));
    controller.initialize();

    const QUrl validUrl = baseUrl();
    const SyncPairing::Info validInfo{
        validUrl, kSpace, kSecret};
    const QString valid = SyncPairing::encode(validInfo);
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{32}$"))
                .match(SyncPairing::newSpaceId())
                .hasMatch());
    QCOMPARE(SyncPairing::newSecret().size(), 32);
    const QList<QPair<QString, QString>> invalid = {
        {QStringLiteral("bad"), QStringLiteral("这不是番茄Todo 的配对码")},
        {valid.left(12), QStringLiteral("配对码不完整或已损坏")},
        {SyncPairing::encode(
             {QUrl(QStringLiteral("http://example.com")), kSpace, kSecret}),
         QStringLiteral("服务器地址不安全")},
        {SyncPairing::encode(
             {validUrl, kSpace, QByteArray(31, 'x')}),
         QStringLiteral("配对码不完整或已损坏")},
    };
    for (const auto& item : invalid) {
        controller.joinWithPairingCode(item.first);
        QVERIFY(controller.transportProblem().contains(item.second));
        QCOMPARE(controller.transport(), QStringLiteral("icloud"));
    }

    QString error;
    QVERIFY2(createEmptyServerSpace(kSpace, kSecret, &error),
             qPrintable(error));
    controller.joinWithPairingCode(valid);
    QTRY_VERIFY_WITH_TIMEOUT(!controller.isSwitchingTransport(), 5000);
    QVERIFY(controller.transportProblem().contains(
        QStringLiteral("还没在这个同步空间里建好")));

    Peer mac = openPeer(QStringLiteral("mac"), true);
    QVERIFY(pairRemoteEngine(
        &mac, kSpace, kSecret, true, QStringLiteral("Mac 快照任务")));
    controller.joinWithPairingCode(valid);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.transport() == QStringLiteral("server")
        && !controller.isSwitchingTransport(), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.statusKey() == QStringLiteral("needsConfirmation"), 5000);
    QSettings current;
    QVERIFY(current.value(QStringLiteral("sync/bookmark")).toByteArray().isEmpty());
    QVERIFY(current.value(QStringLiteral("sync/folderPath")).toString().isEmpty());
    QVERIFY(controller.pendingCount() > 0);
    QCOMPARE(controller.joinWarning(),
             QStringLiteral("本机还有 %1 条改动没发出，加入后只留在自动备份里。")
                 .arg(controller.pendingCount()));
    controller.confirmJoin();
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 10000);
    QCOMPARE(
        taskTitles(DatabaseManager::instance()->database().connectionName()),
        taskTitles(mac.connection));
}

// 保证扫描与 tick 定时器都不在 5 秒窗口内时，服务器 watcher 仍能驱动 iPad 控制器同步。
void SyncControllerServerTests::watcherDrivesControllerWithoutScanTimer()
{
    openMainDatabase(QStringLiteral("ipad"));
    auto harness = std::make_shared<IosHarness>();
    SyncController controller(ipadPlatform(harness));
    controller.initialize();
    Peer mac = openPeer(QStringLiteral("mac"), true);
    QVERIFY(joinIpadControllerToPeer(&controller, &mac, kSpace, kSecret));
    startPeerWatcher(&mac, kSpace, kSecret);

    QVERIFY(!addTask(mac.connection, QStringLiteral("实时任务")).isEmpty());
    mac.engine->syncNow();
    QVERIFY(waitIdle(*mac.engine));
    QStringList titles;
    QTRY_VERIFY_WITH_TIMEOUT(
        (titles = taskTitles(
             DatabaseManager::instance()->database().connectionName()))
            .contains(QStringLiteral("实时任务")),
        5000);
    QVERIFY(waitIdle(*controller.engine()));
    QCOMPARE(controller.statusKey(), QStringLiteral("upToDate"));
}

// 保证 iPad 进后台后 watcher 不再收到服务器变化，回前台立即补同步。
void SyncControllerServerTests::ipadStopsWatcherInBackgroundAndResumesOnForeground()
{
    openMainDatabase(QStringLiteral("ipad"));
    auto harness = std::make_shared<IosHarness>();
    SyncController controller(ipadPlatform(harness));
    controller.initialize();
    Peer mac = openPeer(QStringLiteral("mac"), true);
    QVERIFY(joinIpadControllerToPeer(&controller, &mac, kSpace, kSecret));
    startPeerWatcher(&mac, kSpace, kSecret);

    controller.setApplicationState(Qt::ApplicationSuspended);
    QVERIFY(!addTask(mac.connection, QStringLiteral("后台期间写入")).isEmpty());
    mac.engine->syncNow();
    QVERIFY(waitIdle(*mac.engine));
    bool seenInBackground = false;
    QElapsedTimer backgroundWindow;
    backgroundWindow.start();
    // 轮询观察两秒；不是先固定等待再只看一次，期间一旦出现就立即判失败。
    while (backgroundWindow.elapsed() < 2000) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        if (taskTitles(DatabaseManager::instance()->database().connectionName())
                .contains(QStringLiteral("后台期间写入"))) {
            seenInBackground = true;
            break;
        }
        QTest::qWait(10);
    }
    QVERIFY2(!seenInBackground, "iPad 后台时 watcher 仍在同步");
    controller.setApplicationState(Qt::ApplicationActive);
    QTRY_VERIFY_WITH_TIMEOUT(
        taskTitles(DatabaseManager::instance()->database().connectionName())
            .contains(QStringLiteral("后台期间写入")),
        5000);
    QVERIFY(waitIdle(*controller.engine()));
}

// 保证服务器停掉时 Mac 仍能切回 iCloud，并建出一个带新标记文件的目录。
void SyncControllerServerTests::switchToICloudMacCreatesFreshFolderWhileServerDown()
{
    openMainDatabase(QStringLiteral("mac"));
    auto harness = std::make_shared<MacHarness>();
    harness->iCloudRoot = data->filePath(QStringLiteral("icloud"));
    QVERIFY(QDir().mkpath(harness->iCloudRoot));
    SyncController controller(macPlatform(harness));
    controller.initialize();
    controller.createServerSpace(baseUrl().toString(), enrollSecret);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.transport() == QStringLiteral("server")
        && !controller.isSwitchingTransport(), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 10000);

    { QSettings settings;
      QCOMPARE(settings.value(QStringLiteral("sync/transport")).toString(),
               QStringLiteral("server")); }
    stopServer();
    controller.switchToICloud();
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.transport() == QStringLiteral("icloud")
        && !controller.isSwitchingTransport(), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 10000);
    QVERIFY(QFileInfo::exists(
        harness->iCloudRoot + QLatin1Char('/')
        + SyncFiles::defaultFolderName() + QLatin1Char('/')
        + SyncFiles::markerFileName()));
    QSettings settings;
    QCOMPARE(settings.value(QStringLiteral("sync/transport")).toString(),
             QStringLiteral("icloud"));
    QVERIFY(!settings.contains(QStringLiteral("sync/server/url")));
    QVERIFY(!settings.contains(QStringLiteral("sync/server/space")));
    QVERIFY(!settings.contains(QStringLiteral("sync/server/secret")));
}

// 保证 iPad 切回 iCloud 不沿用服务器书签，而是重新触发选择器并确认加入新文件夹。
void SyncControllerServerTests::switchToICloudIpadRequiresFolderPicker()
{
    openMainDatabase(QStringLiteral("ipad"));
    auto harness = std::make_shared<IosHarness>();
    SyncController controller(ipadPlatform(harness));
    controller.initialize();

    Peer macServer = openPeer(QStringLiteral("mac-server"), true);
    QVERIFY(joinIpadControllerToPeer(
        &controller, &macServer, kSpace, kSecret));

    const QString iCloudRoot = data->filePath(QStringLiteral("icloud"));
    QVERIFY(QDir().mkpath(iCloudRoot));
    Peer macIcloud = openPeer(
        QStringLiteral("mac-icloud"), true,
        iCloudRoot + QLatin1Char('/') + SyncFiles::defaultFolderName());
    QVERIFY(!addTask(macIcloud.connection,
                     QStringLiteral("Mac iCloud 任务")).isEmpty());
    macIcloud.engine->start();
    QVERIFY(waitIdle(*macIcloud.engine));
    const QString selectedFolder
        = iCloudRoot + QLatin1Char('/') + SyncFiles::defaultFolderName();
    harness->pickedBookmark = selectedFolder.toUtf8();
    harness->pickedPath = selectedFolder;

    controller.switchToICloud();
    QTRY_VERIFY_WITH_TIMEOUT(harness->pickerShown > 0, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.transport() == QStringLiteral("icloud")
        && !controller.isSwitchingTransport(), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.statusKey() == QStringLiteral("needsConfirmation"), 5000);
    QCOMPARE(QSettings().value(QStringLiteral("sync/bookmark")).toByteArray(),
             selectedFolder.toUtf8());
    controller.confirmJoin();
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 10000);
    QVERIFY(!taskTitles(
                 DatabaseManager::instance()->database().connectionName())
                 .isEmpty());
}

// 保证服务器建空间成功但 QSettings 写失败时仍留在 iCloud，并以 error 状态暴露存储故障。
void SyncControllerServerTests::settingsFailureKeepsTransportAndReportsError()
{
    openMainDatabase(QStringLiteral("mac"));
    auto harness = std::make_shared<MacHarness>();
    harness->iCloudRoot = data->filePath(QStringLiteral("icloud"));
    QVERIFY(QDir().mkpath(harness->iCloudRoot));
    SyncController controller(macPlatform(harness));
    controller.initialize();
    const QString ini = QSettings().fileName();
    QVERIFY(QFile::remove(ini));
    QVERIFY(QDir().mkpath(ini));
    const auto restorePreferencesFile = qScopeGuard([&] {
        QDir(ini).removeRecursively();
    });

    controller.createServerSpace(baseUrl().toString(), enrollSecret);
    QTRY_VERIFY_WITH_TIMEOUT(!controller.isSwitchingTransport(), 10000);
    QCOMPARE(controller.transport(), QStringLiteral("icloud"));
    QCOMPARE(controller.statusKey(), QStringLiteral("error"));
    QVERIFY(!controller.transportProblem().isEmpty());
}

// 保证恢复备份开始停掉服务器 watcher，恢复失败安全回滚后重新启动并继续收到后续改动。
void SyncControllerServerTests::restoreStopsAndRestartsServerWatcher()
{
    openMainDatabase(QStringLiteral("mac"));
    auto harness = std::make_shared<MacHarness>();
    harness->iCloudRoot = data->filePath(QStringLiteral("icloud"));
    QVERIFY(QDir().mkpath(harness->iCloudRoot));
    SyncController controller(macPlatform(harness));
    controller.initialize();
    controller.createServerSpace(baseUrl().toString(), enrollSecret);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.transport() == QStringLiteral("server")
        && !controller.isSwitchingTransport(), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(controller.statusKey() == QStringLiteral("upToDate"), 10000);
    SyncPairing::Info info;
    QString error;
    QVERIFY(SyncPairing::decode(controller.pairingCode(), &info, &error));
    Peer peer = openPeer(QStringLiteral("peer"), false);
    QVERIFY(pairRemoteEngine(
        &peer, info.spaceId, info.secret, false));
    const QVariant transportBefore
        = QSettings().value(QStringLiteral("sync/transport"));
    const QVariant urlBefore
        = QSettings().value(QStringLiteral("sync/server/url"));
    const QVariant spaceBefore
        = QSettings().value(QStringLiteral("sync/server/space"));
    const QVariant secretBefore
        = QSettings().value(QStringLiteral("sync/server/secret"));

    QString restoreError;
    QVERIFY2(controller.prepareForRestore(&restoreError),
             qPrintable(restoreError));
    controller.finishRestore(false, true);
    QTRY_VERIFY_WITH_TIMEOUT(
        controller.statusKey() == QStringLiteral("upToDate"), 10000);
    QCOMPARE(QSettings().value(QStringLiteral("sync/transport")),
             transportBefore);
    QCOMPARE(QSettings().value(QStringLiteral("sync/server/url")), urlBefore);
    QCOMPARE(QSettings().value(QStringLiteral("sync/server/space")), spaceBefore);
    QCOMPARE(QSettings().value(QStringLiteral("sync/server/secret")), secretBefore);

    QVERIFY(!addTask(peer.connection,
                     QStringLiteral("恢复后写入")).isEmpty());
    peer.engine->syncNow();
    QVERIFY(waitIdle(*peer.engine));
    QTRY_VERIFY_WITH_TIMEOUT(
        taskTitles(DatabaseManager::instance()->database().connectionName())
            .contains(QStringLiteral("恢复后写入")),
        5000);
}

QTEST_GUILESS_MAIN(SyncControllerServerTests)
#include "SyncControllerServerTests.moc"
