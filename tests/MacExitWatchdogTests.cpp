#include "platform/macos/MacExitWatchdog.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QScopeGuard>
#include <QtTest>

#include <cerrno>
#include <chrono>
#include <csignal>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <spawn.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

extern char** environ;

namespace {
using namespace std::chrono_literals;

struct ExitProbe {
    void record(int code)
    {
        std::lock_guard lock(mutex);
        ++calls;
        exitCode = code;
        calledAt = std::chrono::steady_clock::now();
        changed.notify_all();
    }

    bool waitForCalls(int expected, std::chrono::milliseconds timeout)
    {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, timeout, [&] { return calls >= expected; });
    }

    std::mutex mutex;
    std::condition_variable changed;
    int calls = 0;
    int exitCode = 0;
    std::chrono::steady_clock::time_point calledAt;
};

// 测试护栏独立于产品看门狗：断言提前返回也杀掉并回收子进程，父进程自身卡住则在 5 秒后失败退出。
class GuardedChild
{
public:
    GuardedChild(pid_t child, int standardError)
        : m_child(child), m_standardError(standardError), m_guard([this] {
            std::unique_lock lock(m_mutex);
            if (m_finished.wait_for(lock, 5s, [this] { return m_done; })) return;
            lock.unlock();
            killAndReap();
            constexpr char message[] = "退出看门狗测试超过独立硬期限，已清理子进程\n";
            ::write(STDERR_FILENO, message, sizeof(message) - 1);
            ::_exit(124);
        })
    {
    }

    ~GuardedChild()
    {
        {
            std::lock_guard lock(m_mutex);
            m_done = true;
        }
        m_finished.notify_all();
        m_guard.join();
        killAndReap();
        ::close(m_standardError);
    }

    bool reap(int* status)
    {
        std::lock_guard lock(m_mutex);
        if (::waitpid(m_child, status, WNOHANG) != m_child) return false;
        m_child = -1;
        return true;
    }

    QByteArray readStandardError() const
    {
        QByteArray result;
        char buffer[4096];
        for (;;) {
            const auto count = ::read(m_standardError, buffer, sizeof(buffer));
            if (count > 0) result.append(buffer, count);
            else if (count < 0 && errno == EINTR) continue;
            else return result;
        }
    }

private:
    void killAndReap()
    {
        std::lock_guard lock(m_mutex);
        if (m_child <= 0) return;
        ::kill(m_child, SIGKILL);
        for (int attempt = 0; attempt < 1000; ++attempt) {
            int status = 0;
            const auto result = ::waitpid(m_child, &status, WNOHANG);
            if (result == m_child || (result < 0 && errno == ECHILD)) {
                m_child = -1;
                return;
            }
            std::this_thread::sleep_for(1ms);
        }
        // 清理本身也有上限，不能让失败用例无限等在 waitpid 或线程析构里。
        ::_exit(124);
    }

    pid_t m_child;
    int m_standardError;
    std::mutex m_mutex;
    std::condition_variable m_finished;
    bool m_done = false;
    std::thread m_guard;
};

void blockedMessageHandler(QtMsgType, const QMessageLogContext&, const QString&)
{
    constexpr char entered[] = "blocked-qt-handler-entered\n";
    ::write(STDERR_FILENO, entered, sizeof(entered) - 1);
    for (;;) ::pause();
}
}

class MacExitWatchdogTests : public QObject
{
    Q_OBJECT

private slots:
    void disarmBeforeDeadlineNeverExits();
    void deadlineExitsOnceWithoutAnEventLoop();
    void destructionDisarmsAndJoins();
    void repeatedArmKeepsTheOriginalDeadlineAndExitsOnce();
    void stuckProcessExitsWithinDeadline_data();
    void stuckProcessExitsWithinDeadline();
};

// 保证正常退出在期限前撤防后，不会再被强制结束。
void MacExitWatchdogTests::disarmBeforeDeadlineNeverExits()
{
    ExitProbe probe;
    MacExitWatchdog watchdog([&](int code) { probe.record(code); });
    watchdog.arm(80ms);
    watchdog.disarm();
    // 必须观察到原期限之后，不能只检查撤防当下尚未触发的初始状态。
    QVERIFY(!probe.waitForCalls(1, 160ms));
    QCOMPARE(probe.calls, 0);
    watchdog.disarm();
}

// 保证退出卡住且事件循环不再运行时，期限后仅调用一次失败退出。
void MacExitWatchdogTests::deadlineExitsOnceWithoutAnEventLoop()
{
    ExitProbe probe;
    MacExitWatchdog watchdog([&](int code) { probe.record(code); });
    const auto started = std::chrono::steady_clock::now();
    watchdog.arm(80ms);
    // 条件变量等待不泵 Qt 事件；一秒上限为并行测试留调度余量，不放宽产品的 80 ms 期限。
    QVERIFY(probe.waitForCalls(1, 1000ms));
    QVERIFY(!probe.waitForCalls(2, 120ms));
    watchdog.disarm();
    QCOMPARE(probe.calls, 1);
    QCOMPARE(probe.exitCode, EXIT_FAILURE);
    QVERIFY(probe.calledAt - started >= 80ms);
    QVERIFY(probe.calledAt - started < 1000ms);
}

