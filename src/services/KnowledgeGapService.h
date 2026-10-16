#ifndef KNOWLEDGEGAPSERVICE_H
#define KNOWLEDGEGAPSERVICE_H

#include <QDate>
#include <QObject>
#include "ServiceReadResult.h"
#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

class QSqlQuery;

// 知识缺口：专注过程中发现、当下没条件处理、之后要专门腾出时间补的条目。
//
// 与 tasks 的分界只有一条：任务必须有日期（tasks.date 是 NOT NULL），
// 而知识缺口的常态恰恰是「现在还定不了什么时候处理」，所以 due_date 允许为空。
// 真要坐下来处理时用 convertToTask 生成一条当天任务，再从任务启动专注计时——
// 知识缺口自己不接计时、不写 focus_sessions、不进统计，专注口径一个字都不用改。
class KnowledgeGapService : public QObject
{
    Q_OBJECT
    // 输入框 maximumLength 与服务端校验共用同一上限；QML 侧读取这两个常量属性。
    Q_PROPERTY(int maxTitleLength READ maxTitleLength CONSTANT)
    Q_PROPERTY(int maxDetailLength READ maxDetailLength CONSTANT)

public:
    // 状态机：待处理 →（排期或转任务）→ 已安排 →（写下结论）→ 已解决；已解决可重新打开。
    // 「已安排」指已经有 due_date 或已经生成了任务，不是「已经在做」。
    enum Status : int {
        StatusOpen = 0,
        StatusScheduled = 1,
        StatusResolved = 2
    };
    Q_ENUM(Status)

    // listGaps 的状态筛选：传 FilterAll 表示不筛，其余与 Status 取值一一对应。
    static constexpr int kFilterAll = -1;
    // 未解决（待处理 + 已安排）。清单页的「逾期/今天/未来/未排期」分组都基于它。
    static constexpr int kFilterUnresolved = -2;

    // 标题与正文的长度上限跟任务用同一把尺子（TaskManager 的 100 / 2000）。
    // 超长不损坏数据，但会撑爆列表行，处理方式同样是拒绝而不是截断。
    static constexpr int kMaxTitleLength = 100;
    static constexpr int kMaxDetailLength = 2000;
    static constexpr int kMinPriority = 0;
    static constexpr int kMaxPriority = 2;

    static KnowledgeGapService* instance();

    int maxTitleLength() const { return kMaxTitleLength; }
    int maxDetailLength() const { return kMaxDetailLength; }

    // —— 捕获 ——
    // 零成本捕获入口：只要一个标题。专注页的快速记录走这里，不追问日期和优先级，
    // 那些之后在清单页补。捕获时打断得越少，这个功能越可能真的被用起来。
    Q_INVOKABLE int captureGap(const QString& title, int categoryId, int sourceTaskId);
    // 完整新增。dueDateValue 传空或无效值表示「未排期」，不是错误。
    Q_INVOKABLE int addGap(const QString& title,
                           int categoryId,
                           const QString& detail,
                           int priority,
                           const QVariant& dueDateValue,
                           int sourceTaskId);

    // —— 编辑与排期 ——
    Q_INVOKABLE bool updateGap(int gapId,
                               const QString& title,
                               int categoryId,
                               const QString& detail,
                               int priority,
                               const QVariant& dueDateValue);
    // 编辑弹窗只交出用户改过的字段，键为 title / categoryId / detail / priority / dueDate（空串 = 未排期）。
    // 没交的字段取库里现在的值：弹窗开着时另一台改了它们，同步写进来的新值不会被弹窗打开时的旧值盖掉。
    // 不认识的键、类型不对的值整次拒绝；没有改动时只确认条目还在。
    Q_INVOKABLE bool updateGapChanges(int gapId, const QVariantMap& changes);
    Q_INVOKABLE bool setDueDate(int gapId, const QVariant& dueDateValue);
    // 批量改期在一个事务内校验全部编号，任一条不合法就整批回滚，
    // 不留下「一半改了一半没改」的中间状态。
    Q_INVOKABLE bool moveGapsToDate(const QVariantList& gapIds, const QVariant& dueDateValue);

    // —— 状态流转 ——
    Q_INVOKABLE bool resolveGap(int gapId, const QString& resolution);
    // 重新打开保留 resolution：上次想到哪了是有价值的，清掉等于逼用户从头再来。
    Q_INVOKABLE bool reopenGap(int gapId);
    Q_INVOKABLE bool deleteGap(int gapId);

