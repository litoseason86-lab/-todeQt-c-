#include "KnowledgeGapService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "LogicalDay.h"

#include <QDateTime>
#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>

namespace {

// 列表与详情共用同一条 SELECT，保证两处读到的字段口径完全一致。
// 读取一律按列下标，不按列名：category 与 tasks 都有 title/name 这类同名列，
// 按名字取值在不同驱动下的行为并不一致。
const char* const kGapSelectSql =
    "SELECT g.id, g.title, g.detail, g.category_id, c.name, c.color, "
    "       g.source_task_id, g.source_task_title, g.priority, g.status, "
    "       g.due_date, g.resolution, g.linked_task_id, t.completed, t.title, "
    "       g.created_at, g.updated_at, g.resolved_at "
    "FROM knowledge_gaps g "
    "LEFT JOIN categories c ON c.id = g.category_id "
    "LEFT JOIN tasks t ON t.id = g.linked_task_id ";

// 排序不变量：已解决沉到最后，其余按到期日从早到晚，未排期再沉到已排期之后，
// 最后按优先级高到低、创建时间早到晚兜底，保证顺序完全确定。
//
// 第一项写 (g.status = 2) 而不是 g.status ASC：状态的数值顺序是「待处理 0 < 已安排 1」，
// 直接按它排会把全部未排期条目顶到已排期前面，正好和清单页要的顺序相反——
// 这里要分的只有「解决了没有」，待处理和已安排之间的先后由到期日决定。
// 2 是 StatusResolved，与表上的 CHECK(status IN (0,1,2)) 同一套取值。
//
// (g.due_date IS NULL) 也必须单独作为一个排序项：SQLite 把 NULL 排在最小值一侧，
// 只按 due_date 排会让「未排期」冒到「今天到期」前面。
const char* const kGapOrderSql =
    "ORDER BY (g.status = 2) ASC, (g.due_date IS NULL) ASC, g.due_date ASC, "
    "         g.priority DESC, g.created_at ASC, g.id ASC ";

QString nowIso()
{
    return QDateTime::currentDateTime().toString(Qt::ISODate);
}

QDate logicalToday()
{
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}

bool isValidGapId(int gapId)
{
    return gapId > 0;
}

int clampPriority(int value)
{
    // 与任务的预计用时同样采取夹紧而非拒绝：不能因为一个次要字段填错，
    // 就让用户辛苦打下的那段内容存不进去。
    return qBound(KnowledgeGapService::kMinPriority, value, KnowledgeGapService::kMaxPriority);
}

QDate normalizeDate(const QVariant& value)
{
    // QML 传 Date，测试常传字符串，C++ 调用方可能直接传 QDate。
    if (value.canConvert<QDate>()) {
        const QDate date = value.toDate();
        if (date.isValid()) {
            return date;
        }
    }
    if (value.canConvert<QDateTime>()) {
        const QDateTime dateTime = value.toDateTime();
        if (dateTime.isValid()) {
            return dateTime.date();
        }
    }
    const QString text = value.toString().trimmed();
    if (!text.isEmpty()) {
        const QDate isoDate = QDate::fromString(text, Qt::ISODate);
        if (isoDate.isValid()) {
            return isoDate;
        }
        const QDateTime isoDateTime = QDateTime::fromString(text, Qt::ISODate);
        if (isoDateTime.isValid()) {
            return isoDateTime.date();
        }
    }
    return QDate();
}

// 到期日是可选的，所以「空」和「非法」必须分开处理：
// 传空值是合法输入，意思是「清空排期」；传了内容但解析不出日期才是错误。
// 两者混为一谈会让一个填错的日期静默变成「未排期」，用户再也等不到提醒。
bool parseOptionalDueDate(const QVariant& value, QDate* outDate, QString* error)
{
    *outDate = QDate();
    const bool looksEmpty = !value.isValid() || value.isNull()
                            || (value.typeId() == QMetaType::QString && value.toString().trimmed().isEmpty());
    if (looksEmpty) {
        return true;
    }

    const QDate date = normalizeDate(value);
    if (!date.isValid()) {
        *error = QStringLiteral("日期格式不正确");
        return false;
    }
    // 与任务编辑同一口径：只接受 2000–2100 年。超出这个范围的多半是输入事故，
    // 存进去之后排序和「逾期 N 天」都会给出荒唐结果。
    if (date.year() < 2000 || date.year() > 2100) {
        *error = QStringLiteral("日期需要在 2000 年到 2100 年之间");
        return false;
    }
    *outDate = date;
    return true;
}

// 空 QString 是 null，直接绑会写成 SQL NULL，撞上 detail / source_task_title /
// resolution 这三列的 NOT NULL 约束——而「没写正文」恰恰是最常见的情况。
// 所有文本列统一走这里截断并收敛成空串。
QString boundedText(const QString& value, int maxLength)
{
    const QString clipped = value.left(maxLength);
    return clipped.isNull() ? QString::fromLatin1("") : clipped;
}

QVariant dueDateBindValue(const QDate& date)
{
    return date.isValid() ? QVariant(date.toString(Qt::ISODate)) : QVariant(QMetaType(QMetaType::QString));
}

// 有排期就算「已安排」，没有就退回「待处理」。已解决的条目不走这里，
// 它的状态由 resolveGap / reopenGap 显式决定。
int statusForDueDate(const QDate& dueDate)
{
    return dueDate.isValid() ? KnowledgeGapService::StatusScheduled : KnowledgeGapService::StatusOpen;
}

} // namespace

