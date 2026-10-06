#include "MemoService.h"

#include "DatabaseManager.h"
#include "TrashStore.h"

#include <QDateTime>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QSet>
#include <QMap>

#include <limits>

namespace {
const QString kSelect = QStringLiteral(
    "SELECT m.id, m.title, m.body, m.category_id, c.name, c.color, m.sort_order, "
    "m.created_at, m.updated_at FROM memos m LEFT JOIN categories c ON c.id = m.category_id ");

QVariant categoryValue(int categoryId)
{
    return categoryId > 0 ? QVariant(categoryId) : QVariant(QMetaType(QMetaType::Int));
}

QString storedText(const QString& value)
{
    // 默认构造的 QString 绑定成 SQL NULL；空白草稿是合法的，必须绑定成真正的空串。
    return value.isNull() ? QStringLiteral("") : value;
}

QString timestamp()
{
    // 用带时区的 UTC 毫秒时间，避免夏令时回拨或两台设备时区不同导致显示和排序含糊。
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}

bool integerValue(const QVariant& value, int* result)
{
    if (!value.isValid() || value.isNull() || value.typeId() == QMetaType::Bool) {
        return false;
    }
    bool ok = false;
    const double number = value.toDouble(&ok);
    if (!ok || !(number >= 0 && number <= std::numeric_limits<int>::max())) {
        return false;
    }
    *result = static_cast<int>(number);
    return number == *result; // QML 数字以浮点数传入，不能把 1.5 悄悄当成编号 2。
}
}

MemoService::MemoService(QObject* parent)
    : QObject(parent)
{
    // 服务不缓存列表；重开或恢复数据库后通知订阅者重读即可。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged,
            this, &MemoService::memosChanged);
}

MemoService* MemoService::instance()
{
    static MemoService service;
    return &service;
}

bool MemoService::reportFailure(const QString& message) const
{
    emit const_cast<MemoService*>(this)->operationFailed(message);
    return false;
}

bool MemoService::databaseReady() const
{
    return DatabaseManager::instance()->isOpen()
        || reportFailure(QStringLiteral("数据库未打开，无法读取或保存备忘录"));
}

bool MemoService::validateText(const QString& title, const QString& body) const
{
    // 按 Unicode 字符计数，与 SQLite 的 length() 一致；表情不会因占两个 UTF-16 单元被算两字。
    if (title.toUcs4().size() > kMaxTitleLength) {
        return reportFailure(QStringLiteral("标题最多 %1 字，未保存").arg(kMaxTitleLength));
    }
    if (body.toUcs4().size() > kMaxBodyLength) {
        return reportFailure(QStringLiteral("正文最多 %1 字，未保存").arg(kMaxBodyLength));
    }
    if (title.contains(QChar::Null) || body.contains(QChar::Null)) {
        return reportFailure(QStringLiteral("备忘录不能包含空字符，未保存"));
    }
    return true;
}

bool MemoService::categoryExists(int categoryId) const
{
    if (categoryId == 0) {
        return true;
    }
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT id FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), categoryId);
    if (!query.exec()) {
        return reportFailure(QStringLiteral("读取科目失败：%1").arg(query.lastError().text()));
    }
    return (categoryId > 0 && query.next()) || reportFailure(QStringLiteral("科目已不存在"));
}

bool MemoService::nextSortOrder(int categoryId, int* order) const
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT COALESCE(MAX(sort_order), 0) FROM memos WHERE category_id IS :category"));
    query.bindValue(QStringLiteral(":category"), categoryValue(categoryId));
    if (!query.exec() || !query.next()) {
        return reportFailure(QStringLiteral("读取备忘录顺序失败：%1").arg(query.lastError().text()));
    }
    const qlonglong maximum = query.value(0).toLongLong();
    if (maximum >= std::numeric_limits<int>::max()) {
        return reportFailure(QStringLiteral("备忘录顺序已超出范围，请先重新排序"));
    }
    *order = static_cast<int>(maximum) + 1;
    return true;
}

