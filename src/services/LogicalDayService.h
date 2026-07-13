#ifndef LOGICALDAYSERVICE_H
#define LOGICALDAYSERVICE_H

#include <QObject>
#include <QDate>
#include <QByteArray>

class QTimer;
class QEvent;

// 统一发布“逻辑今天已失效”：修改日界点设置或跨过日界点都会触发，
// 服务和已打开视图据此刷新，不各自维护独立定时器。
class LogicalDayService : public QObject
{
    Q_OBJECT

public:
    static LogicalDayService* instance();
    explicit LogicalDayService(QObject* parent = nullptr);

protected:
    bool eventFilter(QObject* watched, QEvent* event) override;

signals:
    void changed();

private slots:
    void onInvalidate();
    void checkSystemClock();

private:
    void scheduleNextBoundary();

    QTimer* m_boundaryTimer = nullptr;
    QTimer* m_clockWatchdog = nullptr;
    QDate m_lastLogicalDate;
    QByteArray m_lastTimeZoneId;
};

#endif // LOGICALDAYSERVICE_H