    // 生成一条当天（或指定日期）的任务并把缺口置为已安排。
    // 三件事必须在同一个事务里：只成功一半会留下指向不存在任务的缺口，
    // 或者一条没人认领、用户不知道哪来的任务。返回新任务编号，失败返回 -1。
    // 已有没做完的关联任务时拒绝，不会建出重复任务；到期日取原到期日与任务日期中较早的一个，
    // 逾期记录不会因为转任务被清零。
    Q_INVOKABLE int convertToTask(int gapId, const QVariant& dateValue);
    // 今日任务页「全部加到今天」：把今天到期和已逾期的条目一次性转成今天的任务。
    // 规则放在服务里，Mac 的今日页和 iPad 共用这一份，界面不再各自挑条目、数成败、拼原因。
    // 返回 {converted, failed, reason}：成功数、失败数、最后一条失败的原因（没有失败时 reason 是空串）。
    //   - 筛选口径：listGaps(kFilterUnresolved, …) 的结果里 dueToday 或 overdue、且不是 linkedTaskOpen 的条目。
    //     已有没做完的关联任务的条目跳过——再转只会被 convertToTask 拒绝、白算一次失败，提示条的计数也不含它们。
    //   - 「今天」用服务自己的逻辑日，调用方不传日期：判断到期和新任务落在哪天是同一个口径。
    //   - 逐条调 convertToTask，每条各自一个事务：前面成功的不会因为后面失败而撤销，部分成功照常保留。
    //     逾期条目的到期日保持原样（见 convertToTask），顺延会抹掉「这条拖了多久」。
    //   - 每条失败照旧发 operationFailed，别的监听方行为不变；reason 取转换期间最后一次播报的失败原因。
    //     读候选失败时 listGaps 同样播报并返回空，这里得到 {0, 0, 空}，页面按约定保持安静。
    Q_INVOKABLE QVariantMap convertDueGapsToTasks();

    // —— 查询 ——
    // statusFilter 取 Status、kFilterAll 或 kFilterUnresolved；categoryId <= 0 表示不筛科目。
    // 每行带 linkedTaskOpen（关联任务还在且没做完），界面据此禁用「今天做」。
    Q_INVOKABLE QVariantList listGaps(int statusFilter,
                                      int categoryId,
                                      const QString& searchText,
                                      int limit) const;
    Q_INVOKABLE QVariantMap getGap(int gapId) const;
    // 今日任务页提示条只读这一个结果，不在 QML 里算「今天」和「逾期」。
    // 返回 {dueToday, overdue, dueCount, unscheduled, openTotal, oldestOverdueDays, valid}。
    // dueToday / overdue / oldestOverdueDays 不计已有没做完关联任务的条目：它们已经由任务列表提醒。
    Q_INVOKABLE QVariantMap getReminderSummary() const;

    // 有界、无共享失败信号的读取入口，供后台调用及交互前同步重读。
    struct ReadFilter {
        int status = kFilterAll;
        int categoryId = 0;
        QString searchText;
        QString dueState;
        QDate dueFrom, dueTo;
        int afterId = 0;
        int limit = 50;
    };
    ServiceReadResult<QVariantList> readGaps(const ReadFilter& filter, const QDate& today) const;

signals:
    void gapsChanged();
    // convertToTask 新建了任务。装配层把它接到 TaskManager::tasksChanged，
    // 让任务列表刷新，而不是让本服务反向依赖 TaskManager。
    void tasksAffected();
    // 查询或写入失败不能伪装成合法空结果；页面监听该信号展示明确错误。
    void operationFailed(const QString& message);

private:
    explicit KnowledgeGapService(QObject* parent = nullptr);

    bool reportFailure(const QString& message) const;
    // 数据库是否可用。knowledge_gaps 由 DatabaseManager 的 v14 迁移建立并校验结构，
    // 本服务不自己建表，只确认连接可用。
    bool databaseReady() const;
    // 读取当前状态；gapId 不存在时返回 -1。
    int statusOf(int gapId) const;

    QVariantMap rowToVariantMap(const QSqlQuery& query, const QDate& logicalToday) const;
};

#endif // KNOWLEDGEGAPSERVICE_H
