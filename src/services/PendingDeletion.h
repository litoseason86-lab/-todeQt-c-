#ifndef PENDINGDELETION_H
#define PENDINGDELETION_H

#include <QObject>
#include <QString>
#include <QTimer>

class FocusHistoryService;
class TaskManager;

// 单槽「撤销删除」：用户删除一条任务，或一条专注/休息记录之后，先不碰数据库，
// 留出一段撤销窗口，窗口走完（或被提前提交）才真正删除。Mac 的主窗口与将来的 iPad 原生界面共用这一份，
// 界面只管撤销条：收到 retired() 收起属于这次删除的那一条，收到 commitFailed() 提示失败。
//
// 单槽：只保护最近一次删除。新的删除到来时上一条先真正落库，撤销窗口里永远只有一条。
// 槽里是任务还是专注/休息记录互斥：taskId 与 sessionId 至多一个大于 0。
//
// 窗口内数据库没有被碰过，各页靠 taskId / sessionId 把那一行暂时隐藏；撤销（cancel）就是什么都不做、
// 清掉槽，那一行自然回来，专注记录与任务的关联也不会提前丢失。
//
// 信号：
//   - changed()：槽的任何内容变了（taskId、sessionId、sessionIsRest、title、active 共用这一个通知）。
//   - retired()：这次删除的撤销窗口已经失效，界面应收起属于这次删除的撤销条。两种情况会发：
//     马上要触库提交（不论成败），或待删任务被别处先删掉了。用户自己撤销（cancel）不发——撤销条是他自己点掉的。
//   - commitFailed(title)：提交触库失败。发出时槽已经清空（隐藏的那一行回来），title 是待删项的标题，
//     界面据此提示「删除「title」失败」。
//   - delayMsChanged()：撤销窗口的时长变了。
//
// 提交（commit）的顺序是有意排的：
//   1. 先发 retired()，再触库。删除一旦触库就不能撤销了；补录、备份、恢复、关窗等路径会提前提交，
//      这时撤销条可能还在剩余的几秒里挂着，用户点「撤销」，提示条照常消失，看起来像撤销成功，
//      记录却已经永久删除。所以不论成败，先收起属于这次删除的撤销条。
//   2. 触库之后才清槽：触库期间各页继续隐藏那一行，不会先闪出来再消失；
//      失败时清槽就是让任务重新出现，不能把数据库失败伪装成「已删除」。
//
// 待删任务被别处先删掉就退场：删除、停用每日例行会顺带收回今天那条还没动过的实例，外部 AI 接入也能删任务。
// 这时既没有东西可提交，也没有东西可撤销。不清掉单槽的话，窗口到期再删一次必然失败，弹出一条假的
// 「删除失败」；撤销条留着，也会让用户以为还能把任务找回来。TaskManager::taskDeleted 只在删除提交之后才发出，
// 按它退场不需要再去查询任务是否还在。自己提交时 deleteTask 也会同步发 taskDeleted，靠提交中标志忽略，
// 否则 retired() 会发两次。专注/休息记录被别处删掉的情况目前没有处理，保持原样。
//
// 调用方约定：
//   - 备份、恢复、退出、补录或修改专注记录之前先 commit()，返回 false 就不要继续：
//     窗口内记录仍在库里，不先落库就写入，会撞上用户已经看不见的那条记录的时间段。
//   - 新的提示要顶掉撤销条时，由界面先 commit()：撤销入口看不见了，就不该让倒计时在背后走完。
//   - 恢复备份会整体替换数据库，旧库的编号不能再用，界面此时调用 cancel() 丢掉待删项。
//   - 应用退出时装配层会再 commit() 一次兜底（见 main.cpp）；失败时已经拦不住退出，只留日志。
class PendingDeletion : public QObject
{
    Q_OBJECT
    // 槽里是任务时 taskId 大于 0，否则 -1；sessionId 同理。两者都不大于 0 就是没有待删项。
    Q_PROPERTY(int taskId READ taskId NOTIFY changed)
    Q_PROPERTY(int sessionId READ sessionId NOTIFY changed)
    Q_PROPERTY(bool sessionIsRest READ sessionIsRest NOTIFY changed)
    Q_PROPERTY(QString title READ title NOTIFY changed)
    Q_PROPERTY(bool active READ active NOTIFY changed)
    // 撤销窗口时长（毫秒），默认 5000。小于等于 0 的值忽略；改它只影响下一次请求，不重启进行中的计时。
    Q_PROPERTY(int delayMs READ delayMs WRITE setDelayMs NOTIFY delayMsChanged)

public:
    PendingDeletion(TaskManager* tasks, FocusHistoryService* history, QObject* parent = nullptr);

    int taskId() const { return m_taskId; }
    int sessionId() const { return m_sessionId; }
    bool sessionIsRest() const { return m_sessionIsRest; }
    QString title() const { return m_title; }
    bool active() const { return m_taskId > 0 || m_sessionId > 0; }
    int delayMs() const { return m_delayMs; }
    void setDelayMs(int delayMs);
    // 读屏开启时暂停自动提交计时，避免提示条未读完但待删项已自动落库导致撤销失效。
    // 默认不暂停；解除后使用请求时长；显式提交规则不变。
    // 开启期间新请求也保持暂停，显式 commit/cancel 语义不变。
    Q_INVOKABLE void setAutomaticCommitSuspended(bool suspended);

    // 请求删除一条任务/一条专注或休息记录（isRest 为真是休息记录）。
    // 编号不大于 0 直接返回 false，不改任何状态、不发信号。
    // 槽里已有待删项时先 commit() 它，失败就返回 false，新请求不进槽（那次失败已经发过 retired、commitFailed）。
    // 成功则写入槽，按 delayMs 启动计时，发 changed()，返回 true。
    Q_INVOKABLE bool requestTask(int taskId, const QString& title);
    Q_INVOKABLE bool requestSession(int sessionId, const QString& title, bool isRest);
    // 立即提交待删项：没有待删项返回 true；提交失败返回 false，槽照样已经清空。
    Q_INVOKABLE bool commit();
    // 撤销：停计时，有待删项就清槽。不碰数据库，不发 retired()。
    Q_INVOKABLE void cancel();

signals:
    void changed();
    void delayMsChanged();
    void retired();
    void commitFailed(const QString& title);

private:
    void handleTaskDeleted(int taskId);
    void clearSlot();

    TaskManager* m_tasks = nullptr;
    FocusHistoryService* m_history = nullptr;
    QTimer m_timer;
    int m_taskId = -1;
    int m_sessionId = -1;
    bool m_sessionIsRest = false;
    QString m_title;
    int m_delayMs = 5000;
    bool m_automaticCommitSuspended = false;
    int m_activeDelayMs = 5000;
    // 正在自己的 commit() 里触库：deleteTask 会同步发 taskDeleted，那一发要忽略。
    bool m_committing = false;
};

#endif // PENDINGDELETION_H
