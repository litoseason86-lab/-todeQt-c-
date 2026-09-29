#ifndef MONOTONICCLOCK_H
#define MONOTONICCLOCK_H

#include <QString>
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
    // 「起点」所属的开机会话标识。单调时钟的起点是本次开机，重启后读数从头算，
    // 所以两次读数只有在标识相同时才能相减。读不到标识时返回空串，调用方必须按
    // 「无法判断是否同一次开机」处理（移动端恢复时就不补离线时段）。
    virtual QString bootSessionId() const { return QString(); }
    // 墙钟（UTC 毫秒）。只用于核对「离开期间单调时钟与墙钟是否走了同样长」，
    // 从不用来计算专注时长——墙钟可被用户随意修改。
    virtual qint64 utcNowMsecs() const;
};

// 生产实现：macOS mach_continuous_time()。与 QElapsedTimer(std::chrono::steady_clock)不同，
// 后者据 Qt 文档“通常不计入系统休眠时间”，会导致合盖休眠期间番茄计时停摆；
// mach_continuous_time 明确“包含系统休眠时间”，且单调、不受改系统时钟影响。
class SystemMonotonicClock : public MonotonicClock
{
public:
    static const SystemMonotonicClock* instance();
    qint64 nowNsecs() const override;
    // 取 sysctl kern.bootsessionuuid。不用 kern.boottime：它由「当前时间 − 已运行时长」推算，
    // 用户改系统时间时会跟着变，拿来判断「是不是同一次开机」会误判。
    QString bootSessionId() const override;
};

#endif // MONOTONICCLOCK_H
