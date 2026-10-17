#include "platform/macos/MacBackupExecutor.h"
#include "services/BackupService.h"
#include "services/DatabaseManager.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QScopeGuard>
#include <QSettings>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include <csignal>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <mutex>
#include <set>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

namespace {
using namespace std::chrono_literals;

class EnvironmentValue
{
public:
    EnvironmentValue(QByteArray key, const QByteArray& value) : m_key(std::move(key)), m_previous(qgetenv(m_key.constData()))
    {
        qputenv(m_key.constData(), value);
    }
    ~EnvironmentValue()
    {
        if (m_previous.isNull()) qunsetenv(m_key.constData());
        else qputenv(m_key.constData(), m_previous);
    }
private:
    QByteArray m_key;
    QByteArray m_previous;
};

class GuardedProcessControl final : public MacBackupExecutor::ProcessControl
{
public:
    explicit GuardedProcessControl(bool pretendUnreaped = false, int hardTimeoutSeconds = 20)
        : m_pretendUnreaped(pretendUnreaped), m_watchdog([this, hardTimeoutSeconds] {
            std::unique_lock lock(m_mutex);
            if (m_finished.wait_for(lock, std::chrono::seconds(hardTimeoutSeconds), [this] { return m_done; })) return;
            lock.unlock();
            cleanupChildren();
            std::fputs("测试子进程超过独立硬期限，已强制清理\n", stderr);
            std::_Exit(124);
        }) {}
    ~GuardedProcessControl() override
    {
        {
            std::lock_guard lock(m_mutex);
            m_done = true;
        }
        m_finished.notify_all();
        m_watchdog.join();
        cleanupChildren();
    }
    void didSpawn(pid_t process) override
    {
        std::lock_guard lock(m_mutex);
        m_children.insert(process);
        lastPid.store(process);
        ++spawnCount;
    }
    pid_t wait(pid_t process, int* status, int options) override
    {
        // 真实内核无法稳定制造“SIGKILL 后仍回收不到”，仅替换产品观察，不阻止测试最终回收。
        if (m_pretendUnreaped) return 0;
        const pid_t result = ::waitpid(process, status, options);
        if (result == process) {
            std::lock_guard lock(m_mutex);
            m_children.erase(process);
        }
        return result;
    }
    int sendSignal(pid_t process, int signal) override
    {
        if (signal == SIGKILL) ++killCount;
        return ::kill(process, signal);
    }
    bool running() const { return lastPid.load() > 0 && ::kill(lastPid.load(), 0) == 0; }

    std::atomic<pid_t> lastPid{-1};
    std::atomic_int spawnCount{0};
    std::atomic_int killCount{0};
private:
    void cleanupChildren()
    {
        std::set<pid_t> children;
        {
            std::lock_guard lock(m_mutex);
            children.swap(m_children);
        }
        // 这层护栏保护测试自身，不参与产品期限的计时或成功判断。
        for (const pid_t child : children) {
            ::kill(child, SIGKILL);
            for (int attempt = 0; attempt < 1000; ++attempt) {
                int status = 0;
                const auto reaped = ::waitpid(child, &status, WNOHANG);
                if (reaped == child || (reaped < 0 && errno == ECHILD)) break;
                std::this_thread::sleep_for(1ms);
            }
        }
    }
    bool m_pretendUnreaped;
    std::mutex m_mutex;
    std::condition_variable m_finished;
    std::set<pid_t> m_children;
    bool m_done = false;
    std::thread m_watchdog;
};

bool populateDatabase(const QString& path, int mebibytes)
{
    if (!DatabaseManager::instance()->initialize(path)) return false;
    auto database = DatabaseManager::instance()->database();
    QSqlQuery query(database);
    if (!query.exec(QStringLiteral("CREATE TABLE executor_padding (id INTEGER PRIMARY KEY, data BLOB)"))
        || !database.transaction()) return false;
    for (int i = 0; i < mebibytes; ++i) {
        if (!query.exec(QStringLiteral("INSERT INTO executor_padding(data) VALUES(zeroblob(1048576))"))) {
            database.rollback();
            return false;
        }
    }
    return database.commit();
}

BackupOperations::SnapshotRequest makeSnapshotRequest(const QTemporaryDir& directory, const QString& destination)
{
    const auto settingsPath = directory.filePath(QStringLiteral("settings.ini"));
    const auto settings = BackupOperations::captureOwnedSettings(settingsPath);
    return {directory.filePath(QStringLiteral("database.db")), destination,
            directory.filePath(QStringLiteral("local-staging")), settings.effectiveSettingsPath,
            QStringLiteral("manual"), DatabaseManager::kCurrentSchemaVersion, settings.values};
}

QByteArray readFile(const QString& path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    return file.readAll();
}

template<typename T> bool ready(std::future<T>& future)
{
    return future.wait_for(0ms) == std::future_status::ready;
}

QStringList temporarySnapshots(const QString& directory)
{
    return QDir(directory).entryList({QStringLiteral(".snapshot-tmp-*")}, QDir::Files | QDir::Hidden);
}
}

