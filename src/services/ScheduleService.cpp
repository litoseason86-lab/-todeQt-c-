#include "ScheduleService.h"

#include "DatabaseManager.h"

#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QSqlRecord>

#include <algorithm>

namespace {

QVariant valueByName(const QSqlQuery& query, const char* name)
{
    // 共享查询的列会演进；按列名读取可以避免列顺序变化破坏映射。
    const int index = query.record().indexOf(QLatin1String(name));
    return index >= 0 ? query.value(index) : QVariant();
}

// 「第 weekIndex 周」对应的单双周取值：奇数周 1，偶数周 2。
// 课表项的 week_parity 为 0（每周）时对任何周次都成立。
int parityForWeek(int weekIndex)
{
    return (weekIndex % 2 == 1) ? ScheduleService::OddWeeks : ScheduleService::EvenWeeks;
}

bool hasCommonActiveWeek(int firstStart, int firstEnd, int firstParity,
                         int secondStart, int secondEnd, int secondParity)
{
    const int overlapStart = std::max(firstStart, secondStart);
    const int overlapEnd = std::min(firstEnd, secondEnd);
    if (overlapStart > overlapEnd) {
        return false;
    }
    if (firstParity == ScheduleService::EveryWeek
        && secondParity == ScheduleService::EveryWeek) {
        return true;
    }
    if (firstParity != ScheduleService::EveryWeek
        && secondParity != ScheduleService::EveryWeek
        && firstParity != secondParity) {
        return false;
    }

    const int requiredParity = firstParity == ScheduleService::EveryWeek
        ? secondParity : firstParity;
    const bool overlapStartsOnRequiredParity = parityForWeek(overlapStart) == requiredParity;
    // 交集起点奇偶不符时，只要还有下一周就会真正相遇。
    return overlapStartsOnRequiredParity || overlapStart < overlapEnd;
}

} // namespace

ScheduleService::ScheduleService(QObject* parent)
    : QObject(parent)
{
    // 换库或同路径重开后，页面持有的课表数据全部作废，需要整体重载。
    // 与其它服务一致由 DatabaseManager 的通知统一驱动，业务路径便不必防御性刷新。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged, this, [this]() {
        emit scheduleChanged();
        emit periodsChanged();
    });
}

ScheduleService* ScheduleService::instance()
{
    static ScheduleService service;
    return &service;
}

void ScheduleService::reportFailure(const QString& message) const
{
    emit const_cast<ScheduleService*>(this)->operationFailed(message);
}

QString ScheduleService::entrySelectSql()
{
    // 科目用左连接取名称与颜色，课表格子直接用它着色；科目被删时 category_id 已置空，
    // 这里自然取到 NULL，不需要额外的空值分支。
    return QStringLiteral(
        "SELECT s.id, s.title, s.location, s.weekday, s.start_minutes, s.end_minutes, "
        "s.week_start, s.week_end, s.week_parity, s.category_id, "
        "c.name AS category_name, c.color AS category_color "
        "FROM schedule_entries s "
        "LEFT JOIN categories c ON s.category_id = c.id ");
}

QVariantMap ScheduleService::entryFromQuery(const QSqlQuery& query) const
{
    QVariantMap map;
    map.insert(QStringLiteral("id"), valueByName(query, "id").toInt());
    map.insert(QStringLiteral("title"), valueByName(query, "title").toString());
    map.insert(QStringLiteral("location"), valueByName(query, "location").toString());
    map.insert(QStringLiteral("weekday"), valueByName(query, "weekday").toInt());

    const int startMinutes = valueByName(query, "start_minutes").toInt();
    const int endMinutes = valueByName(query, "end_minutes").toInt();
    map.insert(QStringLiteral("startMinutes"), startMinutes);
    map.insert(QStringLiteral("endMinutes"), endMinutes);
    // 时长直接算好给 UI：网格按时长决定块高，让每个 delegate 自己减一遍没有意义。
    map.insert(QStringLiteral("durationMinutes"), endMinutes - startMinutes);

    map.insert(QStringLiteral("weekStart"), valueByName(query, "week_start").toInt());
    map.insert(QStringLiteral("weekEnd"), valueByName(query, "week_end").toInt());
    map.insert(QStringLiteral("weekParity"), valueByName(query, "week_parity").toInt());

    const QVariant categoryIdValue = valueByName(query, "category_id");
    const int categoryId = categoryIdValue.isValid() && !categoryIdValue.isNull()
            ? categoryIdValue.toInt()
            : -1;
    const QString categoryName = valueByName(query, "category_name").toString();
    const QString categoryColor = valueByName(query, "category_color").toString();
    // 课表格子只按 categoryColor 着色，不需要任务那种嵌套的 category 对象。
    // 这里刻意只给扁平字段：多给一层没人读的子映射，等于每行多分配一个
    // QVariantMap，还会让后来的人以为存在两套读法。
    map.insert(QStringLiteral("categoryId"), categoryId > 0 ? QVariant(categoryId) : QVariant());
    map.insert(QStringLiteral("categoryName"), categoryName);
    map.insert(QStringLiteral("categoryColor"), categoryColor);
    return map;
}

