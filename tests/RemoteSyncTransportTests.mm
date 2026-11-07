#include "../src/platform/apple/AppleSyncBlockCipher.h"
#include "../src/platform/apple/AppleSyncHttpClient.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/LocalSyncFolder.h"
#include "../src/services/RemoteSyncFolder.h"
#include "../src/services/SyncCrypto.h"
#include "../src/services/SyncEngine.h"
#include "../src/services/SyncFiles.h"
#include "../src/services/SyncServerWatcher.h"
#include "../src/services/SyncStore.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QProcess>
#include <QRegularExpression>
#include <QScopeGuard>
#include <QSet>
#include <QSettings>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTcpServer>
#include <QTemporaryDir>
#include <QTest>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

namespace {

const QByteArray kRemoteSecret(32, 'K');
const QString kSpace = QStringLiteral("space-1234567890ab10");

struct Device {
    QString path;
    QString connection;
    QString id;
};

struct Node {
    Device device;
    std::unique_ptr<SyncEngine> engine;
    std::unique_ptr<SyncServerWatcher> watcher;
    QList<QStringList> backups;
    bool backupSucceeds = true;
};

class BlockingWatchHttp final : public SyncHttpClient
{
public:
    Response send(const Request& request) override
    {
        Q_UNUSED(request);
        if (calls.fetch_add(1) == 0) {
            Response response;
            response.status = 200;
            response.body = QByteArrayLiteral("{\"rev\":0}");
            return response;
        }
        waiting.store(true);
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [this] { return released; });
        Response response;
        response.failure = Failure::Cancelled;
        response.message = QStringLiteral("测试取消");
        return response;
    }

    void cancelAll() override { releaseAll(); }

    void releaseAll()
    {
        {
            const std::lock_guard<std::mutex> lock(mutex);
            released = true;
        }
        condition.notify_all();
    }

    std::atomic<int> calls{0};
    std::atomic<bool> waiting{false};
    std::mutex mutex;
    std::condition_variable condition;
    bool released = false;
};

// 精确复现 T03 遗留的取消竞态：第二次 send 在“登记进取消集合”之前停在闸门上。
// 闸门前的 cancelAll 对这次请求无效；只有登记之后再取消一次，send 才会返回。
class GateWatchHttp final : public SyncHttpClient
{
public:
    Response send(const Request& request) override
    {
        Q_UNUSED(request);
        if (calls.fetch_add(1) == 0) {
            Response response;
            response.status = 200;
            response.body = QByteArrayLiteral("{\"rev\":0}");
            return response;
        }
        gateReached.store(true);
        {
            std::unique_lock<std::mutex> lock(mutex);
            condition.wait(lock, [this] { return gateOpen; });
        }
        {
            const std::lock_guard<std::mutex> lock(mutex);
            registered = true;
        }
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [this] { return longWaitReleased; });
        Response response;
        response.failure = Failure::Cancelled;
        response.message = QStringLiteral("闸门测试取消");
        return response;
    }

    void cancelAll() override
    {
        {
            const std::lock_guard<std::mutex> lock(mutex);
            if (!registered) {
                cancelledBeforeRegistration = true;
            } else {
                longWaitReleased = true;
            }
        }
        condition.notify_all();
    }

    void releaseGate()
    {
        {
            const std::lock_guard<std::mutex> lock(mutex);
            gateOpen = true;
        }
        condition.notify_all();
    }

    void releaseLongWait()
    {
        {
            const std::lock_guard<std::mutex> lock(mutex);
            longWaitReleased = true;
        }
        condition.notify_all();
    }

    std::atomic<int> calls{0};
    std::atomic<bool> gateReached{false};
    std::atomic<bool> cancelledBeforeRegistration{false};
    std::mutex mutex;
    std::condition_variable condition;
    bool gateOpen = false;
    bool registered = false;
    bool longWaitReleased = false;
};

QSqlDatabase deviceDb(const Device& device)
{
    return QSqlDatabase::database(device.connection);
}

QVariant scalar(const Device& device, const QString& sql)
{
    QSqlQuery query(deviceDb(device));
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return {};
    }
    return query.next() ? query.value(0) : QVariant();
}

bool exec(const Device& device, const QString& sql)
{
    QSqlQuery query(deviceDb(device));
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return false;
    }
    return true;
}