class MacBackupExecutorTests : public QObject
{
    Q_OBJECT
private slots:
    void initTestCase();
    void cleanup();
    void realExecutorMatchesInProcessOperations();
    void cancelledSnapshotExitsAndRemovesStaging();
    void ignoredStopIsKilledWithinDeadline();
    void unreapedExecutorMakesAbandonmentSticky_data();
    void unreapedExecutorMakesAbandonmentSticky();
    void incompleteAndAbnormalResultsFail_data();
    void incompleteAndAbnormalResultsFail();
    void shutdownStopsAnUnresponsiveExecutorWithinDeadline();
    void failuresLogOnlyStandardErrorTail_data();
    void failuresLogOnlyStandardErrorTail();
    void closedStandardStreamsStillReachExecutor();
    void measureLargeSnapshot();
};

void MacBackupExecutorTests::initTestCase()
{
    // 对照备份与真实执行器使用同一应用版本，避免把测试宿主默认空版本当成产品差异。
    QCoreApplication::setApplicationVersion(QStringLiteral(POMODORO_TODO_VERSION));
    QVERIFY(QFileInfo::exists(QStringLiteral(POMODORO_BACKUP_EXECUTOR_PATH)));
    QVERIFY(QFileInfo::exists(QStringLiteral(POMODORO_BACKUP_STUB_PATH)));
}

void MacBackupExecutorTests::cleanup()
{
    DatabaseManager::instance()->close();
}

void MacBackupExecutorTests::realExecutorMatchesInProcessOperations()
{
    // 独立执行器的快照、检查、暂存与进程内结果一致，嵌入的偏好保留主进程捕获的值。
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QVERIFY(populateDatabase(directory.filePath(QStringLiteral("database.db")), 8));
    const QVariantMap values{{QStringLiteral("focus/workMinutes"), 37},
                             {QStringLiteral("appearance/name"), QStringLiteral("执行器测试")},
                             {QStringLiteral("appearance/enabled"), true}};
    {
        QSettings settings(directory.filePath(QStringLiteral("settings.ini")), QSettings::IniFormat);
        for (auto it = values.constBegin(); it != values.constEnd(); ++it) settings.setValue(it.key(), it.value());
        settings.sync();
        QCOMPARE(settings.status(), QSettings::NoError);
    }
    const auto guard = std::make_shared<GuardedProcessControl>();
    MacBackupExecutor executor(QStringLiteral(POMODORO_BACKUP_EXECUTOR_PATH), guard);
    InProcessBackupExecutor local;
    auto request = makeSnapshotRequest(directory, directory.filePath(QStringLiteral("local.tomatobackup")));
    const auto inProcess = local.createSnapshot(request, {});
    QVERIFY2(inProcess.success, qPrintable(inProcess.error));
    request.destinationPath = directory.filePath(QStringLiteral("child.tomatobackup"));
    const auto isolated = executor.createSnapshot(request, {});
    QVERIFY2(isolated.success, qPrintable(isolated.error));
    QVERIFY(isolated.committed);
    auto normalInfo = local.inspectBackup(directory.filePath(QStringLiteral("local.tomatobackup")), DatabaseManager::kCurrentSchemaVersion, {});
    auto isolatedInfo = executor.inspectBackup(request.destinationPath, DatabaseManager::kCurrentSchemaVersion, {});
    QVERIFY(normalInfo.value(QStringLiteral("valid")).toBool());
    QVERIFY2(isolatedInfo.value(QStringLiteral("valid")).toBool(), qPrintable(isolatedInfo.value(QStringLiteral("reason")).toString()));
    normalInfo.remove(QStringLiteral("createdAt"));
    isolatedInfo.remove(QStringLiteral("createdAt"));
    QCOMPARE(isolatedInfo, normalInfo);
    const auto embedded = BackupOperations::readEmbeddedSettings(request.destinationPath);
    QVERIFY(embedded.success);
    QCOMPARE(embedded.values, values);
    const auto stagedPath = directory.filePath(QStringLiteral("staged.tomatobackup"));
    const auto staged = executor.stageCopy(request.destinationPath, stagedPath, BackupOperations::kMaxBackupFileBytes, {});
    const auto localStagedPath = directory.filePath(QStringLiteral("local-staged.tomatobackup"));
    const auto localStaged = local.stageCopy(request.destinationPath, localStagedPath, BackupOperations::kMaxBackupFileBytes, {});
    QVERIFY(staged.success);
    QCOMPARE(staged.success, localStaged.success);
    QCOMPARE(staged.committed, localStaged.committed);
    QCOMPARE(readFile(stagedPath), readFile(localStagedPath));
    QVERIFY(temporarySnapshots(request.stagingDirectory).isEmpty());
    QVERIFY(!executor.hasAbandonedWork());
}