bool ScheduleService::validateEntryInput(const QString& title, int weekday,
                                         int startMinutes, int endMinutes,
                                         const QString& location,
                                         int weekStart, int weekEnd, int weekParity,
                                         QString* normalizedTitle,
                                         QString* normalizedLocation) const
{
    const QString trimmedTitle = title.trimmed();
    if (trimmedTitle.isEmpty()) {
        reportFailure(QStringLiteral("课程名称不能为空"));
        return false;
    }
    if (trimmedTitle.length() > kMaxTitleLength) {
        reportFailure(QStringLiteral("课程名称不能超过 %1 个字").arg(kMaxTitleLength));
        return false;
    }

    const QString trimmedLocation = location.trimmed();
    if (trimmedLocation.length() > kMaxLocationLength) {
        reportFailure(QStringLiteral("地点不能超过 %1 个字").arg(kMaxLocationLength));
        return false;
    }

    if (weekday < 1 || weekday > 7) {
        reportFailure(QStringLiteral("星期取值无效"));
        return false;
    }

    // 起止时间必须落在同一天内且 start < end。课表场景不存在跨零点条目，
    // 允许 end == kMinutesPerDay 表示「到 24:00 整」。
    if (startMinutes < 0 || startMinutes >= kMinutesPerDay) {
        reportFailure(QStringLiteral("开始时间无效"));
        return false;
    }
    if (endMinutes <= 0 || endMinutes > kMinutesPerDay) {
        reportFailure(QStringLiteral("结束时间无效"));
        return false;
    }
    if (endMinutes <= startMinutes) {
        reportFailure(QStringLiteral("结束时间必须晚于开始时间"));
        return false;
    }

    if (weekStart < 1 || weekStart > kMaxWeekIndex
        || weekEnd < 1 || weekEnd > kMaxWeekIndex) {
        reportFailure(QStringLiteral("周次必须在 1 到 %1 之间").arg(kMaxWeekIndex));
        return false;
    }
    if (weekEnd < weekStart) {
        reportFailure(QStringLiteral("结束周次不能早于开始周次"));
        return false;
    }

    if (weekParity != EveryWeek && weekParity != OddWeeks && weekParity != EvenWeeks) {
        reportFailure(QStringLiteral("单双周规则无效"));
        return false;
    }

    *normalizedTitle = trimmedTitle;
    *normalizedLocation = trimmedLocation;
    return true;
}

bool ScheduleService::addEntry(const QString& title, int weekday,
                               int startMinutes, int endMinutes,
                               const QString& location, int categoryId,
                               int weekStart, int weekEnd, int weekParity)
{
    QString normalizedTitle;
    QString normalizedLocation;
    if (!validateEntryInput(title, weekday, startMinutes, endMinutes, location,
                            weekStart, weekEnd, weekParity,
                            &normalizedTitle, &normalizedLocation)) {
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add schedule entry: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法添加课程"));
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO schedule_entries "
        "(title, location, weekday, start_minutes, end_minutes, "
        " week_start, week_end, week_parity, category_id) "
        "VALUES (:title, :location, :weekday, :startMinutes, :endMinutes, "
        " :weekStart, :weekEnd, :weekParity, :categoryId)"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":location"), normalizedLocation);
    query.bindValue(QStringLiteral(":weekday"), weekday);
    query.bindValue(QStringLiteral(":startMinutes"), startMinutes);
    query.bindValue(QStringLiteral(":endMinutes"), endMinutes);
    query.bindValue(QStringLiteral(":weekStart"), weekStart);
    query.bindValue(QStringLiteral(":weekEnd"), weekEnd);
    query.bindValue(QStringLiteral(":weekParity"), weekParity);
    // categoryId <= 0 统一存 NULL，而不是 0：外键指向 categories(id)，
    // 存 0 会留下一个指不到任何科目的悬空值。
    query.bindValue(QStringLiteral(":categoryId"),
                    categoryId > 0 ? QVariant(categoryId) : QVariant(QMetaType(QMetaType::Int)));

    if (!query.exec()) {
        qWarning() << "Failed to add schedule entry:" << query.lastError().text();
        reportFailure(QStringLiteral("添加课程失败: %1").arg(query.lastError().text()));
        return false;
    }

    emit scheduleChanged();
    return true;
}

