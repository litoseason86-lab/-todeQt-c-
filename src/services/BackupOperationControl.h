#ifndef BACKUPOPERATIONCONTROL_H
#define BACKUPOPERATIONCONTROL_H

#include <QDeadlineTimer>
#include <QString>

#include <atomic>
#include <functional>
#include <memory>

// 单次备份链共享的协作取消状态。期限只请求停止，不承诺打断系统I/O；
// 令牌随worker存活，主线程不得因请求取消就销毁连接或解除恢复遮罩。
class BackupOperationControl
{
public:
    enum class StopReason { None, Cancelled, TimedOut, Shutdown };
    static constexpr int kDefaultBudgetMs = 120000;
    explicit BackupOperationControl(int budgetMs = kDefaultBudgetMs)
        : m_deadline(budgetMs) {}

    void requestStop(StopReason reason = StopReason::Cancelled)
    {
        StopReason expected = StopReason::None;
        m_reason.compare_exchange_strong(expected, reason);
    }
    bool stopped() const
    {
        if (m_reason.load() == StopReason::None && m_deadline.hasExpired()) {
            StopReason expected = StopReason::None;
            m_reason.compare_exchange_strong(expected, StopReason::TimedOut);
        }
        return m_reason.load() != StopReason::None;
    }
    bool checkpoint(const char* stage)
    {
        // 受控测试在工作线程的真实检查点握手，避免用固定等待猜测执行阶段。
        if (m_checkpointForTest) m_checkpointForTest(stage);
        return !stopped();
    }
    StopReason stopReason() const
    {
        stopped();
        return m_reason.load();
    }
    int remainingBudgetMs() const
    {
        // 跨进程阶段沿用同一次操作的剩余预算，不能为每次启动重新获得 120 秒。
        return static_cast<int>(m_deadline.remainingTime());
    }
    QString message() const
    {
        stopped();
        switch (m_reason.load()) {
        case StopReason::Cancelled: return QStringLiteral("备份操作已取消");
        case StopReason::TimedOut: return QStringLiteral("备份操作超过处理预算，已请求停止");
        case StopReason::Shutdown: return QStringLiteral("应用退出，备份操作已请求停止");
        case StopReason::None: return QString();
        }
        return QString();
    }
private:
    friend class BackupServiceTests;
    friend class BackupCancellationTests;
    QDeadlineTimer m_deadline;
    mutable std::atomic<StopReason> m_reason{StopReason::None};
    std::function<void(const char*)> m_checkpointForTest;
};
using BackupOperation = std::shared_ptr<BackupOperationControl>;

#endif
