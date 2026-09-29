#include "ApplicationActivity.h"

#include "MonotonicClock.h"

#include <QGuiApplication>

GuiApplicationActivity::GuiApplicationActivity(const MonotonicClock* clock, QObject* parent)
    : QObject(parent)
    , m_clock(clock)
{
    // 构造时先读一次当前状态：应用可能在装配这个对象之前就已经进入活动状态，
    // 只靠状态变化信号会错过这一次，导致「从未进入前台」的误判。
    applyState(QGuiApplication::applicationState());
    connect(qGuiApp, &QGuiApplication::applicationStateChanged,
            this, &GuiApplicationActivity::applyState);
}

bool GuiApplicationActivity::isForeground() const
{
    return m_foreground;
}

qint64 GuiApplicationActivity::lastForegroundNsecs() const
{
    return m_lastForegroundNsecs;
}

void GuiApplicationActivity::applyState(Qt::ApplicationState state)
{
    const bool foreground = state == Qt::ApplicationActive;
    if (foreground == m_foreground) {
        return;
    }
    m_foreground = foreground;
    if (foreground) {
        // 记下回到前台的时刻：到点时刻早于它，说明番茄是在后台期间到期的。
        m_lastForegroundNsecs = m_clock->nowNsecs();
    } else {
        emit leftForeground();
    }
}
