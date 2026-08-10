#ifndef FOCUSHISTORYSERVICE_H
#define FOCUSHISTORYSERVICE_H

#include <QDate>
#include <QDateTime>
#include <QVariant>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

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

    // —— 手工补录 / 修改 / 删除 ——
    // 忘记开计时、中途强退、计时器绑错任务，这段时间此前永久丢失，而且连带影响
    // 统计、周复盘和长期目标。这三个接口就是那块缺失的底板。
    //
    // 补录出来的记录一律记为自由计时（mode = 0、pomodoro_completed = 0）：
    // 它确实不是一个自然到点的番茄，把它伪装成番茄会污染「有效番茄」口径。
    // 但它照常计入专注分钟，因而对任务预计用时和长期目标进度都有效——
    // 这正是补录要解决的问题。
    //
    // taskId <= 0 表示不关联任务（对应统计里的「未关联专注」）。
    // 返回新记录 id；失败返回 -1，原因见 lastError()。
    Q_INVOKABLE int addManualSession(int taskId,
                                     const QVariant& startDateTimeValue,
                                     int durationMinutes);
    Q_INVOKABLE bool updateSession(int sessionId,
                                   const QVariant& startDateTimeValue,
                                   int durationMinutes);
    Q_INVOKABLE bool deleteSession(int sessionId);

signals:
    // 手工改动后各视图需要重查；查询本身不缓存，只要有人重新拉一次就是最新的。
    void historyChanged();

private:
    explicit FocusHistoryService(QObject* parent = nullptr);

    // 补录与修改共用的校验：时长下限、不得落在未来、不得与既有记录重叠。
    // 重叠必须拦——两条覆盖同一段时间会让统计凭空多出时长，而且事后无法察觉。
    // excludeSessionId 用于修改自身时排除自己。
    bool validateManualSession(const QDateTime& startTime,
                               int durationMinutes,
                               int excludeSessionId) const;

    // whereClause 只接收本类内部条件；命名占位符允许 :shift 在 SELECT/WHERE 复用，
    // 其余外部值统一走 namedBinds，避免位置索引随 SQL 结构变化而错位。
    QVariantList querySessions(const QString& whereClause,
                               const QVariantMap& namedBinds = QVariantMap()) const;

    // 查询方法是 const，但错误信息属于“最近一次调用状态”，不改变业务数据本身。
    mutable QString m_lastError;
};

#endif // FOCUSHISTORYSERVICE_H
