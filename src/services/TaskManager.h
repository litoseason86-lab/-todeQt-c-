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

    // Q_INVOKABLE 表示 QML 可以直接调用这些方法。
    // 新增任务支持旧版文本科目，也支持新版 category_id 科目编号。
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, const QString& category = QString());
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, int categoryId);
    // 完成、删除和查询任务后都会通过 tasksChanged 通知界面刷新。
    Q_INVOKABLE bool completeTask(int taskId);
    Q_INVOKABLE bool setTaskCompleted(int taskId, bool completed);
    Q_INVOKABLE bool deleteTask(int taskId);
    // 日期查询给今日、本周和月度页面复用，返回值统一是 QML 能直接读取的列表。
    Q_INVOKABLE QVariantList getTodayTasks() const;
    Q_INVOKABLE QVariantList getTasksByDate(const QDate& date) const;
    Q_INVOKABLE QVariantList getWeekTasks(const QVariant& startDateValue) const;
    Q_INVOKABLE QVariantList getMonthTasks(int year, int month) const;

signals:
    void tasksChanged();

private:
    explicit TaskManager(QObject* parent = nullptr);
};

#endif // TASKMANAGER_H