void MacBackupExecutorTests::cancelledSnapshotExitsAndRemovesStaging()
{
    // 快照已经开始生成后取消，执行器在停止响应预算内协作退出，不发布目标也不留本地暂存。
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QVERIFY(populateDatabase(directory.filePath(QStringLiteral("database.db")), 64));
    const auto request = makeSnapshotRequest(directory, directory.filePath(QStringLiteral("cancelled.tomatobackup")));
    const auto guard = std::make_shared<GuardedProcessControl>();
    MacBackupExecutor executor(QStringLiteral(POMODORO_BACKUP_EXECUTOR_PATH), guard);
    const auto operation = std::make_shared<BackupOperationControl>();
    auto future = std::async(std::launch::async, [&] { return executor.createSnapshot(request, operation); });
    QTRY_VERIFY_WITH_TIMEOUT(!temporarySnapshots(request.stagingDirectory).isEmpty() && !ready(future), 5000);
    QVERIFY(guard->running());
    QVERIFY(!QFileInfo::exists(request.destinationPath));
    QElapsedTimer elapsed;
    elapsed.start();
    operation->requestStop();
    QTRY_VERIFY_WITH_TIMEOUT(ready(future), MacBackupExecutor::kStopResponseBudgetMs + MacBackupExecutor::kReapBudgetMs + 1000);
    const auto result = future.get();
    QVERIFY(!result.success);
    QVERIFY(elapsed.elapsed() < MacBackupExecutor::kStopResponseBudgetMs);
    QCOMPARE(guard->killCount.load(), 0);
    QVERIFY(!executor.hasAbandonedWork());
    QVERIFY(temporarySnapshots(request.stagingDirectory).isEmpty());
    QVERIFY(!QFileInfo::exists(request.destinationPath));
}

void MacBackupExecutorTests::ignoredStopIsKilledWithinDeadline()
{
    // 不读停止消息的执行器到停止期限会被结束，父线程不再无限等待，也不误报成功。
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto readyPath = directory.filePath(QStringLiteral("ready"));
    EnvironmentValue mode("POMODORO_BACKUP_STUB_MODE", "ignore");
    EnvironmentValue marker("POMODORO_BACKUP_STUB_READY", readyPath.toUtf8());
    const auto guard = std::make_shared<GuardedProcessControl>();
    MacBackupExecutor executor(QStringLiteral(POMODORO_BACKUP_STUB_PATH), guard);
    const auto operation = std::make_shared<BackupOperationControl>();
    auto future = std::async(std::launch::async, [&] {
        return executor.stageCopy(directory.filePath(QStringLiteral("source")), directory.filePath(QStringLiteral("target")), 100, operation);
    });
    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(readyPath), 5000);
    QCOMPARE(readFile(readyPath).toLongLong(), qint64(guard->lastPid.load()));
    QVERIFY(guard->running());
    QVERIFY(!ready(future));
    QElapsedTimer elapsed;
    elapsed.start();
    operation->requestStop();
    QTRY_VERIFY_WITH_TIMEOUT(ready(future), MacBackupExecutor::kStopResponseBudgetMs + MacBackupExecutor::kReapBudgetMs + 1000);
    const auto result = future.get();
    QVERIFY(!result.success);
    QVERIFY(!result.committed);
    QVERIFY(elapsed.elapsed() >= MacBackupExecutor::kStopResponseBudgetMs);
    QVERIFY(elapsed.elapsed() < MacBackupExecutor::kStopResponseBudgetMs + MacBackupExecutor::kReapBudgetMs + 750);
    QCOMPARE(guard->killCount.load(), 1);
    QVERIFY(!executor.hasAbandonedWork());
    QVERIFY(!guard->running());
}

