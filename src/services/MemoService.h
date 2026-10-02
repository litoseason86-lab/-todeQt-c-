#ifndef MEMOSERVICE_H
#define MEMOSERVICE_H

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class QSqlQuery;

// 备忘录只保存持续修改的纯文本，不生成任务，也不参与专注统计。
class MemoService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int maxTitleLength READ maxTitleLength CONSTANT)
    Q_PROPERTY(int maxBodyLength READ maxBodyLength CONSTANT)

public:
    static MemoService* instance();
    static constexpr int kFilterAll = -1;
    static constexpr int kMaxTitleLength = 60;
    static constexpr int kMaxBodyLength = 10000;

    int maxTitleLength() const { return kMaxTitleLength; }
    int maxBodyLength() const { return kMaxBodyLength; }

    // -1 取全部（按科目顺序分组），0 取未分类，正数取指定科目。
    Q_INVOKABLE QVariantList listMemos(int categoryId = kFilterAll) const;
    Q_INVOKABLE QVariantMap getMemo(int memoId) const;
    Q_INVOKABLE int createMemo(const QString& title, const QString& body, int categoryId = 0);
    // 只保存编辑过的字段（title / body / categoryId），以后同步修改其它字段时不会被旧编辑副本覆盖。
    Q_INVOKABLE bool updateMemo(int memoId, const QVariantMap& changes);
    Q_INVOKABLE bool deleteMemo(int memoId);
    // 必须传该科目的完整编号列表；遗漏、重复、跨科目都拒绝，整批排序在一个事务内完成。
    // 只改顺序，不改更新时间（更新时间只表示内容最后一次修改）。
    Q_INVOKABLE bool reorderMemos(int categoryId, const QVariantList& memoIds);

signals:
    void memosChanged();
    void operationFailed(const QString& message);

private:
    explicit MemoService(QObject* parent = nullptr);
    bool databaseReady() const;
    bool reportFailure(const QString& message) const;
    bool validateText(const QString& title, const QString& body) const;
    bool categoryExists(int categoryId) const;
    bool nextSortOrder(int categoryId, int* order) const;
    QVariantMap memoFromQuery(const QSqlQuery& query) const;
};

#endif // MEMOSERVICE_H
