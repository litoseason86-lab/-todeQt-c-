#include "CountdownModel.h"

CountdownModel::CountdownModel(QObject* parent)
    : QAbstractListModel(parent)
{
}

int CountdownModel::rowCount(const QModelIndex& parent) const
{
    if (parent.isValid()) {
        return 0;
    }

    return m_goals.count();
}

QVariant CountdownModel::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_goals.count()) {
        return QVariant();
    }

    const CountdownGoal& goal = m_goals.at(index.row());
    switch (role) {
    case IdRole:
        return goal.id();
    case NameRole:
        return goal.name();
    case TargetDateRole:
        return goal.targetDate();
    case DisplayOrderRole:
        return goal.displayOrder();
    case DaysRemainingRole:
        return goal.daysRemainingFrom(m_referenceDate);
    default:
        return QVariant();
    }
}

QHash<int, QByteArray> CountdownModel::roleNames() const
{
    return {
        {IdRole, "goalId"},
        {NameRole, "name"},
        {TargetDateRole, "targetDate"},
        {DisplayOrderRole, "displayOrder"},
        {DaysRemainingRole, "daysRemaining"}
    };
}

void CountdownModel::setGoals(const QList<CountdownGoal>& goals)
{
    beginResetModel();
    m_goals = goals;
    endResetModel();
}

void CountdownModel::addGoal(const CountdownGoal& goal)
{
    const int row = m_goals.count();
    beginInsertRows(QModelIndex(), row, row);
    m_goals.append(goal);
    endInsertRows();
}

void CountdownModel::updateGoal(int index, const CountdownGoal& goal)
{
    if (index < 0 || index >= m_goals.count()) {
        return;
    }

    m_goals[index] = goal;
    const QModelIndex modelIndex = this->index(index);
    emit dataChanged(modelIndex,
                     modelIndex,
                     {IdRole, NameRole, TargetDateRole, DisplayOrderRole, DaysRemainingRole});
}

void CountdownModel::removeGoal(int index)
{
    if (index < 0 || index >= m_goals.count()) {
        return;
    }

    beginRemoveRows(QModelIndex(), index, index);
    m_goals.removeAt(index);
    endRemoveRows();
}

void CountdownModel::moveGoal(int fromIndex, int toIndex)
{
    if (fromIndex < 0 || fromIndex >= m_goals.count()
        || toIndex < 0 || toIndex >= m_goals.count()
        || fromIndex == toIndex) {
        return;
    }

    const int destinationChild = toIndex > fromIndex ? toIndex + 1 : toIndex;
    beginMoveRows(QModelIndex(), fromIndex, fromIndex, QModelIndex(), destinationChild);
    m_goals.move(fromIndex, toIndex);
    endMoveRows();
}

void CountdownModel::setReferenceDate(const QDate& referenceDate)
{
    if (m_referenceDate == referenceDate) {
        return;
    }

    m_referenceDate = referenceDate;
    if (!m_goals.isEmpty()) {
        // 基准日变化只影响剩余天数角色，不迫使 QML 重读其它字段。
        emit dataChanged(index(0), index(m_goals.count() - 1), {DaysRemainingRole});
    }
}

const QList<CountdownGoal>& CountdownModel::goals() const
{
    return m_goals;
}