void MacBackupExecutorTests::unreapedExecutorMakesAbandonmentSticky_data()
{
    // 放弃时有完整结果就保留已提交事实，没有结果不能猜测提交。
    QTest::addColumn<bool>("committed");
    QTest::newRow("without-result") << false;
    QTest::newRow("with-committed-result") << true;
}

void MacBackupExecutorTests::unreapedExecutorMakesAbandonmentSticky()
{
    // 结束后仍无法确认回收的执行器使本次运行受限，后续请求不会再启动新子进程。
    QFETCH(bool, committed);
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto readyPath = directory.filePath(QStringLiteral("ready"));
    EnvironmentValue mode("POMODORO_BACKUP_STUB_MODE", committed ? "committed-hang" : "ignore");
    EnvironmentValue marker("POMODORO_BACKUP_STUB_READY", readyPath.toUtf8());
    const auto guard = std::make_shared<GuardedProcessControl>(true);
    MacBackupExecutor executor(QStringLiteral(POMODORO_BACKUP_STUB_PATH), guard);
    const auto operation = std::make_shared<BackupOperationControl>();
    auto future = std::async(std::launch::async, [&] {
        return executor.stageCopy(directory.filePath(QStringLiteral("source")), directory.filePath(QStringLiteral("target")), 100, operation);
    });
    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(readyPath), 5000);
    QVERIFY(guard->running());
    QElapsedTimer elapsed;
    elapsed.start();
    operation->requestStop();
    QTRY_VERIFY_WITH_TIMEOUT(ready(future), MacBackupExecutor::kStopResponseBudgetMs + MacBackupExecutor::kReapBudgetMs + 1000);
    const auto result = future.get();
    QVERIFY(!result.success);
    QCOMPARE(result.committed, committed);
    QVERIFY(elapsed.elapsed() >= MacBackupExecutor::kStopResponseBudgetMs + MacBackupExecutor::kReapBudgetMs);
    QVERIFY(executor.hasAbandonedWork());
    QCOMPARE(guard->killCount.load(), 1);
    QVERIFY(!executor.stageCopy(directory.filePath(QStringLiteral("again")), directory.filePath(QStringLiteral("target")), 100, {}).success);
    QVERIFY(executor.hasAbandonedWork());
    QCOMPARE(guard->spawnCount.load(), 1);
}

void MacBackupExecutorTests::incompleteAndAbnormalResultsFail_data()
{
    // 异常退出、缺失、损坏或未结束的一行结果均失败，只有完整结果能证明提交事实。
    QTest::addColumn<QByteArray>("mode");
    QTest::addColumn<bool>("committed");
    QTest::newRow("empty") << QByteArray("empty") << false;
    QTest::newRow("malformed") << QByteArray("malformed") << false;
    QTest::newRow("partial") << QByteArray("partial") << false;
    QTest::newRow("abnormal") << QByteArray("abnormal") << true;
    QTest::newRow("no-info") << QByteArray("no-info") << false;
    QTest::newRow("missing-executable") << QByteArray("missing") << false;
}

