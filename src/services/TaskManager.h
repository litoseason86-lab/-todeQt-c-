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
    // 预估番茄数上限；输入控件与服务端校验共用，QML 读取该常量属性。
    Q_PROPERTY(int maxEstimatedMinutes READ maxEstimatedMinutes CONSTANT)

public:
    enum class TargetCompletionResult {
        NotReached,
        Completed,
        Failed
    };

    // 任务与例行标题共用的长度上限（QChar 计数）。超长标题不损坏数据，
    // 但会撑爆列表行和导出 CSV；与 CountdownService 一样采取拒绝而非截断。
    static constexpr int kMaxTitleLength = 100;
    // 预估番茄数取值范围 [0, 99]，0 表示未设置。越界一律夹紧而非拒绝，
    // 避免界面因一个预估值填错就无法保存任务本体。
    // 预计用时上限 24 小时，与「今日专注目标」同一上界；0 表示未设置。
    static constexpr int kMaxEstimatedMinutes = 24 * 60;

    static TaskManager* instance();

    int maxTitleLength() const { return kMaxTitleLength; }
    int maxEstimatedMinutes() const { return kMaxEstimatedMinutes; }

    // Q_INVOKABLE 表示 QML 可以直接调用这些方法。
    // 新增任务支持旧版文本科目，也支持新版 category_id 科目编号。
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, const QString& category = QString());
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, int categoryId);
    // 带预估番茄数的新增重载；QML 按参数个数选择，不依赖默认参数。
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, int categoryId, int estimatedMinutes);
    Q_INVOKABLE bool addTask(const QString& title, const QVariant& dateValue, int categoryId,
                             int estimatedMinutes, const QString& notes);
    // 完成、删除和查询任务后都会通过 tasksChanged 通知界面刷新。
    Q_INVOKABLE bool completeTask(int taskId);
    Q_INVOKABLE bool setTaskCompleted(int taskId, bool completed);
    // 只在一颗有效番茄刚入账后调用；用单条 SQL 按实际数恰好等于计划数完成任务，避免检查与更新之间漂移。
    // 本次会话结束后，若累计专注时长刚跨过任务的预计用时就自动完成它。
    //
    // 必须传入本次会话的时长：判据是「这一次把总时长推过了门槛」，而不是「总时长已超」。
    // 后者会让用户重新打开一个已超额的任务后，下一次专注立刻又被强行完成——
    // 这正是改成分钟之前那条「精确相等」写法在守的性质，换成分钟后精确相等不再可行。
    TargetCompletionResult completeTaskIfEstimateReached(int taskId, int justCompletedSeconds);
    // 四参重载只改标题/科目/日期，保留原预估值（重命名走这里）；五参重载额外更新预估番茄数。
    Q_INVOKABLE bool updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue);
    Q_INVOKABLE bool updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue, int estimatedMinutes);
    Q_INVOKABLE bool updateTask(int taskId, const QString& title, int categoryId,
                                const QVariant& dateValue, int estimatedMinutes,
                                const QString& notes);

    // —— 手动排序与改期 ——
    // 同一天里的任务此前只能按创建时间排，十几条并列时无法表达"先做哪个"。
    // orderedTaskIds 是该日期下任务从上到下的完整顺序；服务按数组下标写
    // display_order（从 1 开始，0 保留给"没排过"）。
    Q_INVOKABLE bool reorderTasks(const QVariant& dateValue, const QVariantList& orderedTaskIds);
    // 改期。编辑弹窗此前只有今天/明天/后天三个按钮，最远只能挪两天；
    // 周计划里整块前后挪需要任意日期。
    Q_INVOKABLE bool moveTaskToDate(int taskId, const QVariant& dateValue);

    static constexpr int kMaxNotesLength = 2000;
    Q_INVOKABLE bool deleteTask(int taskId);
    // 删除撤销 UI 用来区分“例行生成的当日实例”与普通任务：删除实例只影响今天，
    // 例行规则本身在 routines 表中不受影响。据此给出更准确的撤销提示。
    Q_INVOKABLE bool isRoutineGeneratedTask(int taskId) const;
    // 单任务实际番茄/专注分钟聚合接口，供需要即时读取的调用方；有效口径与列表聚合完全一致。
    Q_INVOKABLE int getCompletedPomodorosForTask(int taskId) const;
    Q_INVOKABLE int getFocusedMinutesForTask(int taskId) const;
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
    // 仅在删除事务提交后发出。计时器等持有任务 ID 的服务据此解绑，避免通过查询猜测删除结果。
    void taskDeleted(int taskId);
    // 查询失败不能再伪装成合法空列表；页面监听该信号展示明确错误。
    void operationFailed(const QString& message);

private:
    explicit TaskManager(QObject* parent = nullptr);
    void reportFailure(const QString& message) const;
};

#endif // TASKMANAGER_H
