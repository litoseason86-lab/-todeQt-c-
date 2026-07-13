#ifndef ROUTINEMANAGER_H
#define ROUTINEMANAGER_H

#include <QObject>
#include <QString>
#include <QVariantList>

class RoutineManager : public QObject
{
    Q_OBJECT

public:
    static RoutineManager* instance();

    // 例行项的增删改查，供「每日例行」管理弹窗使用。categoryId <= 0 表示不设科目。
    Q_INVOKABLE bool addRoutine(const QString& title, int categoryId);
    Q_INVOKABLE bool updateRoutine(int id, const QString& title, int categoryId);
    Q_INVOKABLE bool deleteRoutine(int id);
    Q_INVOKABLE bool setRoutineActive(int id, bool active);
    Q_INVOKABLE QVariantList getRoutines() const;

    // 生成「今天」的例行任务行：幂等、删不复活、不补历史（Task 3 实现）。
    Q_INVOKABLE int materializeToday();

signals:
    void routinesChanged();
    void operationFailed(const QString& message);

private:
    explicit RoutineManager(QObject* parent = nullptr);
    void reportFailure(const QString& message) const;
};

#endif // ROUTINEMANAGER_H