QString addTask(const Device& device, const QString& title)
{
    QSqlQuery query(deviceDb(device));
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
    return scalar(device, QStringLiteral(
                              "SELECT sync_id FROM tasks WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong()))
        .toString();
}

QStringList taskTitles(const Device& device)
{
    QStringList titles;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT title FROM tasks ORDER BY title, id"));
    while (query.next()) {
        titles.append(query.value(0).toString());
    }
    return titles;
}

SyncEngine::Options manualOptions()
{
    SyncEngine::Options options;
    options.tickMs = 60 * 60 * 1000;
    options.publishIntervalMs = 0;
    options.scanIntervalMs = 0;
    options.retryMinMs = 20;
    options.retryMaxMs = 100;
    return options;
}

SyncEngine::Options watcherOnlyOptions()
{
    SyncEngine::Options options;
    options.tickMs = 60 * 60 * 1000;
    options.publishIntervalMs = 60 * 60 * 1000;
    options.scanIntervalMs = 60 * 60 * 1000;
    options.retryMinMs = 20;
    options.retryMaxMs = 100;
    return options;
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

bool syncOnce(Node& node, int timeoutMs = 15000)
{
    node.engine->syncNow();
    return waitIdle(*node.engine, timeoutMs);
}

QString authToken(const QString& space, const QByteArray& secret)
{
    return SyncCrypto::authTokenText(
        SyncCrypto::deriveKeys(secret, space));
}

} // namespace

class RemoteSyncTransportTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void cleanup();

    void joinsRemoteFolderWithSnapshotAndBackup();
    void propagatesBidirectionalChangesAndDeletionWins();
    void catchesUpFromSnapshotAndCleansServerChanges();
    void carriesOldProgressIntoNewServerSpace();
    void watcherDrivesSyncWithoutScanTimer();
    void watchersDoNotExciteSyncCycles();
    void watcherRecoversAfterServerRestart();
    void watcherStopIsPromptAndSilencesChanges();
    void watcherStopClosesPreRegistrationRace();

private:
    Device openDevice(const QString& name);
    bool startServer(quint16 port);
    void stopServer();
    int watchRequestCount() const;
    bool createSpace(const QString& space, const QByteArray& pairSecret,
                     QString* error);
    QUrl baseUrl() const;
    RemoteSyncFolder::Config remoteConfig(
        const QString& space, const QByteArray& pairSecret) const;
    std::unique_ptr<RemoteSyncFolder> remoteFolder(
        const QString& space, const QByteArray& pairSecret) const;
    std::unique_ptr<SyncServerWatcher> watcher(
        const QString& space, const QByteArray& pairSecret);
    std::unique_ptr<Node> makeRemoteNode(
        const QString& name, bool mayCreateFolder, const QString& space,
        const QByteArray& pairSecret, const SyncEngine::Options& options);
    std::unique_ptr<Node> makeLocalNode(
        const QString& name, bool mayCreateFolder, const QString& root,
        const SyncEngine::Options& options);
    bool pairRemote(Node& mac, Node& ipad, const QString& space,
                    const QByteArray& pairSecret,
                    const SyncEngine::Options& options);
    bool pairLocal(Node& mac, Node& ipad, const QString& root,
                   const SyncEngine::Options& options);
    bool serverTree(const QString& space, QJsonArray* entries, qint64* rev,
                    QString* error);
    QSet<QString> serverPaths(const QString& space);

    std::unique_ptr<QTemporaryDir> preferences;
    std::unique_ptr<QTemporaryDir> data;
    QList<QString> connections;
    QProcess* server = nullptr;
    QString serverOutput;
    QString serverErrorOutput;
    QString enrollFile;
    quint16 serverPort = 0;
    QString enrollSecret;
};

void RemoteSyncTransportTests::initTestCase()
{
    preferences = std::make_unique<QTemporaryDir>();
    QVERIFY(preferences->isValid());
    QCoreApplication::setOrganizationName(
        QStringLiteral("PomodoroTodoRemoteTransportTests"));
    QCoreApplication::setApplicationName(
        QStringLiteral("RemoteSyncTransportTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope,
                       preferences->path());
}

void RemoteSyncTransportTests::cleanupTestCase()
{
    preferences.reset();
}

void RemoteSyncTransportTests::init()
{
    data = std::make_unique<QTemporaryDir>();
    QVERIFY(data->isValid());
    enrollSecret = QStringLiteral("enroll-secret-for-remote-transport-tests");
    enrollFile = data->filePath(QStringLiteral("enroll.sha256"));
    QFile file(enrollFile);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    const QByteArray digest = QCryptographicHash::hash(
        enrollSecret.toUtf8(), QCryptographicHash::Sha256).toHex();
    QCOMPARE(file.write(digest), digest.size());
    file.close();
    QVERIFY(startServer(0));
}

void RemoteSyncTransportTests::cleanup()
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

bool RemoteSyncTransportTests::startServer(quint16 port)
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
    static const QRegularExpression readyPattern(
        QStringLiteral("PT_SYNC_READY (\\d+)"));
    while (timer.elapsed() < 5000) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        const QRegularExpressionMatch match
            = readyPattern.match(serverOutput);
        if (match.hasMatch()) {
            serverPort = static_cast<quint16>(match.captured(1).toUInt());
            return port == 0 || serverPort == port;
        }
        QTest::qWait(10);
    }
    return false;
}