QVariantMap MemoService::memoFromQuery(const QSqlQuery& query) const
{
    const QString title = query.value(1).toString();
    const QString body = query.value(2).toString();
    // 只处理派生显示文本，不改用户存下的原文；标题为空时严格取正文第一行。
    QString firstLine = body.section(QLatin1Char('\n'), 0, 0);
    if (firstLine.endsWith(QLatin1Char('\r'))) {
        firstLine.chop(1);
    }
    return {{QStringLiteral("id"), query.value(0).toInt()},
            {QStringLiteral("title"), title}, {QStringLiteral("body"), body},
            {QStringLiteral("displayTitle"), title.trimmed().isEmpty() ? firstLine : title},
            {QStringLiteral("preview"), firstLine},
            {QStringLiteral("categoryId"), query.value(3).toInt()},
            {QStringLiteral("categoryName"), query.value(4).toString()},
            {QStringLiteral("categoryColor"), query.value(5).toString()},
            {QStringLiteral("sortOrder"), query.value(6).toInt()},
            {QStringLiteral("createdAt"), query.value(7).toString()},
            {QStringLiteral("updatedAt"), query.value(8).toString()}};
}

QVariantList MemoService::queryMemos(int categoryId, QString* error) const
{
    if (categoryId < kFilterAll) {
        *error = QStringLiteral("科目筛选无效");
        return {};
    }
    if (!DatabaseManager::instance()->isOpen()) {
        *error = QStringLiteral("数据库未打开，无法读取或保存备忘录");
        return {};
    }
    QSqlQuery query(DatabaseManager::instance()->database());
    QString sql = kSelect;
    if (categoryId != kFilterAll) {
        sql += QStringLiteral("WHERE m.category_id IS :category ");
    }
    // 全部视图按科目管理顺序分组，未分类放末尾；编号兜底使同序号时也有确定顺序。
    sql += QStringLiteral("ORDER BY (m.category_id IS NULL), c.display_order, m.category_id, "
                          "m.sort_order, m.created_at, m.id");
    query.prepare(sql);
    if (categoryId != kFilterAll) {
        query.bindValue(QStringLiteral(":category"), categoryValue(categoryId));
    }
    if (!query.exec()) {
        *error = QStringLiteral("读取备忘录列表失败：%1").arg(query.lastError().text());
        return {};
    }
    QVariantList result;
    while (query.next()) {
        result.append(memoFromQuery(query));
    }
    if (query.lastError().isValid()) {
        *error = QStringLiteral("读取备忘录列表失败：%1").arg(query.lastError().text());
        return {};
    }
    return result;
}

QVariantList MemoService::listMemos(int categoryId) const
{
    QString error;
    const QVariantList result = queryMemos(categoryId, &error);
    if (!error.isEmpty()) {
        reportFailure(error);
    }
    return result;
}

QVariantMap MemoService::readMemos() const
{
    QString error;
    const QVariantList memos = queryMemos(kFilterAll, &error);
    if (!error.isEmpty()) {
        return {{QStringLiteral("ok"), false}, {QStringLiteral("memos"), QVariantList()},
                {QStringLiteral("error"), error}};
    }
    return {{QStringLiteral("ok"), true}, {QStringLiteral("memos"), memos}};
}

QVariantMap MemoService::getMemo(int memoId) const
{
    if (memoId <= 0) {
        reportFailure(QStringLiteral("备忘录编号无效"));
        return {};
    }
    if (!databaseReady()) {
        return {};
    }
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(kSelect + QStringLiteral("WHERE m.id = :id"));
    query.bindValue(QStringLiteral(":id"), memoId);
    if (!query.exec()) {
        reportFailure(QStringLiteral("读取备忘录失败：%1").arg(query.lastError().text()));
        return {};
    }
    if (!query.next()) {
        reportFailure(QStringLiteral("这条备忘录已不存在"));
        return {};
    }
    return memoFromQuery(query);
}

int MemoService::createMemo(const QString& title, const QString& body, int categoryId)
{
    if (!validateText(title, body) || !databaseReady() || !categoryExists(categoryId)) {
        return -1;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        reportFailure(QStringLiteral("开始新建备忘录失败：%1").arg(db.lastError().text()));
        return -1;
    }
    int order = 0;
    if (!nextSortOrder(categoryId, &order)) {
        db.rollback();
        return -1;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("INSERT INTO memos (title, body, category_id, sort_order, created_at, updated_at) "
                                 "VALUES (:title, :body, :category, :order, :now, :now)"));
    query.bindValue(QStringLiteral(":title"), storedText(title));
    query.bindValue(QStringLiteral(":body"), storedText(body));
    query.bindValue(QStringLiteral(":category"), categoryValue(categoryId));
    query.bindValue(QStringLiteral(":order"), order);
    query.bindValue(QStringLiteral(":now"), timestamp());
    const bool inserted = query.exec();
    const int id = inserted ? query.lastInsertId().toInt() : -1;
    const QString error = query.lastError().text();
    query.finish(); // 先释放语句持有的表锁，再提交或回滚，失败后服务仍能继续使用。
    if (!inserted || !db.commit()) {
        const QString reason = inserted ? db.lastError().text() : error;
        db.rollback();
        reportFailure(QStringLiteral("新建备忘录失败：%1").arg(reason));
        return -1;
    }
    emit memosChanged();
    return id;
}

