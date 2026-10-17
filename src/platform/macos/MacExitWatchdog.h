#ifndef MACEXITWATCHDOG_H
#define MACEXITWATCHDOG_H

#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>

// Mac 退出总期限不依赖 Qt 事件循环，主线程卡在收尾时仍能结束进程。
// arm/disarm 由装配线程串行调用；到期后的结束函数在独立线程执行，不得回调本对象。
class MacExitWatchdog
{
public:
    using ExitFunction = std::function<void(int)>;

    explicit MacExitWatchdog(ExitFunction exitFunction = {});
    ~MacExitWatchdog();

    MacExitWatchdog(const MacExitWatchdog&) = delete;
    MacExitWatchdog& operator=(const MacExitWatchdog&) = delete;

    void arm(std::chrono::milliseconds deadline);
    void disarm();

private:
    ExitFunction m_exitFunction;
    std::mutex m_mutex;
    std::condition_variable m_wakeup;
    bool m_disarmed = false;
    std::thread m_thread;
};

#endif // MACEXITWATCHDOG_H
