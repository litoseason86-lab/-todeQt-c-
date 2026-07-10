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
    void setReferenceDate(const QDate& referenceDate);

    const QList<CountdownGoal>& goals() const;

private:
    QList<CountdownGoal> m_goals;
    // 独立模型默认保持旧行为；服务构造后立即用逻辑今天覆盖。
    QDate m_referenceDate = QDate::currentDate();
};

#endif // COUNTDOWNMODEL_H