void RemoteSyncTransportTests::stopServer()
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

int RemoteSyncTransportTests::watchRequestCount() const
{
    return static_cast<int>(
        serverErrorOutput.count(QStringLiteral("/watch ")));
}

QUrl RemoteSyncTransportTests::baseUrl() const
{
    return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(serverPort));
}

RemoteSyncFolder::Config RemoteSyncTransportTests::remoteConfig(
    const QString& space, const QByteArray& pairSecret) const
{
    return {baseUrl(), space, pairSecret};
}

std::unique_ptr<RemoteSyncFolder>
RemoteSyncTransportTests::remoteFolder(
    const QString& space, const QByteArray& pairSecret) const
{
    return std::make_unique<RemoteSyncFolder>(
        remoteConfig(space, pairSecret),
        std::make_shared<AppleSyncHttpClient>(),
        std::make_shared<AppleSyncBlockCipher>());
}

bool RemoteSyncTransportTests::createSpace(
    const QString& space, const QByteArray& pairSecret, QString* error)
{
    const QByteArray token
        = authToken(space, pairSecret).toUtf8();
    const QJsonObject body{
        {QStringLiteral("space"), space},
        {QStringLiteral("tokenSha256"),
         QString::fromLatin1(
             QCryptographicHash::hash(token, QCryptographicHash::Sha256)
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
                : QStringLiteral("建空间 HTTP %1").arg(response.status);
        }
        return false;
    }
    return true;
}

Device RemoteSyncTransportTests::openDevice(const QString& name)
{
    Device device;
    device.path = data->filePath(name + QStringLiteral(".sqlite"));
    if (!DatabaseManager::instance()->initialize(device.path)) {
        qWarning() << "initialize failed" << device.path;
    }
    DatabaseManager::instance()->close();
    device.connection = QStringLiteral("remote-transport-") + name;
    QSqlDatabase database
        = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"),
                                    device.connection);
    database.setDatabaseName(device.path);
    database.open();
    QSqlQuery(database).exec(QStringLiteral("PRAGMA foreign_keys = ON"));
    QSqlQuery(database).exec(QStringLiteral("PRAGMA busy_timeout = 5000"));
    connections.append(device.connection);
    device.id = SyncStore(device.connection).deviceId();
    return device;
}

std::unique_ptr<Node> RemoteSyncTransportTests::makeRemoteNode(
    const QString& name, bool mayCreateFolder, const QString& space,
    const QByteArray& pairSecret, const SyncEngine::Options& options)
{
    auto node = std::make_unique<Node>();
    node->device = openDevice(name);
    SyncEngine::Options nodeOptions = options;
    nodeOptions.mayCreateFolder = mayCreateFolder;
    node->engine = std::make_unique<SyncEngine>(
        remoteFolder(space, pairSecret), nodeOptions,
        node->device.connection);
    Node* raw = node.get();
    node->engine->setSafetyBackup([raw](QString* error) {
        raw->backups.append(taskTitles(raw->device));
        if (!raw->backupSucceeds) {
            *error = QStringLiteral("备份目录写不进去");
        }
        return raw->backupSucceeds;
    });
    return node;
}

std::unique_ptr<Node> RemoteSyncTransportTests::makeLocalNode(
    const QString& name, bool mayCreateFolder, const QString& root,
    const SyncEngine::Options& options)
{
    auto node = std::make_unique<Node>();
    node->device = openDevice(name);
    SyncEngine::Options nodeOptions = options;
    nodeOptions.mayCreateFolder = mayCreateFolder;
    node->engine = std::make_unique<SyncEngine>(
        std::make_unique<LocalSyncFolder>(root), nodeOptions,
        node->device.connection);
    Node* raw = node.get();
    node->engine->setSafetyBackup([raw](QString* error) {
        raw->backups.append(taskTitles(raw->device));
        if (!raw->backupSucceeds) {
            *error = QStringLiteral("备份目录写不进去");
        }
        return raw->backupSucceeds;
    });
    return node;
}

