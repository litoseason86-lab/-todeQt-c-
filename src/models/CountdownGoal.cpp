#include "CountdownGoal.h"

CountdownGoal::CountdownGoal() = default;

CountdownGoal::CountdownGoal(int id,
                             const QString& name,
                             const QDate& targetDate,
                             int displayOrder,
                             const QDateTime& createdAt,
                             const QDateTime& updatedAt)
    : m_id(id)
    , m_name(name)
    , m_targetDate(targetDate)
    , m_displayOrder(displayOrder)
    , m_createdAt(createdAt)
    , m_updatedAt(updatedAt)
{
}

int CountdownGoal::id() const
{
    return m_id;
}

QString CountdownGoal::name() const
{
    return m_name;
}

QDate CountdownGoal::targetDate() const
{
    return m_targetDate;
}

int CountdownGoal::displayOrder() const
{
    return m_displayOrder;
}

QDateTime CountdownGoal::createdAt() const
{
    return m_createdAt;
}

QDateTime CountdownGoal::updatedAt() const
{
    return m_updatedAt;
}

void CountdownGoal::setId(int id)
{
    m_id = id;
}

void CountdownGoal::setName(const QString& name)
{
    m_name = name;
}

void CountdownGoal::setTargetDate(const QDate& targetDate)
{
    m_targetDate = targetDate;
}

void CountdownGoal::setDisplayOrder(int displayOrder)
{
    m_displayOrder = displayOrder;
}

void CountdownGoal::setCreatedAt(const QDateTime& createdAt)
{
    m_createdAt = createdAt;
}

void CountdownGoal::setUpdatedAt(const QDateTime& updatedAt)
{
    m_updatedAt = updatedAt;
}

int CountdownGoal::daysRemaining() const
{
    if (!m_targetDate.isValid()) {
        return 0;
    }

    return QDate::currentDate().daysTo(m_targetDate);
}
