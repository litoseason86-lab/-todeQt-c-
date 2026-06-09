#ifndef TASKMANAGER_H
#define TASKMANAGER_H

#include <QDate>
#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantList>

class TaskManager : public QObject
{
    Q_OBJECT

public:
    static TaskManager* instance();

    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, const QString& category = QString());
    Q_INVOKABLE bool completeTask(int taskId);
    Q_INVOKABLE bool setTaskCompleted(int taskId, bool completed);
    Q_INVOKABLE bool deleteTask(int taskId);
    Q_INVOKABLE QVariantList getTodayTasks() const;
    Q_INVOKABLE QVariantList getTasksByDate(const QDate& date) const;

signals:
    void tasksChanged();

private:
    explicit TaskManager(QObject* parent = nullptr);
};

#endif // TASKMANAGER_H