// 保证看门狗销毁时自动撤防并回收线程，销毁后不会触发结束函数。
void MacExitWatchdogTests::destructionDisarmsAndJoins()
{
    ExitProbe probe;
    {
        MacExitWatchdog watchdog([&](int code) { probe.record(code); });
        watchdog.arm(80ms);
    }
    QVERIFY(!probe.waitForCalls(1, 160ms));
    QCOMPARE(probe.calls, 0);
}

// 保证重复武装既不延长原期限，也不创建第二次强制结束。
void MacExitWatchdogTests::repeatedArmKeepsTheOriginalDeadlineAndExitsOnce()
{
    ExitProbe probe;
    MacExitWatchdog watchdog([&](int code) { probe.record(code); });
    const auto started = std::chrono::steady_clock::now();
    watchdog.arm(80ms);
    watchdog.arm(10s);
    QVERIFY(probe.waitForCalls(1, 1000ms));
    watchdog.arm(1ms);
    QVERIFY(!probe.waitForCalls(2, 120ms));
    watchdog.disarm();
    QCOMPARE(probe.calls, 1);
    QVERIFY(probe.calledAt - started >= 80ms);
    QVERIFY(probe.calledAt - started < 1000ms);
}

// 保证主线程、Qt 日志处理器或标准错误流锁卡住时，真实进程仍受退出期限约束。
void MacExitWatchdogTests::stuckProcessExitsWithinDeadline_data()
{
    QTest::addColumn<QByteArray>("mode");
    QTest::newRow("blocked-event-loop") << QByteArray("blocked-event-loop");
    QTest::newRow("blocked-qt-handler") << QByteArray("blocked-qt-handler");
    QTest::newRow("locked-stderr") << QByteArray("locked-stderr");
}

// 保证卡住的真实子进程在期限后以失败码退出，并留下绕过 Qt 日志锁的标准错误诊断。
void MacExitWatchdogTests::stuckProcessExitsWithinDeadline()
{
    QFETCH(QByteArray, mode);
    int errorPipe[2] = {-1, -1};
    QVERIFY(::pipe(errorPipe) == 0);
    const auto closePipe = qScopeGuard([&] {
        for (const int descriptor : errorPipe) {
            if (descriptor >= 0) ::close(descriptor);
        }
    });
    const int flags = ::fcntl(errorPipe[0], F_GETFL);
    QVERIFY(flags >= 0);
    QVERIFY(::fcntl(errorPipe[0], F_SETFL, flags | O_NONBLOCK) == 0);

    posix_spawn_file_actions_t actions;
    QCOMPARE(::posix_spawn_file_actions_init(&actions), 0);
    const auto destroyActions = qScopeGuard([&] { ::posix_spawn_file_actions_destroy(&actions); });
    QCOMPARE(::posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO), 0);
    // 只关闭额外管道描述符，不能在父进程标准流关闭时误关子进程刚重定向的 stderr。
    for (const int descriptor : errorPipe) {
        if (descriptor > STDERR_FILENO) {
            QCOMPARE(::posix_spawn_file_actions_addclose(&actions, descriptor), 0);
        }
    }
    QByteArray executable = QFile::encodeName(QCoreApplication::applicationFilePath());
    QByteArray probeArgument("--exit-watchdog-probe");
    char* arguments[] = {executable.data(), probeArgument.data(), mode.data(), nullptr};
    pid_t child = -1;
    QElapsedTimer elapsed;
    elapsed.start();
    const int spawned = ::posix_spawn(&child, executable.constData(), &actions, nullptr, arguments, environ);
    QVERIFY2(spawned == 0, std::strerror(spawned));
    GuardedChild guard(child, errorPipe[0]);
    errorPipe[0] = -1;
    ::close(errorPipe[1]);
    errorPipe[1] = -1;

    bool exited = false;
    int status = 0;
    QByteArray standardError;
    // 200 ms 产品期限之外给启动和并行调度 2 秒余量；独立护栏不参与成功判断。
    while (elapsed.elapsed() < 2200) {
        standardError += guard.readStandardError();
        if (guard.reap(&status)) {
            exited = true;
            break;
        }
        std::this_thread::sleep_for(2ms);
    }
    standardError += guard.readStandardError();
    QVERIFY2(exited, standardError.constData());
    QVERIFY(WIFEXITED(status));
    QCOMPARE(WEXITSTATUS(status), EXIT_FAILURE);
    QVERIFY(elapsed.elapsed() >= 200);
    QVERIFY(elapsed.elapsed() < 2200);
    QVERIFY2(standardError.contains("MacExitWatchdog: 退出流程超过期限，强制结束进程"), standardError.constData());
    if (mode == "blocked-qt-handler") {
        QVERIFY2(standardError.contains("blocked-qt-handler-entered"), standardError.constData());
    }
}

int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    if (argc == 3 && std::strcmp(argv[1], "--exit-watchdog-probe") == 0) {
        // 子进程故意不启动 Qt 事件循环；特殊模式再阻塞日志路径，不能让诊断拖住强制结束。
        if (std::strcmp(argv[2], "blocked-qt-handler") == 0) qInstallMessageHandler(blockedMessageHandler);
        if (std::strcmp(argv[2], "locked-stderr") == 0) ::flockfile(stderr);
        MacExitWatchdog watchdog;
        watchdog.arm(200ms);
        for (;;) ::pause();
    }
    MacExitWatchdogTests tests;
    return QTest::qExec(&tests, argc, argv);
}

#include "MacExitWatchdogTests.moc"