bool ScheduleService::updateEntry(int id, const QString& title, int weekday,
                                  int startMinutes, int endMinutes,
                                  const QString& location, int categoryId,
                                  int weekStart, int weekEnd, int weekParity)
{
    if (id <= 0) {
        reportFailure(QStringLiteral("课程编号无效"));
        return false;
    }

    QString normalizedTitle;
    QString normalizedLocation;
    if (!validateEntryInput(title, weekday, startMinutes, endMinutes, location,
                            weekStart, weekEnd, weekParity,
                            &normalizedTitle, &normalizedLocation)) {
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update schedule entry: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法修改课程"));
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE schedule_entries SET "
        "title = :title, location = :location, weekday = :weekday, "
        "start_minutes = :startMinutes, end_minutes = :endMinutes, "
        "week_start = :weekStart, week_end = :weekEnd, week_parity = :weekParity, "
        "category_id = :categoryId "
        "WHERE id = :id"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":location"), normalizedLocation);
    query.bindValue(QStringLiteral(":weekday"), weekday);
    query.bindValue(QStringLiteral(":startMinutes"), startMinutes);
    query.bindValue(QStringLiteral(":endMinutes"), endMinutes);
    query.bindValue(QStringLiteral(":weekStart"), weekStart);
    query.bindValue(QStringLiteral(":weekEnd"), weekEnd);
    query.bindValue(QStringLiteral(":weekParity"), weekParity);
    query.bindValue(QStringLiteral(":categoryId"),
                    categoryId > 0 ? QVariant(categoryId) : QVariant(QMetaType(QMetaType::Int)));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to update schedule entry:" << query.lastError().text();
        reportFailure(QStringLiteral("修改课程失败: %1").arg(query.lastError().text()));
        return false;
    }
    // 语句成功但没有影响任何行，说明这条课程已经不在了（例如另一处刚删掉）。
    // 这时返回 true 会让界面显示「已保存」，实际什么都没写进去。
    if (query.numRowsAffected() == 0) {
        reportFailure(QStringLiteral("课程不存在或已被删除"));
        return false;
    }

    emit scheduleChanged();
    return true;
}

bool ScheduleService::deleteEntry(int id)
{
    if (id <= 0) {
        reportFailure(QStringLiteral("课程编号无效"));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete schedule entry: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法删除课程"));
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM schedule_entries WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) {
        qWarning() << "Failed to delete schedule entry:" << query.lastError().text();
        reportFailure(QStringLiteral("删除课程失败: %1").arg(query.lastError().text()));
        return false;
    }
    if (query.numRowsAffected() == 0) {
        reportFailure(QStringLiteral("课程不存在或已被删除"));
        return false;
    }

    emit scheduleChanged();
    return true;
}

QVariantList ScheduleService::getEntries() const
{
    QVariantList entries;

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get schedule entries: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载课表"));
        return entries;
    }

    QSqlQuery query(db);
    if (!query.exec(entrySelectSql()
                    + QStringLiteral("ORDER BY s.weekday ASC, s.start_minutes ASC, s.id ASC"))) {
        qWarning() << "Failed to get schedule entries:" << query.lastError().text();
        reportFailure(QStringLiteral("课表加载失败: %1").arg(query.lastError().text()));
        return entries;
    }

    while (query.next()) {
        entries.append(entryFromQuery(query));
    }
    return entries;
}

