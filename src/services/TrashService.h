#ifndef TRASHSERVICE_H
#define TRASHSERVICE_H

#include <QDateTime>
#include <QObject>
#include <QVariantMap>

// 废纸篓（计划 054）：近 30 天被用户删除的内容，列出、恢复、彻底删除、清空、过期清理。
// 写入端在 TrashStore（各服务在自己的删除事务里调用）；这里是读取与处置端。
class TrashService : public QObject
{
    Q_OBJECT

public:
    static TrashService* instance();

    // 保留期按逻辑日算：逻辑日 D 删除的，D 当天剩 30 天，D+29 剩 1 天，D+30 起到期。
    static constexpr int kRetentionDays = 30;

    // { ok, error, today, items }。读失败 ok=false 且 items 为空、不发信号，不把失败当成空废纸篓（同 MemoService::readMemos），
    // 此时也不给 today。
    // today 是逻辑今天（yyyy-MM-dd）：与每项的 remainingDays 用同一个「现在」和同一个日界点算出，
    // 页面判断「今天 / 昨天 / 是否今年」只拿它去比 deletedDate，不自己算日期（「今天」只在 C++ 里算一份）。
    // 服务只给结构化数据，不拼说明句子（同周复盘的做法）。
    // 每项的 restorable 为 false 时，blockedReason 说明原因："corrupted"（内容损坏）或 "needsUpdate"
    // （更新版本新增的类型或更高的内容格式），判定与 restoreItem 共用；能恢复时为空串。
    Q_INVOKABLE QVariantMap readItems() const;
    // 删除到期的全部项，一个事务。返回删除条数，失败返回 -1；删了才发 trashChanged。
    Q_INVOKABLE int purgeExpired();
    // 彻底删除一项，连同 origin_sync_id 相同的全部项（身份退回随机时同一原记录会有多行）。
    // { ok, error, code }；这一项已不在废纸篓里（另一台刚恢复或删掉）时 code 为 "gone"，其余失败不给 code。
    Q_INVOKABLE QVariantMap deleteItem(int trashId);
    // 清空：只删 trashIds 里的各项，连同 origin_sync_id 相同（非空）的同源行（同 deleteItem）。
    // 确认框上说的是打开那一刻列出的项；确认期间同步进来的新项不在其中，保留。
    // 已经不在的编号（另一台刚恢复或删掉）跳过，不算失败；非整数的元素同样跳过。
    // 返回 { ok, error, count }，count 是实际删掉的行数；删了才发 trashChanged。
    Q_INVOKABLE QVariantMap emptyTrash(const QVariantList& trashIds);
    // { ok, error, kind, title, conflict }；conflict 只在专注/休息撞时间时给 "focus" 或 "rest"。
    // 这一项已不在废纸篓里时只给 { ok, error, code: "gone" }，同 deleteItem。
    // 恢复出来的是新记录：同步「删除优先」，原来的身份已经作废。
    Q_INVOKABLE QVariantMap restoreItem(int trashId);

    // 只给 C++ 测试用：注入「现在」，无效值表示用真实时间。
    void setNowForTesting(const QDateTime& now) { m_nowForTesting = now; }

signals:
    // 废纸篓内容变了（放进、恢复、删除、清理、同步收到）。页面据此重读。
    void trashChanged();

private:
    explicit TrashService(QObject* parent = nullptr);
    QDateTime now() const;

    QDateTime m_nowForTesting;
};

#endif // TRASHSERVICE_H