bool RemoteSyncTransportTests::pairRemote(
    Node& mac, Node& ipad, const QString& space,
    const QByteArray& pairSecret, const SyncEngine::Options&)
{
    Q_UNUSED(space);
    Q_UNUSED(pairSecret);
    mac.engine->start();
    if (!waitIdle(*mac.engine)
        || mac.engine->status() != SyncEngine::Status::UpToDate) {
        return false;
    }
    ipad.engine->start();
    if (!waitIdle(*ipad.engine)
        || ipad.engine->status() != SyncEngine::Status::NeedsConfirmation) {
        return false;
    }
    ipad.engine->confirmJoin();
    if (!waitIdle(*ipad.engine)
        || ipad.engine->status() != SyncEngine::Status::UpToDate) {
        return false;
    }
    return syncOnce(mac);
}

bool RemoteSyncTransportTests::pairLocal(
    Node& mac, Node& ipad, const QString& root,
    const SyncEngine::Options&)
{
    Q_UNUSED(root);
    mac.engine->start();
    if (!waitIdle(*mac.engine)
        || mac.engine->status() != SyncEngine::Status::UpToDate) {
        return false;
    }
    ipad.engine->start();
    if (!waitIdle(*ipad.engine)
        || ipad.engine->status() != SyncEngine::Status::NeedsConfirmation) {
        return false;
    }
    ipad.engine->confirmJoin();
    if (!waitIdle(*ipad.engine)
        || ipad.engine->status() != SyncEngine::Status::UpToDate) {
        return false;
    }
    return syncOnce(mac);
}

std::unique_ptr<SyncServerWatcher>
RemoteSyncTransportTests::watcher(
    const QString& space, const QByteArray& pairSecret)
{
    SyncServerWatcher::Config config{
        baseUrl(),
        space,
        authToken(space, pairSecret),
        2,
        100,
        500,
    };
    return std::make_unique<SyncServerWatcher>(
        config, std::make_shared<AppleSyncHttpClient>());
}

bool RemoteSyncTransportTests::serverTree(
    const QString& space, QJsonArray* entries, qint64* rev, QString* error)
{
    AppleSyncHttpClient client;
    SyncHttpClient::Request request;
    request.method = QByteArrayLiteral("GET");
    request.url = QUrl(
        baseUrl().toString()
        + QStringLiteral("/v1/spaces/%1/tree").arg(space));
    request.timeoutMs = 5000;
    request.headers = {
        {QByteArrayLiteral("Authorization"),
         QByteArrayLiteral("Bearer ")
             + authToken(space, kRemoteSecret).toUtf8()},
        {QByteArrayLiteral("User-Agent"),
         QByteArrayLiteral("PomodoroTodo-sync/1")},
    };
    const SyncHttpClient::Response response = client.send(request);
    if (response.failure != SyncHttpClient::Failure::None
        || response.status != 200) {
        if (error) {
            *error = response.failure != SyncHttpClient::Failure::None
                ? response.message
                : QStringLiteral("tree HTTP %1").arg(response.status);
        }
        return false;
    }
    const QJsonObject object
        = QJsonDocument::fromJson(response.body).object();
    const QJsonValue revValue = object.value(QStringLiteral("rev"));
    const QJsonValue entriesValue = object.value(QStringLiteral("entries"));
    if (!revValue.isDouble() || !entriesValue.isArray()) {
        if (error) {
            *error = QStringLiteral("tree 响应不合法");
        }
        return false;
    }
    if (rev) {
        *rev = static_cast<qint64>(revValue.toDouble());
    }
    if (entries) {
        *entries = entriesValue.toArray();
    }
    return true;
}

QSet<QString> RemoteSyncTransportTests::serverPaths(const QString& space)
{
    QSet<QString> result;
    QJsonArray entries;
    QString error;
    if (!serverTree(space, &entries, nullptr, &error)) {
        qWarning() << error;
        return result;
    }
    for (const QJsonValue& value : entries) {
        result.insert(value.toObject().value(QStringLiteral("path")).toString());
    }
    return result;
}

