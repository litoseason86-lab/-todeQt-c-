#include "MonotonicClock.h"

#include <mach/mach_time.h>

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