QVariantList ScheduleService::getEntriesForWeek(int weekIndex) const
{
    QVariantList entries;

    if (weekIndex < 1) {
        // 学期起始日之前的周次没有课表可言，返回空表而不是报错：
        // 用户往前翻到学期开始之前是正常操作，不该弹一条错误。
        return entries;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get schedule entries for week: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载课表"));
        return entries;
    }

    QSqlQuery query(db);
    // 三段合取：周次落在生效区间内、单双周命中、按星期与时间排序。
    // 单双周判据写成「每周 或 与本周奇偶一致」，把 0/1/2 三种取值收在一个条件里。
    query.prepare(entrySelectSql() + QStringLiteral(
        "WHERE s.week_start <= :weekIndex AND s.week_end >= :weekIndex "
        "AND (s.week_parity = :everyWeek OR s.week_parity = :parity) "
        "ORDER BY s.weekday ASC, s.start_minutes ASC, s.id ASC"));
    query.bindValue(QStringLiteral(":weekIndex"), weekIndex);
    query.bindValue(QStringLiteral(":everyWeek"), static_cast<int>(EveryWeek));
    query.bindValue(QStringLiteral(":parity"), parityForWeek(weekIndex));

    if (!query.exec()) {
        qWarning() << "Failed to get schedule entries for week:" << query.lastError().text();
        reportFailure(QStringLiteral("课表加载失败: %1").arg(query.lastError().text()));
        return entries;
    }

    while (query.next()) {
        entries.append(entryFromQuery(query));
    }
    return entries;
}

QVariantList ScheduleService::findConflicts(int weekday, int startMinutes, int endMinutes,
                                            int weekStart, int weekEnd, int weekParity,
                                            int excludeId) const
{
    QVariantList conflicts;

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        // 冲突检测只是提示，查不了就当没有冲突，不要因此挡住用户保存。
        return conflicts;
    }

    QSqlQuery query(db);
    // 判定冲突需要三件事同时成立：
    //   1. 同一天，且时间区间真正相交（左开右开：紧邻的 09:40 与 09:40 不算冲突）
    //   2. 两者的生效周次区间有交集
    //   3. 两者的单双周有可能落在同一周（一个只在单周、另一个只在双周则永不相遇）
    query.prepare(entrySelectSql() + QStringLiteral(
        "WHERE s.weekday = :weekday "
        "AND s.start_minutes < :endMinutes AND s.end_minutes > :startMinutes "
        "AND s.week_start <= :weekEnd AND s.week_end >= :weekStart "
        "AND s.id != :excludeId "
        "ORDER BY s.start_minutes ASC, s.id ASC"));
    query.bindValue(QStringLiteral(":weekday"), weekday);
    query.bindValue(QStringLiteral(":startMinutes"), startMinutes);
    query.bindValue(QStringLiteral(":endMinutes"), endMinutes);
    query.bindValue(QStringLiteral(":weekStart"), weekStart);
    query.bindValue(QStringLiteral(":weekEnd"), weekEnd);
    // 新增时传 -1，不会等于任何自增主键，等效于「不排除任何行」。
    query.bindValue(QStringLiteral(":excludeId"), excludeId);

    if (!query.exec()) {
        qWarning() << "Failed to check schedule conflicts:" << query.lastError().text();
        return conflicts;
    }

    while (query.next()) {
        const QVariantMap entry = entryFromQuery(query);
        if (hasCommonActiveWeek(
                entry.value(QStringLiteral("weekStart")).toInt(),
                entry.value(QStringLiteral("weekEnd")).toInt(),
                entry.value(QStringLiteral("weekParity")).toInt(),
                weekStart, weekEnd, weekParity)) {
            conflicts.append(entry);
        }
    }
    return conflicts;
}

QVariantList ScheduleService::getPeriods() const
{
    QVariantList periods;

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get schedule periods: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载节次"));
        return periods;
    }

    QSqlQuery query(db);
    if (!query.exec(QStringLiteral(
            "SELECT period_index, start_minutes, end_minutes FROM schedule_periods "
            "ORDER BY period_index ASC"))) {
        qWarning() << "Failed to get schedule periods:" << query.lastError().text();
        reportFailure(QStringLiteral("节次加载失败: %1").arg(query.lastError().text()));
        return periods;
    }

    while (query.next()) {
        QVariantMap period;
        period.insert(QStringLiteral("index"), query.value(0).toInt());
        period.insert(QStringLiteral("startMinutes"), query.value(1).toInt());
        period.insert(QStringLiteral("endMinutes"), query.value(2).toInt());
        periods.append(period);
    }
    return periods;
}