// 保证空服务器空间由 Mac 建出标记/快照，iPad 首次加入先备份再把数据换成 Mac 的。
void RemoteSyncTransportTests::joinsRemoteFolderWithSnapshotAndBackup()
{
    QString error;
    QVERIFY2(createSpace(kSpace, kRemoteSecret, &error), qPrintable(error));
    auto mac = makeRemoteNode(
        QStringLiteral("mac"), true, kSpace, kRemoteSecret, manualOptions());
    auto ipad = makeRemoteNode(
        QStringLiteral("ipad"), false, kSpace, kRemoteSecret,
        manualOptions());
    QVERIFY(!addTask(mac->device, QStringLiteral("Mac 的任务")).isEmpty());
    QVERIFY(!addTask(ipad->device, QStringLiteral("iPad 的测试任务")).isEmpty());
    QVERIFY(pairRemote(*mac, *ipad, kSpace, kRemoteSecret,
                       manualOptions()));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    const QSet<QString> paths = serverPaths(kSpace);
    QVERIFY(paths.contains(SyncFiles::markerFileName()));
    QVERIFY(std::any_of(paths.cbegin(), paths.cend(), [&](const QString& path) {
        return path.startsWith(
            SyncFiles::deviceDirectory(mac->device.id)
            + QStringLiteral("/snapshot-"));
    }));
    QCOMPARE(ipad->backups.size(), 1);
    QCOMPARE(ipad->backups.first(),
             QStringList{QStringLiteral("iPad 的测试任务")});
    QCOMPARE(taskTitles(mac->device),
             QStringList{QStringLiteral("Mac 的任务")});
    QCOMPARE(taskTitles(ipad->device), taskTitles(mac->device));
}