KnowledgeGapService::KnowledgeGapService(QObject* parent)
    : QObject(parent)
{
    // 换库与同路径重开都由 DatabaseManager 广播；本服务不缓存行数据，
    // 收到通知后只要让界面重查一次即可。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged,
            this, &KnowledgeGapService::gapsChanged);
}

KnowledgeGapService* KnowledgeGapService::instance()
{
    static KnowledgeGapService service;
    return &service;
}

bool KnowledgeGapService::reportFailure(const QString& message) const
{
    qWarning() << "KnowledgeGapService:" << message;
    emit const_cast<KnowledgeGapService*>(this)->operationFailed(message);
    return false;
}

bool KnowledgeGapService::databaseReady() const
{
    const QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        return reportFailure(QStringLiteral("数据库未打开，知识缺口暂不可用"));
    }
    return true;
}

int KnowledgeGapService::statusOf(int gapId) const
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT status FROM knowledge_gaps WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), gapId);
    if (!query.exec() || !query.next()) {
        return -1;
    }
    return query.value(0).toInt();
}

int KnowledgeGapService::captureGap(const QString& title, int categoryId, int sourceTaskId)
{
    return addGap(title, categoryId, QString(), 1, QVariant(), sourceTaskId);
}

int KnowledgeGapService::addGap(const QString& title,
                                int categoryId,
                                const QString& detail,
                                int priority,
                                const QVariant& dueDateValue,
                                int sourceTaskId)
{
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        reportFailure(QStringLiteral("请先填写要记录的内容"));
        return -1;
    }
    if (normalizedTitle.size() > kMaxTitleLength) {
        reportFailure(QStringLiteral("内容太长了，请控制在 %1 字以内").arg(kMaxTitleLength));
        return -1;
    }

    QDate dueDate;
    QString dateError;
    if (!parseOptionalDueDate(dueDateValue, &dueDate, &dateError)) {
        reportFailure(dateError);
        return -1;
    }

    if (!databaseReady()) {
        return -1;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();

    // 来源任务标题在写入时定格成快照。外键是 ON DELETE SET NULL，任务删掉后
    // source_task_id 会变空，但「这条是在复习线代第 3 章时记的」属于当时的现场，
    // 不该跟着任务一起消失。
    // 必须用赋值初始化：QVariant x(QMetaType(...)) 会被编译器当成函数声明（vexing parse）。
    QVariant sourceTaskIdValue = QVariant(QMetaType(QMetaType::Int));
    QString sourceTaskTitle;
    if (sourceTaskId > 0) {
        QSqlQuery sourceQuery(db);
        sourceQuery.prepare(QStringLiteral("SELECT title FROM tasks WHERE id = :id"));
        sourceQuery.bindValue(QStringLiteral(":id"), sourceTaskId);
        if (sourceQuery.exec() && sourceQuery.next()) {
            sourceTaskIdValue = sourceTaskId;
            sourceTaskTitle = sourceQuery.value(0).toString();
        }
        // 查不到就当作没有来源：来源只是锦上添花的上下文，
        // 不能因为任务刚好被删掉就让这条记录整个存不下来。
    }

    const QString timestamp = nowIso();
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO knowledge_gaps "
        "(title, detail, category_id, source_task_id, source_task_title, priority, status, "
        " due_date, resolution, linked_task_id, created_at, updated_at, resolved_at) "
        "VALUES (:title, :detail, :categoryId, :sourceTaskId, :sourceTaskTitle, :priority, :status, "
        "        :dueDate, '', NULL, :createdAt, :updatedAt, NULL)"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":detail"), boundedText(detail, kMaxDetailLength));
    query.bindValue(QStringLiteral(":categoryId"),
                    categoryId > 0 ? QVariant(categoryId) : QVariant(QMetaType(QMetaType::Int)));
    query.bindValue(QStringLiteral(":sourceTaskId"), sourceTaskIdValue);
    query.bindValue(QStringLiteral(":sourceTaskTitle"), boundedText(sourceTaskTitle, kMaxTitleLength));
    query.bindValue(QStringLiteral(":priority"), clampPriority(priority));
    query.bindValue(QStringLiteral(":status"), statusForDueDate(dueDate));
    query.bindValue(QStringLiteral(":dueDate"), dueDateBindValue(dueDate));
    query.bindValue(QStringLiteral(":createdAt"), timestamp);
    query.bindValue(QStringLiteral(":updatedAt"), timestamp);

    if (!query.exec() || query.numRowsAffected() != 1) {
        reportFailure(QStringLiteral("保存失败：%1").arg(query.lastError().text()));
        return -1;
    }

    const int newId = query.lastInsertId().toInt();
    emit gapsChanged();
    return newId;
}

