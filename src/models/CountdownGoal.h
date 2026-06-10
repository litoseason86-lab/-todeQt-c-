#ifndef COUNTDOWNGOAL_H
#define COUNTDOWNGOAL_H

#include <QDate>
#include <QDateTime>
#include <QMetaType>
#include <QObject>
#include <QString>

class CountdownGoal
{
    Q_GADGET
    Q_PROPERTY(int id READ id)
    Q_PROPERTY(QString name READ name)
    Q_PROPERTY(QDate targetDate READ targetDate)
    Q_PROPERTY(int displayOrder READ displayOrder)
    Q_PROPERTY(QDateTime createdAt READ createdAt)
    Q_PROPERTY(QDateTime updatedAt READ updatedAt)

public:
    CountdownGoal();
    CountdownGoal(int id,
                  const QString& name,
                  const QDate& targetDate,
                  int displayOrder,
                  const QDateTime& createdAt,
                  const QDateTime& updatedAt);

    int id() const;
    QString name() const;
    QDate targetDate() const;
    int displayOrder() const;
    QDateTime createdAt() const;
    QDateTime updatedAt() const;

    void setId(int id);
    void setName(const QString& name);
    void setTargetDate(const QDate& targetDate);
    void setDisplayOrder(int displayOrder);
    void setCreatedAt(const QDateTime& createdAt);
    void setUpdatedAt(const QDateTime& updatedAt);

    int daysRemaining() const;

private:
    int m_id = -1;
    QString m_name;
    QDate m_targetDate;
    int m_displayOrder = 0;
    QDateTime m_createdAt;
    QDateTime m_updatedAt;
};

Q_DECLARE_METATYPE(CountdownGoal)

#endif // COUNTDOWNGOAL_H
