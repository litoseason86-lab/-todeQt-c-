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
    // timebase 把 mach 计数单位换算成纳秒；Apple Silicon 上通常是 125/3。缓存一次即可。
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    // mach_continuous_time：单调，且包含系统休眠期间流逝的时间（对合盖/睡眠场景至关重要）。
    const uint64_t ticks = mach_continuous_time();
    return static_cast<qint64>(ticks) * timebase.numer / timebase.denom;
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