bool KnowledgeGapService::updateGap(int gapId,
                                    const QString& title,
                                    int categoryId,
                                    const QString& detail,
                                    int priority,
                                    const QVariant& dueDateValue)
{
    if (!isValidGapId(gapId)) {
        return reportFailure(QStringLiteral("条目编号无效"));
    }
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        return reportFailure(QStringLiteral("请先填写要记录的内容"));
    }
    if (normalizedTitle.size() > kMaxTitleLength) {
        return reportFailure(QStringLiteral("内容太长了，请控制在 %1 字以内").arg(kMaxTitleLength));
    }

    QDate dueDate;
    QString dateError;
    if (!parseOptionalDueDate(dueDateValue, &dueDate, &dateError)) {
        return reportFailure(dateError);
    }

    if (!databaseReady()) {
        return false;
    }

    const int currentStatus = statusOf(gapId);
    if (currentStatus < 0) {
        return reportFailure(QStringLiteral("这条记录已不存在"));
    }
    // 编辑一条已解决的记录不该把它重新打开——用户可能只是回来补充结论的措辞。
    // 重新打开必须是显式动作（reopenGap）。
    const int nextStatus = currentStatus == StatusResolved ? StatusResolved : statusForDueDate(dueDate);

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "UPDATE knowledge_gaps SET title = :title, detail = :detail, category_id = :categoryId, "
        "priority = :priority, status = :status, due_date = :dueDate, updated_at = :updatedAt "
        "WHERE id = :id"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":detail"), boundedText(detail, kMaxDetailLength));
    query.bindValue(QStringLiteral(":categoryId"),
                    categoryId > 0 ? QVariant(categoryId) : QVariant(QMetaType(QMetaType::Int)));
    query.bindValue(QStringLiteral(":priority"), clampPriority(priority));
    query.bindValue(QStringLiteral(":status"), nextStatus);
    query.bindValue(QStringLiteral(":dueDate"), dueDateBindValue(dueDate));
    query.bindValue(QStringLiteral(":updatedAt"), nowIso());
    query.bindValue(QStringLiteral(":id"), gapId);

    if (!query.exec() || query.numRowsAffected() != 1) {
        return reportFailure(QStringLiteral("保存失败：%1").arg(query.lastError().text()));
    }

    emit gapsChanged();
    return true;
}

bool KnowledgeGapService::setDueDate(int gapId, const QVariant& dueDateValue)
{
    return moveGapsToDate(QVariantList{gapId}, dueDateValue);
}