void MacBackupExecutorTests::incompleteAndAbnormalResultsFail()
{
    // 执行器失败保持目标未动，检查结果不完整时也不能向页面报告有效备份。
    QFETCH(QByteArray, mode);
    QFETCH(bool, committed);
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    EnvironmentValue environment("POMODORO_BACKUP_STUB_MODE", mode);
    const auto guard = std::make_shared<GuardedProcessControl>();
    MacBackupExecutor executor(mode == "missing" ? directory.filePath(QStringLiteral("missing"))
                                                 : QStringLiteral(POMODORO_BACKUP_STUB_PATH), guard);
    if (mode == "no-info") {
        const auto info = executor.inspectBackup(directory.filePath(QStringLiteral("source")), DatabaseManager::kCurrentSchemaVersion, {});
        QVERIFY(!info.value(QStringLiteral("valid")).toBool());
        QVERIFY(!info.value(QStringLiteral("reason")).toString().isEmpty());
    } else {
        const auto result = executor.stageCopy(directory.filePath(QStringLiteral("source")), directory.filePath(QStringLiteral("target")), 100, {});
        QVERIFY(!result.success);
        QVERIFY(!result.error.isEmpty());
        QCOMPARE(result.committed, committed);
    }
    QVERIFY(!QFileInfo::exists(directory.filePath(QStringLiteral("target"))));
    QVERIFY(!executor.hasAbandonedWork());
}

void MacBackupExecutorTests::shutdownStopsAnUnresponsiveExecutorWithinDeadline()
{
    // 应用退出遇到永不返回的隔离文件执行器，也在停止与回收期限内结束等待并释放 worker。
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QVERIFY(populateDatabase(directory.filePath(QStringLiteral("database.db")), 0));
    const auto readyPath = directory.filePath(QStringLiteral("ready"));
    EnvironmentValue mode("POMODORO_BACKUP_STUB_MODE", "ignore");
    EnvironmentValue marker("POMODORO_BACKUP_STUB_READY", readyPath.toUtf8());
    const auto guard = std::make_shared<GuardedProcessControl>();
    auto executor = std::make_shared<MacBackupExecutor>(QStringLiteral(POMODORO_BACKUP_STUB_PATH), guard);
    BackupService service;
    service.configure(directory.filePath(QStringLiteral("settings.ini")), directory.filePath(QStringLiteral("backups")));
    service.setExecutor(executor);
    service.requestBackup(directory.filePath(QStringLiteral("backup.tomatobackup")));
    QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(readyPath), 5000);
    QVERIFY(guard->running());
    QVERIFY(service.busy());
    QElapsedTimer elapsed;
    elapsed.start();
    service.prepareForShutdown();
    QVERIFY(elapsed.elapsed() < MacBackupExecutor::kStopResponseBudgetMs + MacBackupExecutor::kReapBudgetMs + 750);
    QCOMPARE(guard->killCount.load(), 1);
    QVERIFY(!guard->running());
    QVERIFY(!service.busy());
    QVERIFY(!executor->hasAbandonedWork());
}

void MacBackupExecutorTests::failuresLogOnlyStandardErrorTail_data()
{
    // 执行器失败只记录标准错误末尾的一条诊断，成功与空白诊断保持安静。
    QTest::addColumn<QByteArray>("mode");
    QTest::addColumn<bool>("abandoned");
    QTest::addColumn<bool>("success");
    QTest::addColumn<bool>("hasDiagnostic");
    QTest::newRow("abnormal-exit") << QByteArray("abnormal") << false << false << true;
    QTest::newRow("missing-result") << QByteArray("empty") << false << false << true;
    QTest::newRow("malformed-result") << QByteArray("malformed") << false << false << true;
    QTest::newRow("partial-result") << QByteArray("partial") << false << false << true;
    QTest::newRow("timeout") << QByteArray("ignore") << false << false << true;
    QTest::newRow("abandoned") << QByteArray("ignore") << true << false << true;
    QTest::newRow("success") << QByteArray("no-info") << false << true << true;
    QTest::newRow("whitespace") << QByteArray("empty") << false << false << false;
}

