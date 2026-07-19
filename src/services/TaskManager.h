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
    // 输入框 maximumLength 与服务端校验共用同一上限；QML 侧读取该常量属性。
    Q_PROPERTY(int maxTitleLength READ maxTitleLength CONSTANT)

public:
    // 任务与例行标题共用的长度上限（QChar 计数）。超长标题不损坏数据，
    // 但会撑爆列表行和导出 CSV；与 CountdownService 一样采取拒绝而非截断。
    static constexpr int kMaxTitleLength = 100;

    static TaskManager* instance();

    int maxTitleLength() const { return kMaxTitleLength; }

    // Q_INVOKABLE 表示 QML 可以直接调用这些方法。
    // 新增任务支持旧版文本科目，也支持新版 category_id 科目编号。
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, const QString& category = QString());
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, int categoryId);
    // 完成、删除和查询任务后都会通过 tasksChanged 通知界面刷新。
    Q_INVOKABLE bool completeTask(int taskId);
    Q_INVOKABLE bool setTaskCompleted(int taskId, bool completed);
    Q_INVOKABLE bool updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue);
    Q_INVOKABLE bool deleteTask(int taskId);
    // 日期查询给今日、本周和月度页面复用，返回值统一是 QML 能直接读取的列表。
    Q_INVOKABLE QVariantList getTodayTasks() const;
    Q_INVOKABLE QVariantList getTasksByDate(const QDate& date) const;
    Q_INVOKABLE QVariantList getWeekTasks(const QVariant& startDateValue) const;
    Q_INVOKABLE QVariantList getMonthTasks(int year, int month) const;
    // 结转只排除具有可信生成标记的例行任务；旧版仅按标题猜出的 routine_id 不可信。
    Q_INVOKABLE QVariantList getOverdueUncompletedTasks() const;
    Q_INVOKABLE bool moveTasksToToday(const QVariantList& taskIds);

signals:
    void tasksChanged();
    // 查询失败不能再伪装成合法空列表；页面监听该信号展示明确错误。
    void operationFailed(const QString& message);

private:
    explicit TaskManager(QObject* parent = nullptr);
    void reportFailure(const QString& message) const;
};

#endif // TASKMANAGER_H