bool KnowledgeGapService::moveGapsToDate(const QVariantList& gapIds, const QVariant& dueDateValue)
{
    if (gapIds.isEmpty()) {
        return reportFailure(QStringLiteral("没有选中任何条目"));
    }

    QDate dueDate;
    QString dateError;
    if (!parseOptionalDueDate(dueDateValue, &dueDate, &dateError)) {
        return reportFailure(dateError);
    }

    if (!databaseReady()) {
        return false;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();

    if (!db.transaction()) {
        return reportFailure(QStringLiteral("开始批量改期失败：%1").arg(db.lastError().text()));
    }

    const QString timestamp = nowIso();
    const int nextStatus = statusForDueDate(dueDate);
    for (const QVariant& idValue : gapIds) {
        bool ok = false;
        const int gapId = idValue.toInt(&ok);
        if (!ok || !isValidGapId(gapId)) {
            db.rollback();
            return reportFailure(QStringLiteral("条目编号无效"));
        }

        // 整批先校验再写：已解决的条目排期没有意义，撞上一条就整批退回，
        // 不留下「前几条改了、后几条没改」的中间状态。
        const int currentStatus = statusOf(gapId);
        if (currentStatus < 0) {
            db.rollback();
            return reportFailure(QStringLiteral("其中有条目已不存在，改期已取消"));
        }
        if (currentStatus == StatusResolved) {
            db.rollback();
            return reportFailure(QStringLiteral("已解决的条目需要先重新打开才能排期"));
        }

        QSqlQuery query(db);
        query.prepare(QStringLiteral(
            "UPDATE knowledge_gaps SET due_date = :dueDate, status = :status, updated_at = :updatedAt "
            "WHERE id = :id"));
        query.bindValue(QStringLiteral(":dueDate"), dueDateBindValue(dueDate));
        query.bindValue(QStringLiteral(":status"), nextStatus);
        query.bindValue(QStringLiteral(":updatedAt"), timestamp);
        query.bindValue(QStringLiteral(":id"), gapId);
        if (!query.exec() || query.numRowsAffected() != 1) {
            const QString error = query.lastError().text();
            // 回滚前必须先释放语句句柄：失败的 exec 也可能留下仍然打开的 statement，
            // SQLite 会继续持有表锁，之后任何 DDL（启动迁移、备份的 VACUUM INTO）
            // 都会以“database table is locked”失败，而现场早已离开这里。
            query.finish();
            db.rollback();
            return reportFailure(QStringLiteral("改期失败：%1").arg(error));
        }
    }

    if (!db.commit()) {
        const QString error = db.lastError().text();
        db.rollback();
        return reportFailure(QStringLiteral("提交批量改期失败：%1").arg(error));
    }

    emit gapsChanged();
    return true;
}

bool KnowledgeGapService::resolveGap(int gapId, const QString& resolution)
{
    if (!isValidGapId(gapId)) {
        return reportFailure(QStringLiteral("条目编号无效"));
    }
    if (!databaseReady()) {
        return false;
    }

    const QString timestamp = nowIso();
    QSqlQuery query(DatabaseManager::instance()->database());
    // resolved_at 只在首次解决时写入：重复点「已解决」不该把首次想明白的时间抹掉。
    query.prepare(QStringLiteral(
        "UPDATE knowledge_gaps SET status = :status, resolution = :resolution, "
        "resolved_at = COALESCE(resolved_at, :resolvedAt), updated_at = :updatedAt "
        "WHERE id = :id"));
    query.bindValue(QStringLiteral(":status"), static_cast<int>(StatusResolved));
    query.bindValue(QStringLiteral(":resolution"), boundedText(resolution, kMaxDetailLength));
    query.bindValue(QStringLiteral(":resolvedAt"), timestamp);
    query.bindValue(QStringLiteral(":updatedAt"), timestamp);
    query.bindValue(QStringLiteral(":id"), gapId);

    if (!query.exec()) {
        return reportFailure(QStringLiteral("保存失败：%1").arg(query.lastError().text()));
    }
    if (query.numRowsAffected() != 1) {
        return reportFailure(QStringLiteral("这条记录已不存在"));
    }

    emit gapsChanged();
    return true;
}

bool KnowledgeGapService::reopenGap(int gapId)
{
    if (!isValidGapId(gapId)) {
        return reportFailure(QStringLiteral("条目编号无效"));
    }
    if (!databaseReady()) {
        return false;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    // 重新打开时按 due_date 回推状态，并清掉 resolved_at；resolution 保留下来当笔记。
    query.prepare(QStringLiteral(
        "UPDATE knowledge_gaps "
        "SET status = CASE WHEN due_date IS NULL THEN :openStatus ELSE :scheduledStatus END, "
        "    resolved_at = NULL, updated_at = :updatedAt "
        "WHERE id = :id AND status = :resolvedStatus"));
    query.bindValue(QStringLiteral(":openStatus"), static_cast<int>(StatusOpen));
    query.bindValue(QStringLiteral(":scheduledStatus"), static_cast<int>(StatusScheduled));
    query.bindValue(QStringLiteral(":resolvedStatus"), static_cast<int>(StatusResolved));
    query.bindValue(QStringLiteral(":updatedAt"), nowIso());
    query.bindValue(QStringLiteral(":id"), gapId);

    if (!query.exec()) {
        return reportFailure(QStringLiteral("保存失败：%1").arg(query.lastError().text()));
    }
    if (query.numRowsAffected() != 1) {
        return reportFailure(QStringLiteral("这条记录不在已解决状态"));
    }

    emit gapsChanged();
    return true;
}

bool KnowledgeGapService::deleteGap(int gapId)
{
    if (!isValidGapId(gapId)) {
        return reportFailure(QStringLiteral("条目编号无效"));
    }
    if (!databaseReady()) {
        return false;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("DELETE FROM knowledge_gaps WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), gapId);
    if (!query.exec()) {
        return reportFailure(QStringLiteral("删除失败：%1").arg(query.lastError().text()));
    }
    if (query.numRowsAffected() != 1) {
        return reportFailure(QStringLiteral("这条记录已不存在"));
    }

    emit gapsChanged();
    return true;
}

int KnowledgeGapService::convertToTask(int gapId, const QVariant& dateValue)
{
    if (!isValidGapId(gapId)) {
        reportFailure(QStringLiteral("条目编号无效"));
        return -1;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        reportFailure(QStringLiteral("请选择要安排到哪一天"));
        return -1;
    }
    if (date.year() < 2000 || date.year() > 2100) {
        reportFailure(QStringLiteral("日期需要在 2000 年到 2100 年之间"));
        return -1;
    }

    if (!databaseReady()) {
        return -1;
    }
    QSqlDatabase db = DatabaseManager::instance()->database();

    // 读现状、建任务、置状态、记关联必须同进同退。「是否已有没做完的关联任务」这个判断
    // 也放在事务里：判断和写入之间不能留出空隙，否则判断就不作数。
    if (!db.transaction()) {
        reportFailure(QStringLiteral("开始转任务失败：%1").arg(db.lastError().text()));
        return -1;
    }

    QSqlQuery gapQuery(db);
    gapQuery.prepare(QStringLiteral(
        "SELECT g.title, g.detail, g.category_id, g.status, c.name, t.id, t.completed "
        "FROM knowledge_gaps g "
        "LEFT JOIN categories c ON c.id = g.category_id "
        "LEFT JOIN tasks t ON t.id = g.linked_task_id "
        "WHERE g.id = :id"));
    gapQuery.bindValue(QStringLiteral(":id"), gapId);
    if (!gapQuery.exec() || !gapQuery.next()) {
        gapQuery.finish();
        db.rollback();
        reportFailure(QStringLiteral("这条记录已不存在"));
        return -1;
    }
    const QString gapTitle = gapQuery.value(0).toString();
    const QString gapDetail = gapQuery.value(1).toString();
    const QVariant gapCategoryId = gapQuery.value(2);
    const int gapStatus = gapQuery.value(3).toInt();
    const QString gapCategoryName = gapQuery.value(4).toString();
    // 按 JOIN 到的任务行判断，不按 linked_task_id 判断：编号可能指向已经删掉的任务
    // （外键未生效的旧库），那种情况等同于没有关联，应当允许重新转。
    const bool linkedTaskOpen = !gapQuery.value(5).isNull() && gapQuery.value(6).toInt() == 0;
    gapQuery.finish();

    if (gapStatus == StatusResolved) {
        db.rollback();
        reportFailure(QStringLiteral("已解决的条目不需要再安排任务"));
        return -1;
    }
    // 已有一条没做完的关联任务：它已经在任务列表（或逾期任务区）里等着了。
    // 再建一条只会得到两条同名任务，关联还会被改写到新任务上，旧任务从此没人认领。
    // 关联任务做完了却还没想明白的，才允许再转一次。
    if (linkedTaskOpen) {
        db.rollback();
        reportFailure(QStringLiteral("这条已经有一条没做完的任务"));
        return -1;
    }

    // 任务备注带上缺口原文并注明来源：一周后在任务列表里看到这行字，
    // 光有标题往往已经想不起来当初卡在哪了。
    QString notes = QStringLiteral("来自知识缺口 #%1").arg(gapId);
    if (!gapDetail.isEmpty()) {
        notes += QLatin1Char('\n');
        notes += gapDetail;
    }

    QSqlQuery insertTask(db);
    insertTask.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, category_id, date, completed, "
        "estimated_minutes, notes, display_order) "
        // display_order 取当天最大值 +1，与 TaskManager::addTask 完全一致：
        // 新任务落在当天末尾，不插进用户已经排好的顺序中间。
        // 具名占位符不能重名，子查询里的日期单独取名。
        "VALUES (:title, :category, :categoryId, :date, 0, 0, :notes, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate))"));
    insertTask.bindValue(QStringLiteral(":title"), gapTitle);
    insertTask.bindValue(QStringLiteral(":category"), gapCategoryName);
    insertTask.bindValue(QStringLiteral(":categoryId"), gapCategoryId);
    insertTask.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));
    insertTask.bindValue(QStringLiteral(":orderDate"), date.toString(Qt::ISODate));
    insertTask.bindValue(QStringLiteral(":notes"), boundedText(notes, 2000));

    if (!insertTask.exec() || insertTask.numRowsAffected() != 1) {
        const QString error = insertTask.lastError().text();
        // 同上：先 finish 再 rollback，否则失败的 INSERT 会把 tasks 的表锁留在连接上。
        insertTask.finish();
        db.rollback();
        reportFailure(QStringLiteral("创建任务失败：%1").arg(error));
        return -1;
    }
    const int newTaskId = insertTask.lastInsertId().toInt();

    // 到期日取「原到期日」和「任务日期」里较早的那个，三种情况各有理由：
    // - 原来已逾期：保持原日期。逾期不顺延，拖了多久是判断该不该停下来处理的唯一依据；
    //   今日页的「全部加到今天」正是从逾期条目发起的，覆盖掉就等于每点一次抹掉一批逾期记录。
    // - 原来未排期：补成任务日期。状态由到期日派生，「已安排」却没有到期日会让两者分家。
    // - 原来排在以后：提前到任务日期。提前处理不抹掉任何拖延记录，
    //   继续显示那个以后的日期反而和「今天就在做」矛盾。
    // 到期日存的是 ISO 日期字符串，按字典序比较就是按日期比较。
    QSqlQuery updateGapQuery(db);
    updateGapQuery.prepare(QStringLiteral(
        "UPDATE knowledge_gaps SET status = :status, "
        "due_date = CASE WHEN due_date IS NULL OR due_date > :taskDate THEN :taskDate2 ELSE due_date END, "
        "linked_task_id = :taskId, updated_at = :updatedAt WHERE id = :id"));
    updateGapQuery.bindValue(QStringLiteral(":status"), static_cast<int>(StatusScheduled));
    // 同名占位符只绑第一处，两处任务日期各取一个名字。
    updateGapQuery.bindValue(QStringLiteral(":taskDate"), date.toString(Qt::ISODate));
    updateGapQuery.bindValue(QStringLiteral(":taskDate2"), date.toString(Qt::ISODate));
    updateGapQuery.bindValue(QStringLiteral(":taskId"), newTaskId);
    updateGapQuery.bindValue(QStringLiteral(":updatedAt"), nowIso());
    updateGapQuery.bindValue(QStringLiteral(":id"), gapId);

    if (!updateGapQuery.exec() || updateGapQuery.numRowsAffected() != 1) {
        const QString error = updateGapQuery.lastError().text();
        updateGapQuery.finish();
        insertTask.finish();
        db.rollback();
        reportFailure(QStringLiteral("更新知识缺口失败：%1").arg(error));
        return -1;
    }

    // 提交前收干净这两条语句，理由同上：连接上不能留着仍然打开的 statement。
    insertTask.finish();
    updateGapQuery.finish();
    if (!db.commit()) {
        const QString error = db.lastError().text();
        db.rollback();
        reportFailure(QStringLiteral("提交转任务失败：%1").arg(error));
        return -1;
    }

    emit gapsChanged();
    emit tasksAffected();
    return newTaskId;
}