// 保证远端双写能互见，删除与修改竞争时删除优先并留下冲突记录。
void RemoteSyncTransportTests::propagatesBidirectionalChangesAndDeletionWins()
{
    QString error;
    QVERIFY2(createSpace(kSpace, kRemoteSecret, &error), qPrintable(error));
    auto mac = makeRemoteNode(
        QStringLiteral("mac"), true, kSpace, kRemoteSecret, manualOptions());
    auto ipad = makeRemoteNode(
        QStringLiteral("ipad"), false, kSpace, kRemoteSecret,
        manualOptions());
    QVERIFY(pairRemote(*mac, *ipad, kSpace, kRemoteSecret,
                       manualOptions()));

    const QString task = addTask(mac->device, QStringLiteral("会冲突"));
    QVERIFY(!task.isEmpty());
    QVERIFY(syncOnce(*mac));
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(taskTitles(ipad->device), QStringList{QStringLiteral("会冲突")});

    QVERIFY(exec(mac->device,
                 QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'")
                     .arg(task)));
    QVERIFY(exec(ipad->device,
                 QStringLiteral("UPDATE tasks SET title = '同时改名' "
                                "WHERE sync_id = '%1'")
                     .arg(task)));
    QVERIFY(syncOnce(*mac));
    QVERIFY(syncOnce(*ipad));
    QVERIFY(syncOnce(*mac));

    QVERIFY(taskTitles(mac->device).isEmpty());
    QVERIFY(taskTitles(ipad->device).isEmpty());
    const int conflicts
        = scalar(mac->device,
                 QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log"))
              .toInt()
        + scalar(ipad->device,
                 QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log"))
              .toInt();
    QVERIFY(conflicts > 0);
    QCOMPARE(taskTitles(mac->device), taskTitles(ipad->device));
}

// 保证落后很多批的设备从快照追上，维护后再删掉已有快照兜底的旧改动文件。
void RemoteSyncTransportTests::catchesUpFromSnapshotAndCleansServerChanges()
{
    QString error;
    QVERIFY2(createSpace(kSpace, kRemoteSecret, &error), qPrintable(error));
    SyncEngine::Options options = manualOptions();
    options.compactAfterFiles = 2;
    options.maintenanceIntervalMs = 0;
    options.peerStaleDays = 0;
    options.catchUpViaSnapshot = 1;
    auto mac = makeRemoteNode(
        QStringLiteral("mac"), true, kSpace, kRemoteSecret, options);
    auto ipad = makeRemoteNode(
        QStringLiteral("ipad"), false, kSpace, kRemoteSecret, options);
    QVERIFY(pairRemote(*mac, *ipad, kSpace, kRemoteSecret, options));

    for (int index = 1; index <= 3; ++index) {
        QVERIFY(!addTask(
                     mac->device,
                     QStringLiteral("第 %1 批").arg(index)).isEmpty());
        QVERIFY(syncOnce(*mac));
    }
    const QSet<QString> paths = serverPaths(kSpace);
    const QString changes = SyncFiles::changesDirectory(mac->device.id);
    QVERIFY(!paths.contains(
        changes + QStringLiteral("/") + SyncFiles::changeFileName({0, 1})));
    QVERIFY(!paths.contains(
        changes + QStringLiteral("/") + SyncFiles::changeFileName({0, 2})));
    QVERIFY(paths.contains(
        SyncFiles::deviceDirectory(mac->device.id)
        + QStringLiteral("/snapshot-0000-00000002.json")));

    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(ipad->device), taskTitles(mac->device));
    QCOMPARE(SyncStore(ipad->device.connection)
                 .peerCursors()
                 .value(mac->device.id),
             (SyncPosition{0, 3}));
}

// 保证两台设备带着 iCloud 方式的旧进度换到新服务器空间后，后续双向修改仍能接上。
void RemoteSyncTransportTests::carriesOldProgressIntoNewServerSpace()
{
    const QString localRoot = data->filePath(QStringLiteral("old-icloud"));
    auto mac = makeLocalNode(
        QStringLiteral("mac"), true, localRoot, manualOptions());
    auto ipad = makeLocalNode(
        QStringLiteral("ipad"), false, localRoot, manualOptions());
    QVERIFY(pairLocal(*mac, *ipad, localRoot, manualOptions()));

    for (int round = 1; round <= 2; ++round) {
        QVERIFY(!addTask(mac->device,
                         QStringLiteral("Mac 旧进度 %1").arg(round)).isEmpty());
        QVERIFY(syncOnce(*mac));
        QVERIFY(syncOnce(*ipad));
        QVERIFY(!addTask(ipad->device,
                         QStringLiteral("iPad 旧进度 %1").arg(round)).isEmpty());
        QVERIFY(syncOnce(*ipad));
        QVERIFY(syncOnce(*mac));
    }
    SyncStore macOldStore(mac->device.connection);
    SyncStore ipadOldStore(ipad->device.connection);
    QVERIFY(macOldStore.outboundPosition().seq > 1);
    QVERIFY(macOldStore.peerCursors().value(ipad->device.id).seq > 1);
    QVERIFY(ipadOldStore.outboundPosition().seq > 1);
    QVERIFY(ipadOldStore.peerCursors().value(mac->device.id).seq > 1);

    const QString unsentTitle = QStringLiteral("iPad 换空间前未发出");
    QVERIFY(!addTask(ipad->device, unsentTitle).isEmpty());
    QVERIFY(SyncStore(ipad->device.connection).pendingCount() > 0);

    QString error;
    QVERIFY2(createSpace(kSpace, kRemoteSecret, &error), qPrintable(error));
    mac->engine->setFolder(remoteFolder(kSpace, kRemoteSecret));
    QVERIFY(SyncStore(mac->device.connection).setFolderId(QString()));
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    const QSet<QString> afterSwitch = serverPaths(kSpace);
    QVERIFY(afterSwitch.contains(SyncFiles::markerFileName()));
    QVERIFY(std::any_of(
        afterSwitch.cbegin(), afterSwitch.cend(),
        [&](const QString& path) {
            return path.startsWith(
                SyncFiles::deviceDirectory(mac->device.id)
                + QStringLiteral("/snapshot-"));
        }));

    ipad->engine->setFolder(remoteFolder(kSpace, kRemoteSecret));
    QVERIFY(syncOnce(*ipad));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::NeedsConfirmation);
    const qsizetype backupsBeforeRemoteJoin = ipad->backups.size();
    ipad->engine->confirmJoin();
    QVERIFY(waitIdle(*ipad->engine));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(ipad->backups.size(), backupsBeforeRemoteJoin + 1);
    QVERIFY(ipad->backups.last().contains(unsentTitle));
    QVERIFY(!taskTitles(ipad->device).contains(unsentTitle));

    const QString macNew = addTask(mac->device, QStringLiteral("Mac 新任务"));
    QVERIFY(!macNew.isEmpty());
    QVERIFY(syncOnce(*mac));
    QVERIFY(syncOnce(*ipad));
    const QString ipadNew = addTask(ipad->device, QStringLiteral("iPad 新任务"));
    QVERIFY(!ipadNew.isEmpty());
    QVERIFY(syncOnce(*ipad));
    QVERIFY(syncOnce(*mac));
    QVERIFY(exec(ipad->device,
                 QStringLiteral("UPDATE tasks SET title = 'iPad 改过 Mac 标题' "
                                "WHERE sync_id = '%1'")
                     .arg(macNew)));
    QVERIFY(syncOnce(*ipad));
    QVERIFY(syncOnce(*mac));
    QVERIFY(exec(mac->device,
                 QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'")
                     .arg(ipadNew)));
    QVERIFY(syncOnce(*mac));
    QVERIFY(syncOnce(*ipad));

    QCOMPARE(taskTitles(mac->device), taskTitles(ipad->device));
    QVERIFY(taskTitles(mac->device).contains(
        QStringLiteral("iPad 改过 Mac 标题")));
    QVERIFY(!taskTitles(mac->device).contains(
        QStringLiteral("iPad 新任务")));
    QCOMPARE(scalar(mac->device,
                    QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log"))
                 .toInt(),
             0);
    QCOMPARE(scalar(ipad->device,
                    QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log"))
                 .toInt(),
             0);
}

// 保证扫描与 tick 定时器都不触发时，服务器 watcher 仍能驱动另一端在 5 秒内同步。
void RemoteSyncTransportTests::watcherDrivesSyncWithoutScanTimer()
{
    QString error;
    QVERIFY2(createSpace(kSpace, kRemoteSecret, &error), qPrintable(error));
    auto mac = makeRemoteNode(
        QStringLiteral("mac"), true, kSpace, kRemoteSecret,
        watcherOnlyOptions());
    auto ipad = makeRemoteNode(
        QStringLiteral("ipad"), false, kSpace, kRemoteSecret,
        watcherOnlyOptions());
    QVERIFY(pairRemote(*mac, *ipad, kSpace, kRemoteSecret,
                       watcherOnlyOptions()));

    mac->watcher = watcher(kSpace, kRemoteSecret);
    ipad->watcher = watcher(kSpace, kRemoteSecret);
    connect(mac->watcher.get(), &SyncServerWatcher::changed,
            mac->engine.get(), &SyncEngine::syncNow,
            Qt::QueuedConnection);
    connect(ipad->watcher.get(), &SyncServerWatcher::changed,
            ipad->engine.get(), &SyncEngine::syncNow,
            Qt::QueuedConnection);
    mac->watcher->start();
    ipad->watcher->start();

    QVERIFY(!addTask(mac->device, QStringLiteral("只靠 watcher")).isEmpty());
    QVERIFY(syncOnce(*mac));
    QTRY_VERIFY_WITH_TIMEOUT(
        taskTitles(ipad->device).contains(QStringLiteral("只靠 watcher")),
        5000);
    QVERIFY(waitIdle(*ipad->engine));
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
}

// 保证 watcher 收到相同 rev 的超时返回时不会反复请求引擎，服务器 rev 和两端空闲状态保持稳定。
void RemoteSyncTransportTests::watchersDoNotExciteSyncCycles()
{
    QString error;
    QVERIFY2(createSpace(kSpace, kRemoteSecret, &error), qPrintable(error));
    auto mac = makeRemoteNode(
        QStringLiteral("mac"), true, kSpace, kRemoteSecret,
        watcherOnlyOptions());
    auto ipad = makeRemoteNode(
        QStringLiteral("ipad"), false, kSpace, kRemoteSecret,
        watcherOnlyOptions());
    QVERIFY(pairRemote(*mac, *ipad, kSpace, kRemoteSecret,
                       watcherOnlyOptions()));

    mac->watcher = watcher(kSpace, kRemoteSecret);
    ipad->watcher = watcher(kSpace, kRemoteSecret);
    connect(mac->watcher.get(), &SyncServerWatcher::changed,
            mac->engine.get(), &SyncEngine::syncNow,
            Qt::QueuedConnection);
    connect(ipad->watcher.get(), &SyncServerWatcher::changed,
            ipad->engine.get(), &SyncEngine::syncNow,
            Qt::QueuedConnection);
    mac->watcher->start();
    ipad->watcher->start();

    qint64 baseline = -1;
    QVERIFY(serverTree(kSpace, nullptr, &baseline, &error));
    QElapsedTimer observation;
    observation.start();
    while (observation.elapsed() < 6000) {
        qint64 current = -1;
        QVERIFY(serverTree(kSpace, nullptr, &current, &error));
        QCOMPARE(current, baseline);
        QVERIFY2(mac->engine->isIdle(), "Mac 被 watcher 自激");
        QVERIFY2(ipad->engine->isIdle(), "iPad 被 watcher 自激");
        // 每次只推进一小段事件循环，持续观察整个窗口；不是先固定等待再单次判断。
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QTest::qWait(20);
    }
}

// 保证服务器中断时引擎进入 Error，原端口恢复后 watcher 唤醒并把离线改动送到另一端。
void RemoteSyncTransportTests::watcherRecoversAfterServerRestart()
{
    QString error;
    QVERIFY2(createSpace(kSpace, kRemoteSecret, &error), qPrintable(error));
    auto mac = makeRemoteNode(
        QStringLiteral("mac"), true, kSpace, kRemoteSecret,
        watcherOnlyOptions());
    auto ipad = makeRemoteNode(
        QStringLiteral("ipad"), false, kSpace, kRemoteSecret,
        watcherOnlyOptions());
    QVERIFY(pairRemote(*mac, *ipad, kSpace, kRemoteSecret,
                       watcherOnlyOptions()));

    mac->watcher = watcher(kSpace, kRemoteSecret);
    ipad->watcher = watcher(kSpace, kRemoteSecret);
    connect(mac->watcher.get(), &SyncServerWatcher::changed,
            mac->engine.get(), &SyncEngine::syncNow,
            Qt::QueuedConnection);
    connect(ipad->watcher.get(), &SyncServerWatcher::changed,
            ipad->engine.get(), &SyncEngine::syncNow,
            Qt::QueuedConnection);
    QSignalSpy macChanges(mac->watcher.get(),
                          &SyncServerWatcher::changed);
    mac->watcher->start();
    ipad->watcher->start();
    const int baselineWatchCalls = watchRequestCount();
    QTRY_VERIFY_WITH_TIMEOUT(watchRequestCount() >= baselineWatchCalls + 2,
                             5000);

    const quint16 fixedPort = serverPort;
    stopServer();
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::Error);
    QVERIFY(!addTask(mac->device, QStringLiteral("断服期间写入")).isEmpty());
    QVERIFY(startServer(fixedPort));
    macChanges.clear();
    QVERIFY(syncOnce(*mac));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    QTRY_VERIFY_WITH_TIMEOUT(macChanges.count() > 0, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(
        taskTitles(ipad->device).contains(QStringLiteral("断服期间写入")),
        8000);
    QVERIFY(waitIdle(*ipad->engine));
    QCOMPARE(mac->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(ipad->engine->status(), SyncEngine::Status::UpToDate);
    QCOMPARE(taskTitles(mac->device), taskTitles(ipad->device));
}

// 保证 watcher 挂在长等待时 stop 及时返回，并在停止后不再发送 changed。
void RemoteSyncTransportTests::watcherStopIsPromptAndSilencesChanges()
{
    auto blocking = std::make_shared<BlockingWatchHttp>();
    SyncServerWatcher stopWatcher(
        {baseUrl(), kSpace, QStringLiteral("test-token"), 25, 100, 500},
        blocking);
    QSignalSpy changes(&stopWatcher, &SyncServerWatcher::changed);
    stopWatcher.start();
    QTRY_VERIFY_WITH_TIMEOUT(blocking->waiting.load(), 2000);

    std::atomic<bool> stopDone{false};
    std::thread stopper([&] {
        stopWatcher.stop();
        stopDone.store(true);
    });
    QElapsedTimer timer;
    timer.start();
    while (!stopDone.load() && timer.elapsed() < 1000) {
        QTest::qWait(5);
    }
    if (!stopDone.load()) {
        // 变异实现没有取消阻塞请求时先放行，避免测试析构永久挂住；随后明确失败。
        blocking->releaseAll();
        stopper.join();
        QFAIL("watcher.stop() 在 1 秒内没有返回");
    }
    stopper.join();
    QVERIFY(timer.elapsed() < 1000);

    QElapsedTimer quiet;
    quiet.start();
    while (quiet.elapsed() < 300) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QCOMPARE(changes.count(), 0);
        QTest::qWait(10);
    }
}

// 保证 stop() 能关闭“已经过停止检查但尚未登记 HTTP 任务”的窗口，而不是等满一次长轮询。
void RemoteSyncTransportTests::watcherStopClosesPreRegistrationRace()
{
    auto gate = std::make_shared<GateWatchHttp>();
    SyncServerWatcher stopWatcher(
        {baseUrl(), kSpace, QStringLiteral("test-token"), 25, 100, 500},
        gate);
    QSignalSpy changes(&stopWatcher, &SyncServerWatcher::changed);
    stopWatcher.start();
    QTRY_VERIFY_WITH_TIMEOUT(gate->gateReached.load(), 2000);

    std::atomic<bool> stopDone{false};
    std::thread stopper([&] {
        stopWatcher.stop();
        stopDone.store(true);
    });
    QElapsedTimer cancelWait;
    cancelWait.start();
    while (!gate->cancelledBeforeRegistration.load()
           && cancelWait.elapsed() < 1000) {
        QTest::qWait(5);
    }
    if (!gate->cancelledBeforeRegistration.load()) {
        gate->releaseGate();
        gate->releaseLongWait();
        stopper.join();
        QFAIL("stop() 没有先执行登记前 cancelAll");
    }
    gate->releaseGate();

    QElapsedTimer timer;
    timer.start();
    while (!stopDone.load() && timer.elapsed() < 1000) {
        QTest::qWait(5);
    }
    if (!stopDone.load()) {
        gate->releaseLongWait();
        stopper.join();
        QFAIL("stop() 没有关闭登记前取消窗口");
    }
    stopper.join();
    QVERIFY(timer.elapsed() < 1000);
    QCOMPARE(changes.count(), 0);
}

QTEST_GUILESS_MAIN(RemoteSyncTransportTests)
#include "RemoteSyncTransportTests.moc"
