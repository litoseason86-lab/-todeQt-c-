#include "NotificationService.h"

#include "FocusTimer.h"

#include <QDebug>
#include <QMetaObject>
#include <QPointer>

NotificationService::NotificationService(QObject* parent)
    : QObject(parent)
{
}

NotificationService* NotificationService::instance()
{
    static NotificationService service;
    return &service;
}

void NotificationService::setBackend(NotificationBackend* backend)
{
    m_backend = backend;
}

NotificationBackend* NotificationService::backend() const
{
    return m_backend;
}

void NotificationService::requestAuthorization()
{
    if (m_backend) {
        m_backend->requestAuthorization();
    }
}

bool NotificationService::isAuthorized() const
{
    return m_backend && m_backend->isAuthorized();
}

void NotificationService::notify(const QString& title,
                                 const QString& body,
                                 bool playSound)
{
    sendNotification(title, body, playSound, false);
}

void NotificationService::sendNotification(const QString& title,
                                            const QString& body,
                                            bool playSound,
                                            bool requestFallback)
{
    if (!m_backend) {
        const QString reason = QStringLiteral("无通知后端");
        emit notificationSuppressed(reason);
        if (requestFallback) {
            emit notificationDeliveryFailed(reason);
        }
        return;
    }

    const QPointer<NotificationService> self(this);
    m_backend->deliver(
        title, body, playSound,
        [self, title, requestFallback](bool success, const QString& reason) {
            if (!self) {
                return;
            }
            // macOS 完成回调不保证位于 GUI 线程；信号统一切回服务对象线程。
            QMetaObject::invokeMethod(
                self,
                [self, title, success, reason, requestFallback]() {
                    if (!self) {
                        return;
                    }
                    if (success) {
                        emit self->notificationDelivered(title);
                    } else {
                        const QString message = reason.isEmpty()
                            ? QStringLiteral("系统通知不可用，已降级提示音")
                            : reason;
                        emit self->notificationSuppressed(message);
                        if (requestFallback) {
                            emit self->notificationDeliveryFailed(message);
                        }
                    }
                },
                Qt::AutoConnection);
        });
}

bool NotificationService::phaseCompleteContent(int phase,
                                               int completedPomodoros,
                                               int breakMinutes,
                                               bool isLongBreak,
                                               QString* title,
                                               QString* body)
{
    if (phase == FocusTimer::WorkPhase) {
        *title = QStringLiteral("专注完成");
        if (completedPomodoros > 0 && breakMinutes > 0) {
            *body = QStringLiteral("你已完成第 %1 个番茄，休息 %2 分钟。")
                        .arg(completedPomodoros).arg(breakMinutes);
        } else if (breakMinutes > 0) {
            *body = QStringLiteral("专注时间到，休息 %1 分钟。").arg(breakMinutes);
        } else {
            *body = QStringLiteral("专注时间到，休息一下。");
        }
        return true;
    }
    if (phase == FocusTimer::BreakPhase) {
        *title = isLongBreak ? QStringLiteral("长休息结束") : QStringLiteral("休息结束");
        *body = QStringLiteral("休息结束，开始下一个番茄吧。");
        return true;
    }
    // 无相位（自由计时等）不发系统通知，避免通知轰炸。
    return false;
}

void NotificationService::notifyPhaseComplete(int phase,
                                              int completedPomodoros,
                                              int breakMinutes,
                                              bool isLongBreak,
                                              bool playSound)
{
    QString title;
    QString body;
    if (!phaseCompleteContent(phase, completedPomodoros, breakMinutes, isLongBreak, &title, &body)) {
        emit notificationSuppressed(QStringLiteral("该阶段不发送系统通知"));
        return;
    }
    // 系统预约的通知就是这次提醒：它按到点时刻投递，前台时由通知中心委托展示。
    // 这里再即时投递一条，用户会在同一时刻收到两次。属于业务抑制，不触发提示音降级。
    if (m_phaseAlarmCoverage && m_phaseAlarmCoverage(phase)) {
        emit notificationSuppressed(QStringLiteral("已由预约通知覆盖"));
        return;
    }

    sendNotification(title, body, playSound, true);
}

void NotificationService::setPhaseAlarmCoverage(std::function<bool(int phase)> coverage)
{
    m_phaseAlarmCoverage = std::move(coverage);
}

namespace {
// 把系统回调排队送回服务对象线程；服务已销毁时丢弃，不回调到悬空的调用方。
NotificationBackend::ScheduleCallback queuedOn(QObject* context,
                                               NotificationBackend::ScheduleCallback callback)
{
    const QPointer<QObject> guard(context);
    return [guard, callback](bool success, const QString& reason) {
        if (!guard) {
            return;
        }
        QMetaObject::invokeMethod(
            guard.data(),
            [guard, callback, success, reason]() {
                if (guard && callback) {
                    callback(success, reason);
                }
            },
            Qt::QueuedConnection);
    };
}
}

void NotificationService::scheduleNotification(const QString& id,
                                               int fireAfterSeconds,
                                               const QString& title,
                                               const QString& body,
                                               bool playSound,
                                               NotificationBackend::ScheduleCallback callback)
{
    const auto done = queuedOn(this, std::move(callback));
    if (!m_backend) {
        done(false, QStringLiteral("无通知后端"));
        return;
    }
    m_backend->schedule(id, fireAfterSeconds, title, body, playSound, done);
}

void NotificationService::cancelScheduledNotifications(const QString& prefix,
                                                       const QString& keepId,
                                                       NotificationBackend::ScheduleCallback callback)
{
    const auto done = queuedOn(this, std::move(callback));
    if (!m_backend) {
        done(false, QStringLiteral("无通知后端"));
        return;
    }
    m_backend->cancelScheduled(prefix, keepId, done);
}
