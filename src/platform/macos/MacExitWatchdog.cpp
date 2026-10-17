#include "MacExitWatchdog.h"

#include <QDebug>

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <utility>
#include <unistd.h>

namespace {
void reportTimeout()
{
    struct Completion {
        std::mutex mutex;
        std::condition_variable changed;
        bool finished = false;
    };
    const auto completion = std::make_shared<Completion>();
    // Qt 消息处理器、stdio 流锁甚至 stderr 的写入都可能卡住，诊断不能阻塞计时线程。
    // 日志线程只持有自己的完成状态；最多等 50 ms，随后即使未写完也必须执行强制结束。
    std::thread([completion] {
        constexpr char message[] = "MacExitWatchdog: 退出流程超过期限，强制结束进程\n";
        // 先绕过 Qt 和 stdio 锁写一份，保证消息处理器卡住时仍能留下诊断。
        ::write(STDERR_FILENO, message, sizeof(message) - 1);
        qCritical("%s", message);
        std::fflush(stderr);
        {
            std::lock_guard lock(completion->mutex);
            completion->finished = true;
        }
        completion->changed.notify_all();
    }).detach();
    std::unique_lock lock(completion->mutex);
    completion->changed.wait_for(lock, std::chrono::milliseconds(50), [&] { return completion->finished; });
}
}

MacExitWatchdog::MacExitWatchdog(ExitFunction exitFunction)
    : m_exitFunction(exitFunction ? std::move(exitFunction) : [](int code) {
        // 超时说明正常退出已经卡住，_exit 绕过全局析构及 stdio flush，避免再次等待同一把锁。
        ::_exit(code);
    })
{
}

MacExitWatchdog::~MacExitWatchdog()
{
    disarm();
}

void MacExitWatchdog::arm(std::chrono::milliseconds deadline)
{
    std::lock_guard lock(m_mutex);
    // 到期后注入的替身可能返回，此时线程仍 joinable；重复武装同样不能重新计时或再次结束。
    if (m_thread.joinable()) return;
    m_disarmed = false;
    m_thread = std::thread([this, deadline, exitFunction = m_exitFunction] {
        std::unique_lock lock(m_mutex);
        if (m_wakeup.wait_for(lock, deadline, [this] { return m_disarmed; })) return;
        // 到期决定与撤防在同一把锁下判定；决定已作出时，撤防只等待结束函数完成。
        lock.unlock();
        try {
            reportTimeout();
        } catch (...) {
            // 日志线程分配失败也不能使退出期限失效，结束进程优先于尽力记录诊断。
        }
        exitFunction(EXIT_FAILURE);
    });
}

void MacExitWatchdog::disarm()
{
    {
        std::lock_guard lock(m_mutex);
        m_disarmed = true;
    }
    m_wakeup.notify_all();
    if (m_thread.joinable()) m_thread.join();
}
