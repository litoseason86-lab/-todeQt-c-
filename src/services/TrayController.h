#ifndef TRAYCONTROLLER_H
#define TRAYCONTROLLER_H

#include <QObject>
#include <QString>

class FocusTimer;

// 菜单栏展示状态的完整快照。平台视图只消费这个结构，不自行读取计时器，
// 保证菜单栏永远由 FocusTimer 的当前状态单向驱动，不维护第二套计时。
struct TrayDisplay
{
    QString title;      // 菜单栏标题文字；空串表示空闲，由视图退回图标/简称
    QString taskLine;   // “当前任务：X” 或 “未选择任务”
    QString stateLine;  // “状态：专注中/休息中/已暂停/空闲”
    QString timeLine;   // “剩余：18:42” / “已专注：MM:SS” / 空
    bool canPause = false;
    bool canResume = false;
    bool canStop = false;

    bool operator==(const TrayDisplay& other) const
    {
        return title == other.title && taskLine == other.taskLine
            && stateLine == other.stateLine && timeLine == other.timeLine
            && canPause == other.canPause && canResume == other.canResume
            && canStop == other.canStop;
    }
    bool operator!=(const TrayDisplay& other) const { return !(*this == other); }
};

// 平台无关的菜单栏视图接口。macOS 用 NSStatusItem 实现；测试注入假视图记录更新。
class TrayView
{
public:
    virtual ~TrayView() = default;
    // 每次状态变化推送一次；实现只更新既有菜单栏对象的文本与启用态，不重建对象。
    virtual void updateDisplay(const TrayDisplay& display) = 0;
};

// 平台无关的菜单栏控制器：订阅 FocusTimer，计算展示状态并把菜单动作转发回计时器。
// 不含任何平台代码，可在无 macOS 依赖的测试里完整验证。
class TrayController : public QObject
{
    Q_OBJECT

public:
    explicit TrayController(FocusTimer* timer, QObject* parent = nullptr);

    // 视图不转移所有权；设置后立即推送一次当前状态，避免菜单栏首次显示为空。
    void setView(TrayView* view);
    TrayDisplay display() const;

    // 菜单动作：既被平台视图点击回调，也可被 QML/测试直接调用。
    Q_INVOKABLE void requestPause();
    Q_INVOKABLE void requestResume();
    Q_INVOKABLE void requestStop();
    Q_INVOKABLE void requestShowWindow();
    Q_INVOKABLE void requestQuit();

signals:
    void displayChanged();
    // 主窗口的显示与退出由宿主（QML/main）落实：菜单栏只发意图，不直接操作窗口或进程。
    void showWindowRequested();
    void quitRequested();

private slots:
    void refresh();

private:
    static QString formatClock(int seconds);

    FocusTimer* m_timer;
    TrayView* m_view = nullptr;
    TrayDisplay m_display;
};

#endif // TRAYCONTROLLER_H