bool MemoService::updateMemo(int memoId, const QVariantMap& changes)
{
    for (auto it = changes.cbegin(); it != changes.cend(); ++it) {
        if (it.key() != QStringLiteral("title") && it.key() != QStringLiteral("body")
            && it.key() != QStringLiteral("categoryId")) {
            return reportFailure(QStringLiteral("不能修改备忘录字段：%1").arg(it.key()));
        }
        if (it.key() != QStringLiteral("categoryId") && it.value().typeId() != QMetaType::QString) {
            return reportFailure(QStringLiteral("标题和正文必须是纯文本"));
        }
    }
    int categoryId = 0;
    if (changes.contains(QStringLiteral("categoryId"))
        && !integerValue(changes.value(QStringLiteral("categoryId")), &categoryId)) {
        return reportFailure(QStringLiteral("科目编号无效"));
    }
    if (!databaseReady()) {
        return false;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        return reportFailure(QStringLiteral("开始保存备忘录失败：%1").arg(db.lastError().text()));
    }
    const QVariantMap current = getMemo(memoId);
    if (current.isEmpty()) {
        db.rollback();
        return false;
    }
    const QString title = changes.value(QStringLiteral("title"), current.value(QStringLiteral("title"))).toString();
    const QString body = changes.value(QStringLiteral("body"), current.value(QStringLiteral("body"))).toString();
    categoryId = changes.contains(QStringLiteral("categoryId")) ? categoryId : current.value(QStringLiteral("categoryId")).toInt();
    if (!validateText(title, body) || !categoryExists(categoryId)) {
        db.rollback();
        return false;
    }
    QStringList assignments;
    QSqlQuery query(db);
    for (const QString& field : {QStringLiteral("title"), QStringLiteral("body")}) {
        if (changes.contains(field) && changes.value(field).toString() != current.value(field).toString()) {
            assignments.append(field + QStringLiteral(" = :") + field);
        }
    }
    int order = 0;
    if (categoryId != current.value(QStringLiteral("categoryId")).toInt()) {
        if (!nextSortOrder(categoryId, &order)) {
            db.rollback();
            return false;
        }
        assignments.append(QStringLiteral("category_id = :category"));
        assignments.append(QStringLiteral("sort_order = :order"));
    }
    if (assignments.isEmpty()) {
        db.rollback();
        return true; // 没改内容时不刷新更新时间，也不制造同步版本。
    }
    assignments.append(QStringLiteral("updated_at = :now"));
    query.prepare(QStringLiteral("UPDATE memos SET %1 WHERE id = :id").arg(assignments.join(QStringLiteral(", "))));
    for (const QString& field : {QStringLiteral("title"), QStringLiteral("body")}) {
        if (changes.contains(field) && changes.value(field).toString() != current.value(field).toString()) {
            query.bindValue(QLatin1Char(':') + field, storedText(changes.value(field).toString()));
        }
    }
    if (order > 0) {
        query.bindValue(QStringLiteral(":category"), categoryValue(categoryId));
        query.bindValue(QStringLiteral(":order"), order);
    }
    query.bindValue(QStringLiteral(":id"), memoId);
    query.bindValue(QStringLiteral(":now"), timestamp());
    const bool saved = query.exec() && query.numRowsAffected() == 1;
    const QString error = query.lastError().text();
    query.finish();
    if (!saved || !db.commit()) {
        const QString reason = saved ? db.lastError().text() : error;
        db.rollback();
        return reportFailure(QStringLiteral("保存备忘录失败：%1").arg(reason));
    }
    emit memosChanged();
    return true;
}