QVariantMap KnowledgeGapService::rowToVariantMap(const QSqlQuery& query, const QDate& today) const
{
    QVariantMap map;
    map.insert(QStringLiteral("id"), query.value(0).toInt());
    map.insert(QStringLiteral("title"), query.value(1).toString());
    map.insert(QStringLiteral("detail"), query.value(2).toString());
    map.insert(QStringLiteral("categoryId"), query.value(3).isNull() ? 0 : query.value(3).toInt());
    map.insert(QStringLiteral("categoryName"), query.value(4).toString());
    map.insert(QStringLiteral("categoryColor"), query.value(5).toString());
    map.insert(QStringLiteral("sourceTaskId"), query.value(6).isNull() ? 0 : query.value(6).toInt());
    map.insert(QStringLiteral("sourceTaskTitle"), query.value(7).toString());
    map.insert(QStringLiteral("priority"), query.value(8).toInt());

    const int status = query.value(9).toInt();
    map.insert(QStringLiteral("status"), status);

    const QString dueText = query.value(10).toString();
    const QDate dueDate = QDate::fromString(dueText, Qt::ISODate);
    map.insert(QStringLiteral("dueDate"), dueDate.isValid() ? dueDate.toString(Qt::ISODate) : QString());
    map.insert(QStringLiteral("scheduled"), dueDate.isValid());
    // 逾期天数按逻辑日算，不用物理日：凌晨 2 点看列表时「今天」仍是前一天，
    // 这时不该把今天到期的条目报成已经逾期一天。
    const bool unresolved = status != StatusResolved;
    const bool overdue = unresolved && dueDate.isValid() && dueDate < today;
    map.insert(QStringLiteral("overdue"), overdue);
    map.insert(QStringLiteral("overdueDays"), overdue ? static_cast<int>(dueDate.daysTo(today)) : 0);
    map.insert(QStringLiteral("dueToday"), unresolved && dueDate.isValid() && dueDate == today);

    map.insert(QStringLiteral("resolution"), query.value(11).toString());
    const bool hasLinkedTask = !query.value(12).isNull();
    map.insert(QStringLiteral("linkedTaskId"), hasLinkedTask ? query.value(12).toInt() : 0);
    // 关联任务做完了不代表这条已经想明白，所以只把事实报给界面，由用户决定是否标记已解决。
    map.insert(QStringLiteral("linkedTaskCompleted"), hasLinkedTask && query.value(13).toInt() == 1);
    // 关联任务还在且没做完：这条已经以任务的形式进了任务列表。按 JOIN 到的任务行判断，
    // 与 convertToTask 的拒绝条件同一个口径；界面据此禁用「今天做」。
    map.insert(QStringLiteral("linkedTaskOpen"),
               !query.value(13).isNull() && query.value(13).toInt() == 0);
    map.insert(QStringLiteral("linkedTaskTitle"), query.value(14).toString());
    map.insert(QStringLiteral("createdAt"), query.value(15).toString());
    map.insert(QStringLiteral("updatedAt"), query.value(16).toString());
    map.insert(QStringLiteral("resolvedAt"), query.value(17).toString());
    return map;
}