void MacBackupExecutorTests::failuresLogOnlyStandardErrorTail()
{
    // 标准错误超过收集上限时仍保留最后 4 KiB，不把首部、换行或内部诊断带进用户文案。
    QFETCH(QByteArray, mode);
    QFETCH(bool, abandoned);
    QFETCH(bool, success);
    QFETCH(bool, hasDiagnostic);
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QByteArray diagnostic = hasDiagnostic
        ? QByteArray("dropped-prefix:") + QByteArray(70 * 1024, 'x') + QByteArray("\n  final error \r\n")
        : QByteArray(" \r\n\t ");
    QVERIFY(!hasDiagnostic || diagnostic.size() > 64 * 1024);
    EnvironmentValue modeValue("POMODORO_BACKUP_STUB_MODE", mode);
    EnvironmentValue errorValue("POMODORO_BACKUP_STUB_STDERR", diagnostic);
    QTest::failOnWarning(QRegularExpression(QStringLiteral("备份执行器标准错误")));
    if (!success && hasDiagnostic) {
        auto tail = QString::fromUtf8(diagnostic.right(4096)).trimmed();
        tail.replace(QLatin1Char('\r'), QLatin1Char(' '));
        tail.replace(QLatin1Char('\n'), QLatin1Char(' '));
        const auto expected = QStringLiteral("备份执行器标准错误： %1").arg(tail).toUtf8();
        QTest::ignoreMessage(QtWarningMsg, expected.constData());
    }
    const auto guard = std::make_shared<GuardedProcessControl>(abandoned);
    MacBackupExecutor executor(QStringLiteral(POMODORO_BACKUP_STUB_PATH), guard);
    const auto operation = std::make_shared<BackupOperationControl>(1000);
    const auto result = executor.stageCopy(directory.filePath(QStringLiteral("source")),
                                            directory.filePath(QStringLiteral("target")), 100, operation);
    QCOMPARE(result.success, success);
    QCOMPARE(executor.hasAbandonedWork(), abandoned);
    QVERIFY(!result.error.contains(QStringLiteral("final error")));
}

void MacBackupExecutorTests::closedStandardStreamsStillReachExecutor()
{
    // 宿主标准流已关闭时，执行器仍能收请求和返回结果，不因管道复用 0–2 号而被误关。
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto source = directory.filePath(QStringLiteral("source"));
    const auto destination = directory.filePath(QStringLiteral("target"));
    const auto report = directory.filePath(QStringLiteral("probe.json"));
    QFile file(source);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write("pipe-probe"), qint64(10));
    file.close();
    // 只在独立测试宿主中关闭标准流，避免破坏 Qt Test 报告；内外两层都保留硬超时和清理。
    QProcess probe;
    const auto cleanup = qScopeGuard([&] {
        if (probe.state() != QProcess::NotRunning) {
            probe.kill();
            probe.waitForFinished(5000);
        }
    });
    probe.start(QCoreApplication::applicationFilePath(),
                {QStringLiteral("--closed-stdio-probe"), source, destination, report});
    QVERIFY(probe.waitForStarted(5000));
    QVERIFY(probe.waitForFinished(15000));
    QCOMPARE(probe.exitStatus(), QProcess::NormalExit);
    QCOMPARE(probe.exitCode(), 0);
    const auto result = QJsonDocument::fromJson(readFile(report)).object();
    QVERIFY2(result.value(QStringLiteral("success")).toBool(), qPrintable(result.value(QStringLiteral("error")).toString()));
    QCOMPARE(readFile(destination), QByteArray("pipe-probe"));
}

