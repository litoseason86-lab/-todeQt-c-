#ifndef FOCUSSESSIONCONTROLLER_H
#define FOCUSSESSIONCONTROLLER_H

#include <QObject>
#include <QString>
#include <QVariantMap>

class AppSettings;
class FocusTimer;
class PendingDeletion;
class TaskManager;

// 专注计时的业务流程（055-P2A）：从 QML 下沉的判断与动作，Mac 页面与将来的 iPad 原生界面共用这一份，
// 界面只负责确认框、跳页、提示条文案这类展示状态，按本类返回的结果去执行。
// 返回 QVariantMap 是为了 QML 与桥接层都能直接取用。
//
// 本类不持有计时状态，每次调用都读 FocusTimer 的当下事实；所有指针不转移所有权，生命周期由装配层保证。
class FocusSessionController : public QObject
{
    Q_OBJECT

public:
    FocusSessionController(FocusTimer* timer, TaskManager* tasks, AppSettings* settings,
                           PendingDeletion* pendingDeletion, QObject* parent = nullptr);

    // 超长自由专注的提醒时长（小时）：设置值在 1–24 之间取整，否则用 8。
    Q_INVOKABLE int freeTimerWarningHours() const;
    // 有活动会话、mode == 0，且已超过提醒时长（严格大于：恰好等于阈值不弹，多一秒才弹）。
    Q_INVOKABLE bool needsLongFreeStopConfirmation() const;

    // 「结束」在所有入口同口径：按计时器的真实模式分发，不看页面本地的模式选择。
    // 返回 {result, kind, discarded, error}：
    //   result  none（没有会话且 phase == 0）/ needsConfirmation（超长自由专注，尚未结束）/ ended / failed；
    //   kind    manualRest / pomodoro / free，none 时为空串；
    //   discarded  停止过程中同步收到了 sessionDiscarded，即不足最小时长、未计入记录；
    //   error   失败文案，非 failed 时为空串。
    Q_INVOKABLE QVariantMap endCurrent();

    // 番茄页的「结束」：放弃整个番茄循环。先走 endCurrent()，结果是 ended 或 none 都把连续计数归零
    // （重复归零无害），none 转成 {ended, pomodoro}，页面照常回到起点；failed、needsConfirmation 原样返回、不归零。
    // 为什么不并进 endCurrent：番茄间的空档里（休息结束、下一轮未开始）FocusTimer 已 resetSession 回到自由模式，
    // 控制器只看计时器分不出「这是番茄页的结束」，所以要由调用方用专门的入口表明意图。
    // 只有番茄页的结束入口（FocusView.endPomodoro）用它；其它入口按计时器真实模式走 endCurrent。
    Q_INVOKABLE QVariantMap endPomodoroCycle();

    // 超长自由专注确认后的收尾，返回 {ok, error}：
    //   记录且 correctedSeconds > 0 → 按修正时长结算；记录且不修正 → 原样结算；不记录 → 丢弃。
    Q_INVOKABLE QVariantMap finishLongFree(bool recordSession, int correctedSeconds);

private:
    FocusTimer* m_timer = nullptr;
    // 后续步骤（候选任务回查、新建任务、跳过撤销窗口里的任务）才会用到这两个依赖，
    // 构造签名先按计划定下，避免之后改装配。
    [[maybe_unused]] TaskManager* m_tasks = nullptr;
    AppSettings* m_settings = nullptr;
    [[maybe_unused]] PendingDeletion* m_pendingDeletion = nullptr;
};

#endif // FOCUSSESSIONCONTROLLER_H