QVariantList KnowledgeGapService::listGaps(int statusFilter,
                                           int categoryId,
                                           const QString& searchText,
                                           int limit) const
{
    QVariantList results;
    if (!databaseReady()) {
        return results;
    }

    QString whereSql = QStringLiteral("WHERE 1 = 1 ");
    if (statusFilter == kFilterUnresolved) {
        whereSql += QStringLiteral("AND g.status != :resolvedStatus ");
    } else if (statusFilter >= StatusOpen && statusFilter <= StatusResolved) {
        whereSql += QStringLiteral("AND g.status = :status ");
    }
    if (categoryId > 0) {
        whereSql += QStringLiteral("AND g.category_id = :categoryId ");
    }
    const QString trimmedSearch = searchText.trimmed();
    if (!trimmedSearch.isEmpty()) {
        // 标题、正文和结论一起搜：想找回一条旧记录时，记得住的往往是当时写的细节
        // 或者后来写下的答案，而不是标题那几个字。
        whereSql += QStringLiteral(
            "AND (g.title LIKE :search OR g.detail LIKE :search2 OR g.resolution LIKE :search3) ");
    }

    // limit <= 0 视为不限制，但仍给一个硬上限，避免界面一次拿到上万行。
    const int effectiveLimit = (limit > 0 && limit < 10000) ? limit : 10000;

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QLatin1String(kGapSelectSql) + whereSql + QLatin1String(kGapOrderSql)
                  + QStringLiteral("LIMIT :limit"));
    if (statusFilter == kFilterUnresolved) {
        query.bindValue(QStringLiteral(":resolvedStatus"), static_cast<int>(StatusResolved));
    } else if (statusFilter >= StatusOpen && statusFilter <= StatusResolved) {
        query.bindValue(QStringLiteral(":status"), statusFilter);
    }
    if (categoryId > 0) {
        query.bindValue(QStringLiteral(":categoryId"), categoryId);
    }
    if (!trimmedSearch.isEmpty()) {
        // SQLite 对同名具名占位符只绑第一处，三个 LIKE 必须用三个不同的名字。
        const QString pattern = QStringLiteral("%%%1%%").arg(trimmedSearch);
        query.bindValue(QStringLiteral(":search"), pattern);
        query.bindValue(QStringLiteral(":search2"), pattern);
        query.bindValue(QStringLiteral(":search3"), pattern);
    }
    query.bindValue(QStringLiteral(":limit"), effectiveLimit);

    if (!query.exec()) {
        reportFailure(QStringLiteral("读取知识缺口失败：%1").arg(query.lastError().text()));
        return results;
    }

    const QDate today = logicalToday();
    while (query.next()) {
        results.append(rowToVariantMap(query, today));
    }
    return results;
}

