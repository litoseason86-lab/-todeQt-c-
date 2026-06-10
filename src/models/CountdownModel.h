#ifndef COUNTDOWNMODEL_H
#define COUNTDOWNMODEL_H

#include "CountdownGoal.h"

#include <QAbstractListModel>
#include <QList>

class CountdownModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NameRole,
        TargetDateRole,
        DisplayOrderRole,
        DaysRemainingRole
    };
    Q_ENUM(Roles)

    explicit CountdownModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setGoals(const QList<CountdownGoal>& goals);
    void addGoal(const CountdownGoal& goal);
    void updateGoal(int index, const CountdownGoal& goal);
    void removeGoal(int index);
    void moveGoal(int fromIndex, int toIndex);

    const QList<CountdownGoal>& goals() const;

private:
    QList<CountdownGoal> m_goals;
};

#endif // COUNTDOWNMODEL_H