bool ScheduleService::setPeriods(const QVariantList& periods)
{
    if (periods.isEmpty()) {
        // 允许清空会让「按节次」显示模式变成一张没有任何行的空网格，
        // 看起来和功能损坏没有区别。至少留一节。
        reportFailure(QStringLiteral("至少需要保留一节课时"));
        return false;
    }

    if (periods.size() > kMaxPeriodCount) {
        reportFailure(QStringLiteral("节次最多 %1 节").arg(kMaxPeriodCount));
        return false;
    }

    // 先全部校验并规范化，再整表写入。校验穿插在写入中间会留下半张节次表。
    struct NormalizedPeriod {
        int startMinutes;
        int endMinutes;
    };
    QList<NormalizedPeriod> normalized;
    normalized.reserve(periods.size());

    for (const QVariant& item : periods) {
        const QVariantMap period = item.toMap();
        bool startOk = false;
        bool endOk = false;
        const int startMinutes = period.value(QStringLiteral("startMinutes")).toInt(&startOk);
        const int endMinutes = period.value(QStringLiteral("endMinutes")).toInt(&endOk);
        if (!startOk || !endOk) {
            reportFailure(QStringLiteral("节次时间格式无效"));
            return false;
        }
        if (startMinutes < 0 || startMinutes >= kMinutesPerDay
            || endMinutes <= 0 || endMinutes > kMinutesPerDay
            || endMinutes <= startMinutes) {
            reportFailure(QStringLiteral("节次时间无效：结束时间必须晚于开始时间"));
            return false;
        }
        normalized.append({ startMinutes, endMinutes });
    }

    // 按开始时间排序后重新编号。节次编号必须与时间顺序一致，
    // 否则「按节次」模式画出来的行会和用户心里的第 1、2、3 节对不上。
    std::sort(normalized.begin(), normalized.end(),
              [](const NormalizedPeriod& lhs, const NormalizedPeriod& rhs) {
                  if (lhs.startMinutes != rhs.startMinutes) {
                      return lhs.startMinutes < rhs.startMinutes;
                  }
                  return lhs.endMinutes < rhs.endMinutes;
              });

    // 排序之后再查重叠：节次是「一节接一节」的时间轴，区间相交在现实里不存在，
    // 而网格按「课表项与哪几节相交」决定块跨几行——两节重叠时，
    // 一条 30 分钟的课会同时命中两节，被画成两行高，压到下一节的行上。
    for (int i = 1; i < normalized.size(); ++i) {
        if (normalized.at(i).startMinutes < normalized.at(i - 1).endMinutes) {
            reportFailure(QStringLiteral("第 %1 节与第 %2 节时间重叠").arg(i).arg(i + 1));
            return false;
        }
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to set schedule periods: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法保存节次"));
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start schedule period transaction:" << db.lastError().text();
        reportFailure(QStringLiteral("保存节次失败: %1").arg(db.lastError().text()));
        return false;
    }

    QSqlQuery clearQuery(db);
    if (!clearQuery.exec(QStringLiteral("DELETE FROM schedule_periods"))) {
        qWarning() << "Failed to clear schedule periods:" << clearQuery.lastError().text();
        reportFailure(QStringLiteral("保存节次失败: %1").arg(clearQuery.lastError().text()));
        db.rollback();
        return false;
    }

    QSqlQuery insertQuery(db);
    if (!insertQuery.prepare(QStringLiteral(
            "INSERT INTO schedule_periods (period_index, start_minutes, end_minutes) "
            "VALUES (?, ?, ?)"))) {
        qWarning() << "Failed to prepare schedule period insert:"
                   << insertQuery.lastError().text();
        reportFailure(QStringLiteral("保存节次失败: %1").arg(insertQuery.lastError().text()));
        db.rollback();
        return false;
    }

    for (int i = 0; i < normalized.size(); ++i) {
        insertQuery.addBindValue(i + 1);
        insertQuery.addBindValue(normalized.at(i).startMinutes);
        insertQuery.addBindValue(normalized.at(i).endMinutes);
        if (!insertQuery.exec()) {
            qWarning() << "Failed to insert schedule period:" << insertQuery.lastError().text();
            reportFailure(QStringLiteral("保存节次失败: %1").arg(insertQuery.lastError().text()));
            db.rollback();
            return false;
        }
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit schedule periods:" << db.lastError().text();
        reportFailure(QStringLiteral("保存节次失败: %1").arg(db.lastError().text()));
        db.rollback();
        return false;
    }

    emit periodsChanged();
    return true;
}
