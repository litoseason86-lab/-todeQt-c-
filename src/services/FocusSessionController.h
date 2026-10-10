#ifndef FOCUSSESSIONCONTROLLER_H
#define FOCUSSESSIONCONTROLLER_H

#include <QDateTime>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <functional>

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

    // 规则 2：任务入口（今日、仪表盘、本周）的「开始专注」怎么分流。返回 {kind, usePomodoro, autoStart, title}，
    // title 是 trim 后的标题。kind：
    //   invalid          编号 <= 0 或标题为空（界面提示「任务信息无效，无法开始计时」）；
    //   returnToCurrent  计时中且正是这个任务：只回到当前计时，不看记住的模式（那是「下一次」的偏好）；
    //   confirmSwitch    有活动会话或 phase != 0：要先确认结束当前计时；
    //   apply            空闲：直接落到本页。
    // usePomodoro = 记住的模式是番茄，或平台不开放自由计时；autoStart = 设置里的「快速开始」。
    Q_INVOKABLE QVariantMap planTaskEntry(int taskId, const QString& title) const;

    // 规则 6：计时中切换模式或任务，被截断的东西会怎样。返回 {kind, minimumMinutes}：
    //   restKept   休息段（phase 2/3），休息记录会保留；
    //   notSaved   已用秒数 < 最小有效时长，专注不会保存；
    //   saved      其余，专注会先保存。
    // 文案留在界面。
    Q_INVOKABLE QVariantMap switchConsequence() const;

    // 打开切换确认框时记下 {taskId, mode, phase}；用户点确认时把它交给 stopForSwitch。
    Q_INVOKABLE QVariantMap captureSwitchSource() const;
    // 确认期间计时可能自然结束或换了段，不能把确认误用到刚自动启动的下一段。依次判断：
    //   stateChanged               计时器的 taskId / mode / phase 与记下的不一致（不停表）；
    //   needsLongFreeConfirmation  超长自由专注，要先走超长确认（不停表）；
    //   stopFailed                 stopFocus 失败（计时保持原样）；
    //   stopped                    已停下，界面可以落到新任务 / 新模式。
    Q_INVOKABLE QString stopForSwitch(const QVariantMap& source);

    // 页签切换模式（番茄 / 自由）时是否要先确认：计时器忙且有可继承的任务时返回
    // {kind: "confirmSwitch", taskId, title}（这条路不自动开始）；其余 {kind: "pageOnly"}，由界面只换页签。
    // 可继承的任务：计时器有当前任务就用它，否则用界面选中的。「要切的模式就是当前页签」属于页面状态，不在这里判。
    Q_INVOKABLE QVariantMap planModeSwitch(int selectedTaskId, const QString& selectedTitle) const;

    // 规则 5：快捷键 / 全局热键「开始专注」自动挑哪条任务。返回 {id, title, selectionStale}，没有候选时 id 为 -1。
    // 依次判断：
    //   1. 界面选中项有效（编号 > 0、标题 trim 后非空）且按编号回查确实存在：用它（用户刚点过某条，不该被换掉）；
    //   2. 选中项回查不到（在别处被删了）：selectionStale = true，界面据此清掉选中，然后继续往下；
    //   3. 逻辑今日第一个未完成任务（顺序同今日页：未完成在前、display_order 升序），
    //      跳过撤销窗口里的那条（窗口内它仍在库里，对它开始计时会在窗口结束后变成「未关联」）。
    // 候选范围只是逻辑今日，不会挑到别的日期的任务。
    Q_INVOKABLE QVariantMap autoStartCandidate(int selectedTaskId, const QString& selectedTitle) const;

    // 规则 8：选择器里新建今日任务。标题 trim 后为空返回 -1，否则按逻辑今日建任务并返回新编号，失败返回 -1。
    // 编号来自 createTask 的返回值，不按标题反查：同一天允许同名任务，反查会绑到别人头上。
    Q_INVOKABLE int createTodayTask(const QString& title);

    // 规则 3：用户在今日 / 仪表盘 / 本周页亲手完成了任务，写库已成功。返回 {focusResult, kind, discarded, error}：
    // 只在「有活动会话且正在计时的就是这个任务」时调 endCurrent()，把它的 result 作为 focusResult
    // （ended / failed / needsConfirmation），kind、discarded、error 原样带回；其余一律 focusResult = none：
    // 已完成的任务允许再练一轮，那种计时不能被完成动作打断；番茄休息段没有会话（hasActiveSession 为假），休息照常进行。
    // needsConfirmation 是超长自由专注，尚未结束，由界面切到专注页弹确认。
    Q_INVOKABLE QVariantMap handleTaskCompleted(int taskId);

    // 长休息：每完成 N 个番茄，这一次休息更久。连续完成数由 FocusTimer 维护（只计自然到点的番茄）；
    // 开着长休息、连续数大于 0 且是间隔的整数倍时返回长休息分钟，其余返回页面当前选的 selectedBreakMinutes。
    // 手动与自动开始休息共用这一判定。
    Q_INVOKABLE int nextBreakMinutes(int selectedBreakMinutes) const;
    // 阶段自然完成后要不要自动衔接下一段：工作段（phase 1）看「自动开始休息」，休息段（phase 2）看「自动开始下一个番茄」，
    // 其它阶段一律不衔接。界面延迟到点时要再问一次：等待期间用户可能关掉了开关。
    Q_INVOKABLE bool autoAdvanceAfter(int completedPhase) const;

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
    // 逻辑今日的「现在」。默认取系统时钟；测试经友元注入固定时刻，才能稳定构造「自然日与逻辑日不同」的凌晨场景。
    friend class FocusSessionControllerTests;
    std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTime(); };
    QDate logicalToday() const;

    TaskManager* m_tasks = nullptr;
    AppSettings* m_settings = nullptr;
    PendingDeletion* m_pendingDeletion = nullptr;
};

#endif // FOCUSSESSIONCONTROLLER_H
