#ifndef MONOTONICCLOCK_H
#define MONOTONICCLOCK_H

#include <QtGlobal>

// 专注计时的时间基准抽象：单调、包含系统休眠时间、不受用户修改系统时钟影响。
// FocusTimer 通过它读取经过时间，测试可注入 FakeClock 精确模拟休眠与时钟跳变，
// 无需真的等待或让机器睡眠。
class MonotonicClock
{
public:
    virtual ~MonotonicClock() = default;
    // 返回自某固定起点的纳秒数。要求单调递增，且**包含系统休眠期间流逝的时间**。
    virtual qint64 nowNsecs() const = 0;
};

// 生产实现：macOS mach_continuous_time()。与 QElapsedTimer(std::chrono::steady_clock)不同，
// 后者据 Qt 文档“通常不计入系统休眠时间”，会导致合盖休眠期间番茄计时停摆；
// mach_continuous_time 明确“包含系统休眠时间”，且单调、不受改系统时钟影响。
class SystemMonotonicClock : public MonotonicClock
{
public:
    static const SystemMonotonicClock* instance();
    qint64 nowNsecs() const override;
};

#endif // MONOTONICCLOCK_H