bool MemoService::deleteMemo(int memoId)
{
    if (memoId <= 0) {
        return reportFailure(QStringLiteral("备忘录编号无效"));
    }
    if (!databaseReady()) {
        return false;
    }
    // 先写废纸篓再删除，同一事务：写入失败整体回滚，宁可删不掉也不能删了却没进废纸篓。
    // 完全空白的备忘 capture 会直接放行、不写废纸篓。
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        return reportFailure(QStringLiteral("删除备忘录失败：%1").arg(db.lastError().text()));
    }
    QString trashError;
    if (!TrashStore::captureMemo(db, memoId, &trashError)) {
        db.rollback();
        return reportFailure(trashError == TrashStore::kMissingRecord
                                 ? QStringLiteral("这条备忘录已不存在")
                                 : QStringLiteral("删除备忘录失败：%1").arg(trashError));
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM memos WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), memoId);
    if (!query.exec()) {
        const QString reason = query.lastError().text();
        query.finish();
        db.rollback();
        return reportFailure(QStringLiteral("删除备忘录失败：%1").arg(reason));
    }
    if (query.numRowsAffected() != 1) {
        query.finish();
        db.rollback();
        return reportFailure(QStringLiteral("这条备忘录已不存在"));
    }
    query.finish();
    if (!db.commit()) {
        const QString reason = db.lastError().text();
        db.rollback();
        return reportFailure(QStringLiteral("删除备忘录失败：%1").arg(reason));
    }
    emit memosChanged();
    emit TrashNotifier::instance()->changed();
    return true;
}

bool MemoService::reorderMemos(int categoryId, const QVariantList& memoIds)
{
    if (categoryId < 0) {
        return reportFailure(QStringLiteral("排序必须在同一科目内进行"));
    }
    if (!databaseReady()) {
        return false;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        return reportFailure(QStringLiteral("开始排序失败：%1").arg(db.lastError().text()));
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT id, sort_order FROM memos WHERE category_id IS :category"));
    query.bindValue(QStringLiteral(":category"), categoryValue(categoryId));
    if (!query.exec()) {
        const QString error = query.lastError().text();
        query.finish();
        db.rollback();
        return reportFailure(QStringLiteral("读取排序失败：%1").arg(error));
    }
    QMap<int, int> current;
    while (query.next()) {
        current.insert(query.value(0).toInt(), query.value(1).toInt());
    }
    if (query.lastError().isValid()) {
        const QString error = query.lastError().text();
        query.finish();
        db.rollback();
        return reportFailure(QStringLiteral("读取排序失败：%1").arg(error));
    }
    query.finish();
    QList<int> ids;
    QSet<int> seen;
    for (const QVariant& value : memoIds) {
        int id = 0;
        if (!integerValue(value, &id) || id <= 0 || seen.contains(id) || !current.contains(id)) {
            db.rollback();
            return reportFailure(QStringLiteral("排序包含重复、无效或其它科目的备忘录"));
        }
        seen.insert(id);
        ids.append(id);
    }
    if (ids.size() != current.size()) {
        db.rollback();
        return reportFailure(QStringLiteral("备忘录列表已变化，请刷新后重排"));
    }
    bool changed = false;
    for (qsizetype index = 0; index < ids.size(); ++index) {
        const int order = static_cast<int>(index) + 1;
        if (current.value(ids.at(index)) == order) {
            continue;
        }
        // 只改位置，不动更新时间：界面上的「更新时间」表示内容最后一次修改，拖动排序不算改内容。
        // 否则挪一下顺序，被挪动的几条都会显示成「刚刚更新」。
        query.prepare(QStringLiteral("UPDATE memos SET sort_order = :order WHERE id = :id"));
        query.bindValue(QStringLiteral(":order"), order);
        query.bindValue(QStringLiteral(":id"), ids.at(index));
        const bool saved = query.exec() && query.numRowsAffected() == 1;
        const QString error = query.lastError().text();
        query.finish();
        if (!saved) {
            db.rollback();
            return reportFailure(QStringLiteral("排序失败，已恢复原顺序：%1").arg(error));
        }
        changed = true;
    }
    if (!db.commit()) {
        const QString error = db.lastError().text();
        db.rollback();
        return reportFailure(QStringLiteral("排序提交失败：%1").arg(error));
    }
    if (changed) {
        emit memosChanged();
    }
    return true;
}
