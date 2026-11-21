#include "MonotonicClock.h"

#include <QDateTime>

#include <mach/mach_time.h>
#include <sys/sysctl.h>

const SystemMonotonicClock* SystemMonotonicClock::instance()
{
    static SystemMonotonicClock clock;
    return &clock;
}

qint64 SystemMonotonicClock::nowNsecs() const
{
    // timebase 把 mach 计数单位换算成纳秒；Apple Silicon 上通常是 125/3。
    // C++11 静态局部初始化保证主线程与 AppleNotificationBackend GCD 线程并发读取时无数据竞争。
    static const mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t info{0, 0};
        mach_timebase_info(&info);
        return info;
    }();
    if (timebase.denom == 0) {
        return 0;
    }
    // mach_continuous_time：单调，且包含系统休眠期间流逝的时间（对合盖/睡眠场景至关重要）。
    // 使用 128 位无符号中间值避免 ticks * numer 在长时间运行后发生有符号整数溢出。
    __extension__ using UInt128 = unsigned __int128;
    const UInt128 ticks = mach_continuous_time();
    return static_cast<qint64>((ticks * timebase.numer) / timebase.denom);
}

QString SystemMonotonicClock::bootSessionId() const
{
    // UUID 文本 36 个字符，留足余量；读取失败（沙盒限制、系统不提供）时返回空串。
    char buffer[64] = {};
    size_t size = sizeof(buffer);
    if (sysctlbyname("kern.bootsessionuuid", buffer, &size, nullptr, 0) != 0 || size == 0) {
        return QString();
    }
    return QString::fromLatin1(buffer).trimmed();
}

qint64 MonotonicClock::utcNowMsecs() const
{
    return QDateTime::currentMSecsSinceEpoch();
}
