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

void NotificationService::notifyPhaseComplete(int phase,
                                              int completedPomodoros,
                                              int breakMinutes,
                                              bool isLongBreak,
                                              bool playSound)
{
    QString title;
    QString body;

    if (phase == FocusTimer::WorkPhase) {
        title = QStringLiteral("专注完成");
        if (completedPomodoros > 0 && breakMinutes > 0) {
            body = QStringLiteral("你已完成第 %1 个番茄，休息 %2 分钟。")
                       .arg(completedPomodoros).arg(breakMinutes);
        } else if (breakMinutes > 0) {
            body = QStringLiteral("专注时间到，休息 %1 分钟。").arg(breakMinutes);
        } else {
            body = QStringLiteral("专注时间到，休息一下。");
        }
    } else if (phase == FocusTimer::BreakPhase) {
        title = isLongBreak ? QStringLiteral("长休息结束") : QStringLiteral("休息结束");
        body = QStringLiteral("休息结束，开始下一个番茄吧。");
    } else {
        // 无相位（自由计时等）不发系统通知，避免通知轰炸。
        emit notificationSuppressed(QStringLiteral("该阶段不发送系统通知"));
        return;
    }

    sendNotification(title, body, playSound, true);
}
