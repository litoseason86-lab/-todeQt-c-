#ifndef APPLICATIONACTIVITY_H
#define APPLICATIONACTIVITY_H

#include <QObject>
#include <QtGlobal>

class MonotonicClock;

// 应用前后台状态的只读视图。FocusTimer 用它判断「番茄是不是在后台到期的」：
// iOS 会在应用进入后台后很快挂起进程，到点那一刻计时器根本没机会运行，
// 要等回到前台或重新启动才处理。这种到期只能做离线结算，不能当成眼前刚完成——
// 否则会自动开始休息、再弹一次提醒，把用户不在场时发生的事当成现在发生的。
// 测试注入假实现即可精确模拟前后台切换，不依赖真实的窗口系统。
class ApplicationActivity
{
public:
    virtual ~ApplicationActivity() = default;
    // 此刻是否在前台且处于活动状态。锁屏、切到其它应用、下拉控制中心都算不在前台。
    virtual bool isForeground() const = 0;
    // 最近一次回到前台时的单调时钟读数（纳秒，与 FocusTimer 用的时钟同源）；从未进入前台返回 -1。
    virtual qint64 lastForegroundNsecs() const = 0;
};

// 生产实现：跟随 QGuiApplication::applicationStateChanged。
// 只有 Qt::ApplicationActive 算前台：非活动状态（锁屏过程、系统弹窗遮挡）下
// 到点的番茄同样按离线结算，宁可少一次自动衔接，也不在用户看不见时开始下一段。
class GuiApplicationActivity : public QObject, public ApplicationActivity
{
    Q_OBJECT

public:
    explicit GuiApplicationActivity(const MonotonicClock* clock, QObject* parent = nullptr);

    bool isForeground() const override;
    qint64 lastForegroundNsecs() const override;

signals:
    // 从前台离开时发出；装配层据此让计时器补写一次检查点。
    void leftForeground();

private:
    void applyState(Qt::ApplicationState state);

    const MonotonicClock* m_clock;
    bool m_foreground = false;
    qint64 m_lastForegroundNsecs = -1;
};

#endif // APPLICATIONACTIVITY_H
