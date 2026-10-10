#ifndef PHASECOMPLETIONNOTIFIER_H
#define PHASECOMPLETIONNOTIFIER_H

#include <QObject>
#include <functional>

class AppSettings;
class FocusTimer;
class NotificationService;

// 阶段自然完成时的即时系统通知与提示音降级（055：从 QML PhaseCompletionCoordinator 下沉）。
// Mac、iPhone/iPad 的 QML 界面和 iPad 原生界面共用这一份，由 main.cpp 在加载任何界面之前装配；
// Mac 的「到点置前窗口」属于窗口行为，仍留在 QML 协调器里。
//
// 通知文案、预约覆盖时不即时投递，都在 NotificationService 里；这里只决定这次说的是不是长休息、休息几分钟、要不要响铃，
// 以及系统通知发不出去时用本地提示音兜底（提示音由调用方注入，测试换成计数器，不链接声音后端）。
class PhaseCompletionNotifier : public QObject
{
    Q_OBJECT

public:
    using ChimePlayer = std::function<bool()>;

    // 指针不转移所有权，生命周期由装配层保证；notifications 为空时每次完成都直接走提示音兜底。
    PhaseCompletionNotifier(FocusTimer* timer, AppSettings* settings, NotificationService* notifications,
                            ChimePlayer playChime, QObject* parent = nullptr);

private:
    // 休息结束时计时器已回到空闲，读不到这段休息的目标时长，所以在进入休息段时先记下「是不是长休息」。
    void captureActiveBreakKind();
    void handlePhaseCompleted(int phase);
    void playFallbackChime();

    FocusTimer* m_timer = nullptr;
    AppSettings* m_settings = nullptr;
    NotificationService* m_notifications = nullptr;
    ChimePlayer m_playChime;
    bool m_activeBreakWasLong = false;
};

#endif // PHASECOMPLETIONNOTIFIER_H