QVariantMap KnowledgeGapService::getGap(int gapId) const
{
    QVariantMap result;
    if (!isValidGapId(gapId) || !databaseReady()) {
        return result;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QLatin1String(kGapSelectSql) + QStringLiteral("WHERE g.id = :id"));
    query.bindValue(QStringLiteral(":id"), gapId);
    if (!query.exec()) {
        reportFailure(QStringLiteral("读取知识缺口失败：%1").arg(query.lastError().text()));
        return result;
    }
    if (!query.next()) {
        return result;
    }
    return rowToVariantMap(query, logicalToday());
}

QVariantMap KnowledgeGapService::getReminderSummary() const
{
    QVariantMap summary;
    // valid 用来把「真的没有待办」和「这次查询失败了」区分开：
    // 两种情况计数都是 0，但提示条对它们的处理必须不同。
    summary.insert(QStringLiteral("valid"), false);
    summary.insert(QStringLiteral("dueToday"), 0);
    summary.insert(QStringLiteral("overdue"), 0);
    summary.insert(QStringLiteral("unscheduled"), 0);
    summary.insert(QStringLiteral("openTotal"), 0);
    summary.insert(QStringLiteral("oldestOverdueDays"), 0);

    if (!databaseReady()) {
        return summary;
    }

    const QDate today = logicalToday();
    QSqlQuery query(DatabaseManager::instance()->database());
    // awaiting = 0 表示已有没做完的关联任务。这类条目不计入「今天到期 / 已逾期 / 最久逾期」：
    // 它已经作为任务出现在今日页（或逾期任务区），提示条再催一遍只会诱导用户点
    // 「全部加到今天」建出重复任务。关联任务做完而条目仍未解决时重新计入——做完不等于想明白。
    // 未排期与总数照旧统计全部未解决条目：转成任务不等于解决。
    query.prepare(QStringLiteral(
        "SELECT "
        " SUM(CASE WHEN awaiting = 1 AND due_date = :today1 THEN 1 ELSE 0 END), "
        " SUM(CASE WHEN awaiting = 1 AND due_date IS NOT NULL AND due_date < :today2 THEN 1 ELSE 0 END), "
        " SUM(CASE WHEN due_date IS NULL THEN 1 ELSE 0 END), "
        " COUNT(*), "
        " MIN(CASE WHEN awaiting = 1 AND due_date IS NOT NULL AND due_date < :today3 "
        "          THEN due_date ELSE NULL END) "
        "FROM ("
        "  SELECT g.due_date AS due_date, "
        "         CASE WHEN t.id IS NOT NULL AND t.completed = 0 THEN 0 ELSE 1 END AS awaiting "
        "  FROM knowledge_gaps g "
        "  LEFT JOIN tasks t ON t.id = g.linked_task_id "
        "  WHERE g.status != :resolvedStatus"
        ")"));
    // 同名占位符在 SQLite 驱动下只会绑上第一处，三处「今天」必须各取一个名字。
    const QString todayIso = today.toString(Qt::ISODate);
    query.bindValue(QStringLiteral(":today1"), todayIso);
    query.bindValue(QStringLiteral(":today2"), todayIso);
    query.bindValue(QStringLiteral(":today3"), todayIso);
    query.bindValue(QStringLiteral(":resolvedStatus"), static_cast<int>(StatusResolved));

    if (!query.exec() || !query.next()) {
        reportFailure(QStringLiteral("读取待补提醒失败：%1").arg(query.lastError().text()));
        return summary;
    }

    summary.insert(QStringLiteral("dueToday"), query.value(0).toInt());
    summary.insert(QStringLiteral("overdue"), query.value(1).toInt());
    summary.insert(QStringLiteral("unscheduled"), query.value(2).toInt());
    summary.insert(QStringLiteral("openTotal"), query.value(3).toInt());

    const QDate oldestOverdue = QDate::fromString(query.value(4).toString(), Qt::ISODate);
    summary.insert(QStringLiteral("oldestOverdueDays"),
                   oldestOverdue.isValid() ? static_cast<int>(oldestOverdue.daysTo(today)) : 0);
    summary.insert(QStringLiteral("valid"), true);
    return summary;
}
