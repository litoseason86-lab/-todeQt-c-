#ifndef COUNTDOWNSERVICE_H
#define COUNTDOWNSERVICE_H

#include "../models/CountdownGoal.h"
#include "../models/CountdownModel.h"

#include <QDate>
#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantMap>

class CountdownService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(CountdownModel* model READ model CONSTANT)
    Q_PROPERTY(QVariant primaryGoal READ primaryGoal NOTIFY primaryGoalChanged)

public:
    static CountdownService* instance();

    Q_INVOKABLE bool addGoal(const QString& name, const QDate& targetDate);
    Q_INVOKABLE bool updateGoal(int id, const QString& name, const QDate& targetDate);
    Q_INVOKABLE bool deleteGoal(int id);
    Q_INVOKABLE bool reorder(int fromIndex, int toIndex);
    Q_INVOKABLE int calculateDaysRemaining(const QDate& targetDate) const;

    // 列表角色与主目标横幅同步基准日的唯一入口；公开以便测试注入固定日期。
    void syncReferenceDateTo(const QDate& referenceDate);

    CountdownModel* model() const;
    QVariant primaryGoal() const;

signals:
    void primaryGoalChanged();
    void errorOccurred(const QString& message);

private:
    explicit CountdownService(QObject* parent = nullptr);

    bool ensureDatabaseReady();
    bool initializeDatabase();
    bool loadGoals();
    void updatePrimaryGoal();
    void syncReferenceDate();
    int findGoalIndexById(int id) const;
    bool validateGoalInput(const QString& name, const QDate& targetDate, QString* normalizedName);
    QVariantMap goalToVariantMap(const CountdownGoal& goal) const;

    CountdownModel* m_model = nullptr;
    QDate m_referenceDate;
    QVariantMap m_primaryGoalCache;
    bool m_databaseReady = false;
    QString m_databaseName;
};

#endif // COUNTDOWNSERVICE_H
