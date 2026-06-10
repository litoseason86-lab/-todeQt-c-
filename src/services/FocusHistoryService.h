#ifndef FOCUSHISTORYSERVICE_H
#define FOCUSHISTORYSERVICE_H

#include <QDate>
#include <QObject>
#include <QString>
#include <QVariantList>

class FocusHistoryService : public QObject
{
    Q_OBJECT

public:
    static FocusHistoryService* instance();

    // 返回给 QML 的列表项固定包含 id/taskId/taskTitle/startTime/endTime/durationSeconds/date。
    Q_INVOKABLE QVariantList getMonthSessions(int year, int month) const;
    Q_INVOKABLE QVariantList getDaySessions(const QDate& date) const;
    Q_INVOKABLE int getDayTotalDuration(const QDate& date) const;
    Q_INVOKABLE QString formatDuration(int seconds) const;
    Q_INVOKABLE QString lastError() const;
    Q_INVOKABLE int invalidSessionCount() const;
    Q_INVOKABLE int cleanupInvalidSessions();

private:
    explicit FocusHistoryService(QObject* parent = nullptr);

    // whereClause 只接收本类内部拼出的条件；外部值必须走 bindValues，避免 SQL 拼接污染。
    QVariantList querySessions(const QString& whereClause,
                               const QVariantList& bindValues = QVariantList()) const;

    // 查询方法是 const，但错误信息属于“最近一次调用状态”，不改变业务数据本身。
    mutable QString m_lastError;
};

#endif // FOCUSHISTORYSERVICE_H