void MacBackupExecutorTests::measureLargeSnapshot()
{
    // 接近备份上限的本地数据库提供停止预算的实测依据，普通回归不承担大库性能测量。
    if (qgetenv("POMODORO_MEASURE_BACKUP_EXECUTOR") != "1") QSKIP("仅显式启用环境变量时测量大库");
    QTemporaryDir directory(QStringLiteral(POMODORO_BACKUP_MEASUREMENT_ROOT "/backup-measure-XXXXXX"));
    QVERIFY(directory.isValid());
    QVERIFY(populateDatabase(directory.filePath(QStringLiteral("database.db")), 450));
    const auto databaseBytes = QFileInfo(directory.filePath(QStringLiteral("database.db"))).size();
    QVERIFY(databaseBytes >= 400LL * 1024 * 1024);
    QVERIFY(databaseBytes <= 500LL * 1024 * 1024);
    const auto guard = std::make_shared<GuardedProcessControl>(false, 90);
    MacBackupExecutor executor(QStringLiteral(POMODORO_BACKUP_EXECUTOR_PATH), guard);
    auto request = makeSnapshotRequest(directory, directory.filePath(QStringLiteral("normal.tomatobackup")));
    QElapsedTimer timer;
    timer.start();
    const auto normal = executor.createSnapshot(request, {});
    const qint64 normalMs = timer.elapsed();
    QVERIFY2(normal.success, qPrintable(normal.error));
    QVERIFY(normal.committed);
    QVERIFY(QFile::remove(request.destinationPath));

    QJsonArray stoppedTimes, stagingSizes;
    qint64 maximumStopMs = 0;
    for (int trial = 0; trial < 5; ++trial) {
        request.destinationPath = directory.filePath(QStringLiteral("cancelled-%1.tomatobackup").arg(trial));
        const auto operation = std::make_shared<BackupOperationControl>();
        auto future = std::async(std::launch::async, [&] { return executor.createSnapshot(request, operation); });
        qint64 stagedBytes = 0;
        QElapsedTimer observation;
        observation.start();
        while (stagedBytes < 64LL * 1024 * 1024 && !ready(future) && observation.elapsed() < 10000) {
            const auto files = temporarySnapshots(request.stagingDirectory);
            if (!files.isEmpty()) stagedBytes = QFileInfo(QDir(request.stagingDirectory).filePath(files.first())).size();
            std::this_thread::sleep_for(1ms);
        }
        // 先确认已经实际写出至少 64 MiB 且任务仍在运行，不能把“启动前就取消”当成停止响应。
        QVERIFY(stagedBytes >= 64LL * 1024 * 1024);
        QVERIFY(!ready(future));
        QVERIFY(guard->running());
        timer.restart();
        operation->requestStop();
        QVERIFY(future.wait_for(std::chrono::milliseconds(
            MacBackupExecutor::kStopResponseBudgetMs + MacBackupExecutor::kReapBudgetMs + 1000)) == std::future_status::ready);
        const auto result = future.get();
        const qint64 stoppedMs = timer.elapsed();
        maximumStopMs = std::max(maximumStopMs, stoppedMs);
        stoppedTimes.append(stoppedMs);
        stagingSizes.append(stagedBytes);
        const QJsonObject measurement{{QStringLiteral("databaseBytes"), databaseBytes},
                                       {QStringLiteral("normalSnapshotMs"), normalMs},
                                       {QStringLiteral("stopMilliseconds"), stoppedTimes},
                                       {QStringLiteral("stagingBytesAtStop"), stagingSizes},
                                       {QStringLiteral("maximumStopMs"), maximumStopMs},
                                       {QStringLiteral("forcedKills"), guard->killCount.load()}};
        qInfo().noquote() << "T22_MEASUREMENT_JSON" << QJsonDocument(measurement).toJson(QJsonDocument::Compact);
        QVERIFY(!result.success);
        QVERIFY(!result.committed);
        QVERIFY(temporarySnapshots(request.stagingDirectory).isEmpty());
        QVERIFY(!QFileInfo::exists(request.destinationPath));
        QVERIFY(!executor.hasAbandonedWork());
        QCOMPARE(guard->killCount.load(), 0);
        QVERIFY2(stoppedMs <= 2000, "停止响应超过 2 秒，需统筹决定预算，停止继续测量");
    }
}

int main(int argc, char* argv[])
{
    QCoreApplication application(argc, argv);
    if (argc == 5 && QByteArray(argv[1]) == "--closed-stdio-probe") {
        const QString source = QString::fromLocal8Bit(argv[2]);
        const QString destination = QString::fromLocal8Bit(argv[3]);
        const QString report = QString::fromLocal8Bit(argv[4]);
        for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; ++descriptor) ::close(descriptor);
        // 内层先于外层 15 秒期限清理执行器，避免外层结束宿主后留下孙进程。
        const auto guard = std::make_shared<GuardedProcessControl>(false, 10);
        MacBackupExecutor executor(QStringLiteral(POMODORO_BACKUP_EXECUTOR_PATH), guard);
        const auto result = executor.stageCopy(source, destination, 100, std::make_shared<BackupOperationControl>(3000));
        QFile output(report);
        if (!output.open(QIODevice::WriteOnly)) return 2;
        const auto json = QJsonDocument(QJsonObject{{QStringLiteral("success"), result.success},
                                                   {QStringLiteral("error"), result.error}}).toJson(QJsonDocument::Compact);
        return output.write(json) == json.size() ? 0 : 3;
    }
    MacBackupExecutorTests tests;
    return QTest::qExec(&tests, argc, argv);
}
#include "MacBackupExecutorTests.moc"
