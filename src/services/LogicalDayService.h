#ifndef LOGICALDAYSERVICE_H
#define LOGICALDAYSERVICE_H

#include <QObject>

class QTimer;

// 统一发布“逻辑今天已失效”：修改日界点设置或跨过日界点都会触发，
// 服务和已打开视图据此刷新，不各自维护独立定时器。
class LogicalDayService : public QObject
{
    Q_OBJECT

public:
    static LogicalDayService* instance();
    explicit LogicalDayService(QObject* parent = nullptr);

signals:
    void changed();

private slots:
    void onInvalidate();

private:
    void scheduleNextBoundary();

    QTimer* m_boundaryTimer = nullptr;
};

#endif // LOGICALDAYSERVICE_H
