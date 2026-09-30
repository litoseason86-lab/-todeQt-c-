#ifndef SYNCSTORE_H
#define SYNCSTORE_H

#include "SyncRecord.h"

#include <QHash>
#include <QList>
#include <QSet>
#include <QSqlDatabase>
#include <QString>

// 设备间同步的本地数据层（050 阶段 2）：只和数据库打交道，不关心改动怎么在设备之间传递。
// 读出本机待发送的改动、确认已经发出，以及把对方的一批改动合并进本机库，都在这里。
//
// 合并规则（计划 050「合并规则」一节）：
// - 按字段比较版本，新的赢；两边改的是不同字段就都保留。
// - 删除优先：删除记录永远赢，之后收到的修改一律忽略并记日志。例外是例行的「收回」：
//   之后重新生成的实例可以取代它（见 SyncSchema 里 reclaim 的说明）。
// - 绝不因为一条数据让整批失败：每条记录各自一个保存点，失败只回滚这一条、记日志、继续下一条。
// - 引用的目标已被删除，按本机删除该目标时的做法处理（任务的科目置空并清掉科目名，专注记录的任务置空……）。
class SyncStore
{
public:
    // connectionName 为空时用应用主连接（DatabaseManager）；测试用它同时打开两台「设备」的库。
    explicit SyncStore(const QString& connectionName = QString());

    QString deviceId() const;
    qint64 epoch() const;

    // 本机待发送的改动，按表的依赖顺序（科目 → 例行 → 任务 → 专注 → 休息）、同表内按改动先后排列。
    SyncBatch collectPending() const;
    // 这批改动已经写进同步文件：队列里期间没再改过的记录出队，字段的「待发送」标记清掉。
    // 期间又改过的保留，并把 base 更新成刚发出的那一版（对方马上就会见到它）。
    bool acknowledge(const SyncBatch& batch);

    struct ApplyResult {
        bool ok = false;
        QString error;
        // 本批真的改动了哪些表，界面据此只刷新变了的模型，不整库重载。
        QSet<QString> changedTables;
        // 本机因远端删除而删掉的任务编号：提交成功后逐个发 taskDeleted，计时器据此解绑。
        QList<int> deletedTaskIds;
        // 本批改变了的设置项（键 → 新值），由调用方写回 AppSettings。
        QHash<QString, QString> changedSettings;
        int conflictsLogged = 0;
        int skippedRecords = 0;
    };
    // 在一个事务里应用对方的一批改动。纪元与本机不同的批次整批拒绝：
    // 纪元更高要走快照替换（全局回滚），更低的是回滚之前的旧改动，不能再合进来。
    ApplyResult applyRemote(const SyncBatch& batch);

private:
    QSqlDatabase database() const;

    QString m_connectionName;
};

#endif // SYNCSTORE_H
